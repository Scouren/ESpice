//! Model cards: global and subcircuit-local `.model` rows, binning bounds,
//! and the per-instance re-reads a local model needs.
//! Cites: ngspice subckt.c modtranslate, INPgetModBin.
//!
//! Contents:
//! - `pub const Geometry = struct`
//! - `pub fn readModel(r: *Reader, card: F, outer: *const Frame, global: bool) Error!void`
//! - `pub fn unresolved(r: *const Reader, span: Span) bool`
//! - `pub fn namesParam(r: *const Reader, span: Span, sub: Subckt) bool`
//! - `pub fn modelRow(r: *Reader, letter: u8, name: []const u8, pos: u32, frame: *const Frame) Error!u32`
//! - `pub fn binsEnd(r: *const Reader) u32`
//! - `pub fn closeBins(r: *Reader, e: u32, per_finger: bool) Error!void`
//! - `pub fn cardLength(r: *Reader, kv: []const Kv, key: []const u8) Error!?Geometry`
//! - `pub fn localRow(r: *Reader, lm: usize, frame: *const Frame) Error!u32`
//! - `pub fn localKey(r: *Reader, lm: usize, frame: *const Frame) Error!?[]const u8`
//! - `pub fn localReads(r: *Reader, text: []const u8) Error!LocalReads`
//! - `pub fn sameValues(a: []const Kv, b: []const Kv) bool`

const std = @import("std");
const Ast = @import("../Ast.zig");
const spice_number = @import("../Parse/spice_number.zig");
const expr = @import("../Parse/expr.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_sweeps = @import("reader_sweeps.zig");
const reader_values = @import("reader_values.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const none = card_rows.none;
const Error = card_rows.Error;
const Span = card_rows.Span;
const Value = card_rows.Value;
const Kv = card_rows.Kv;
const data_file_keys = card_table.data_file_keys;
const nameKey = netlist_view.nameKey;
const Frame = reader_frame.Frame;
const Subckt = reader_frame.Subckt;
const isBinOf = card_table.isBinOf;
const binBounds = card_table.binBounds;
const binHolds = netlist_view.binHolds;
const kvNumber = netlist_view.kvNumber;
const readsLive = card_table.readsLive;
const appendSpan = reader_frame.appendSpan;
const LocalReads = reader.LocalReads;

pub const Geometry = struct { num: f64, live: bool = false };

/// Reads a `.model` card under `frame` into a new row; `global`
/// makes it the row its name resolves to outside subcircuits.
pub fn readModel(r: *Reader, card: F, outer: *const Frame, global: bool) Error!void {
    const line = card.line;
    r.diag.card = line;
    var f = card;
    _ = f.field();
    const name = f.field() orelse return error.ParseError;
    const kind = f.field() orelse return error.ParseError;
    if (!F.isWord(name) or !F.isWord(kind)) return error.ParseError;
    var own = outer.*;
    own.keep_live = true;
    const frame = &own;
    // Site keys are read only under Monte Carlo (`emit`).
    if (r.live.monte) r.eval.site_owner = nameKey(nameKey(0, frame.path orelse ""), name);
    r.eval.site_ordinal = 0;
    const matrix_keys = std.StaticStringMap(void).initComptime(.{ .{ "r", {} }, .{ "l", {} }, .{ "g", {} }, .{ "c", {} } });
    // CPL matrices are blank-separated; a negative entry is not a subtraction.
    const cpl = std.mem.eql(u8, kind, "cpl");
    // So are an HSPICE W model's lower-triangle matrices.
    const wline = std.mem.eql(u8, kind, "w");
    const w_matrix_keys = std.StaticStringMap(void).initComptime(.{
        .{ "lo", {} }, .{ "co", {} }, .{ "ro", {} }, .{ "go", {} }, .{ "rs", {} }, .{ "gd", {} },
        .{ "l", {} },  .{ "c", {} },  .{ "r", {} },  .{ "g", {} },
    });
    r.card.kv.clearRetainingCapacity();
    while (f.field()) |t| {
        if (t[0] == '(' or t[0] == ')' or t[0] == ',') continue;
        if (!F.isWord(t)) return error.ParseError;
        if (f.takeEq()) {
            // DEV/LOT tolerances apply to the value before them;
            // the global-scope read records them once.
            const prev = if (r.card.kv.items.len > 0) r.card.kv.items[r.card.kv.items.len - 1].key else "";
            if (try reader_sweeps.devLot(r, t, prev, name, &f, line)) |v| {
                if (global) try r.deck.variations.append(r.arena, v);
                continue;
            }
            if (data_file_keys.has(t)) {
                try r.card.kv.append(r.arena, .{ .key = t, .value = .{ .name = try reader_values.dataPath(r, &f) } });
                continue;
            }
            const value = if ((cpl and matrix_keys.has(t)) or (wline and w_matrix_keys.has(t))) try reader_values.readValue(r, &f, frame, true, true) else try reader_values.kvValue(r, &f, frame, true);
            try r.card.kv.append(r.arena, .{ .key = t, .value = value });
        } else {
            const value: Value = if (spice_number.spiceNumber(t)) |n| .{ .num = n } else try reader_values.nameValue(r, t, frame, true);
            try r.card.kv.append(r.arena, .{ .key = "", .value = value });
        }
    }
    const span = try appendSpan(Kv, r.arena, &r.nl.kvs, r.card.kv.items);
    if (global) {
        const gop = try r.nl.model_ids.getOrPut(r.arena, name);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(r.nl.models.items.len);
    }
    try r.nl.models.append(r.arena, .{ .name = name, .kind = kind, .kv = span });
}

/// True when a value in `span` did not fold: it names a parameter the
/// global scope lacks, which no device could bind.
pub fn unresolved(r: *const Reader, span: Span) bool {
    for (r.nl.kvs.items[span.start..][0..span.len]) |kv| if (kv.value == .expr) return true;
    return false;
}

/// True when a value in `span` is a bare name `sub` declares as a
/// parameter: read at global scope it stayed a name, but each
/// instance substitutes its own value.
pub fn namesParam(r: *const Reader, span: Span, sub: Subckt) bool {
    for (r.nl.kvs.items[span.start..][0..span.len]) |kv| if (kv.value == .name) {
        for (sub.defaults) |d| if (std.mem.eql(u8, d.key, kv.value.name)) return true;
    };
    return false;
}

/// The model row card `letter` inside `frame` names: a `.model` of
/// the frame's own subcircuit (for an M card, the `name.N` bin the
/// card's L and W select, as ngspice bins the renamed subcircuit
/// models), else the first global row. Rewrites the card's model
/// name, `r.values[pos]`, to the bin it picks.
pub fn modelRow(r: *Reader, letter: u8, name: []const u8, pos: u32, frame: *const Frame) Error!u32 {
    const sub = r.decl.subckts.items[frame.sub orelse return r.nl.model_ids.get(name) orelse none];
    for (r.local.instance_models.items[frame.models_mark..]) |m| if (std.mem.eql(u8, m.name, name)) return m.row;
    const locals = r.local.models.items[sub.models_lo..sub.models_hi];
    for (locals, sub.models_lo..) |m, lm| if (!m.cond and std.mem.eql(u8, m.name, name)) return localRow(r, lm, frame);
    if (letter != 'm') return r.nl.model_ids.get(name) orelse none;
    // ngspice prepends model declarations (inpmkmod.c): the last
    // matching bin wins, as in `modelBins`.
    // Read before any `localRow`, which reuses the card scratch.
    const kv = r.card.kv.items;
    const lg = try cardLength(r, kv, "l") orelse return r.nl.model_ids.get(name) orelse none;
    const use_nf = if (kvNumber(kv, "wnflag")) |flag| flag != 0 else r.deck.wnflag;
    const nfg: Geometry = if (use_nf) try cardLength(r, kv, "nf") orelse .{ .num = 1 } else .{ .num = 1 };
    const wg = try cardLength(r, kv, "w") orelse return r.nl.model_ids.get(name) orelse none;
    const l = lg.num * r.deck.scale;
    const w = wg.num * r.deck.scale / nfg.num;
    const w_live = wg.live or nfg.live;
    var picked: ?u32 = null;
    var k = locals.len;
    while (k > 0) {
        k -= 1;
        const m = locals[k];
        if (m.cond or !isBinOf(m.name, name)) continue;
        // Bounds from the global-scope read, else from the read under
        // this instance's parameters: a PDK writes `lmin=lmin_parm`
        // with the parameter in the device subcircuit.
        const b = binBounds(r.nl.kvs.items[r.nl.models.items[m.top].kv.start..][0..r.nl.models.items[m.top].kv.len]) orelse blk: {
            const own = r.nl.models.items[try localRow(r, sub.models_lo + k, frame)].kv;
            break :blk binBounds(r.nl.kvs.items[own.start..][0..own.len]) orelse continue;
        };
        if (!lg.live and !w_live) {
            if (!binHolds(b, l, w)) continue;
            r.nl.values.items[pos] = .{ .name = m.name };
            return localRow(r, sub.models_lo + k, frame);
        }
        // Live geometry: every bin the fixed dimension allows is a
        // candidate a point may pick (`Live.bins`), read now under
        // this instance's parameters.
        if (!lg.live and !binHolds(b, l, b[2])) continue;
        if (!w_live and !binHolds(b, b[0], w)) continue;
        const row = try localRow(r, sub.models_lo + k, frame);
        try r.live.bin_rows.append(r.arena, row);
        try r.live.bin_bounds.append(r.arena, b);
        if (picked == null and binHolds(b, l, w)) {
            picked = row;
            r.nl.values.items[pos] = .{ .name = m.name };
        }
    }
    if (r.live.bin_rows.items.len != binsEnd(r)) try closeBins(r, @intCast(r.nl.hg.edges.len), use_nf);
    return picked orelse r.nl.model_ids.get(name) orelse none;
}

/// One past the last candidate of the cards `Live.bins` holds.
pub fn binsEnd(r: *const Reader) u32 {
    const starts = r.live.bin_starts.items;
    return if (starts.len == 0) 0 else starts[starts.len - 1];
}

/// Records the candidates appended since `binsEnd` as edge `e`'s.
/// `starts` opens on the first card, so a deck without one
/// allocates nothing here.
pub fn closeBins(r: *Reader, e: u32, per_finger: bool) Error!void {
    std.debug.assert(r.live.bin_rows.items.len > binsEnd(r));
    if (r.live.bin_starts.items.len == 0) try r.live.bin_starts.append(r.arena, 0);
    try r.live.bin_edges.append(r.arena, e);
    try r.live.bin_per_finger.append(r.arena, per_finger);
    try r.live.bin_starts.append(r.arena, @intCast(r.live.bin_rows.items.len));
}

/// Card value `key` as a number: as written, or, when it reads a
/// live name, folded at the nominal values (`live` set). Null when
/// the card lacks it or it does not fold.
pub fn cardLength(r: *Reader, kv: []const Kv, key: []const u8) Error!?Geometry {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) switch (item.value) {
        .num => |n| return .{ .num = n },
        .expr => |span| {
            const ops = r.nl.ops.items[span.start..][0..span.len];
            if (!readsLive(ops)) return null;
            const v = try expr.fold(r.arena, &r.eval.stack, ops, r.nl.consts.items, false, r.live.nominal.items);
            return if (v.known) .{ .num = v.num, .live = true } else null;
        },
        else => return null,
    };
    return null;
}

/// The model row of `local_models` row `lm` for the instance `frame`
/// expands: the shared global-scope row, else one read under the
/// instance's parameters on first use.
pub fn localRow(r: *Reader, lm: usize, frame: *const Frame) Error!u32 {
    const m = r.local.models.items[lm];
    if (m.shared) return m.top;
    const line = m.line;
    const name = m.name;
    if (r.local.variants.len != r.local.models.items.len) {
        std.debug.assert(r.local.variants.len == 0);
        r.local.variants = try r.arena.alloc(std.ArrayList(u32), r.local.models.items.len);
        @memset(r.local.variants, .empty);
        r.local.reads = try r.arena.alloc(?LocalReads, r.local.models.items.len);
        @memset(r.local.reads, null);
    }
    // A PDK reads each subcircuit-local card once per instance
    // under the instance's parameters (78% of `Problem.init` on
    // c7552_ihp); equal inputs fold to equal rows.
    const memo = try localKey(r, lm, frame);
    if (memo) |key| if (r.local.memo.get(key)) |row| {
        try r.local.instance_models.append(r.arena, .{ .name = name, .row = row });
        return row;
    };
    const kv_mark = r.nl.kvs.items.len;
    try readModel(r, r.ast.cursor(line), frame, false);
    var row: u32 = @intCast(r.nl.models.items.len - 1);
    const seen = &r.local.variants[lm];
    const fresh = r.nl.kvs.items[kv_mark..];
    for (seen.items) |old| {
        const kv = r.nl.models.items[old].kv;
        if (!sameValues(r.nl.kvs.items[kv.start..][0..kv.len], fresh)) continue;
        r.nl.models.shrinkRetainingCapacity(row);
        r.nl.kvs.shrinkRetainingCapacity(kv_mark);
        row = old;
        break;
    } else try seen.append(r.arena, row);
    if (memo) |key| try r.local.memo.put(r.arena, try r.arena.dupe(u8, key), row);
    try r.local.instance_models.append(r.arena, .{ .name = name, .row = row });
    return row;
}

/// The memo key of local model `lm` read in `frame`: `lm`, then for
/// each name its line can read, every scope's entry for it (all
/// scopes, not only the innermost, so any lookup order the fold uses
/// is covered), following text entries' own names. Null when the
/// line draws a statistical value, which differs per instance site.
/// Borrows `r.local_key` until the next call.
pub fn localKey(r: *Reader, lm: usize, frame: *const Frame) Error!?[]const u8 {
    const reads = r.local.reads[lm] orelse blk: {
        const got = try localReads(r, r.ast.line(r.local.models.items[lm].line));
        r.local.reads[lm] = got;
        break :blk got;
    };
    const names = switch (reads) {
        .stochastic => return null,
        .names => |ns| ns,
    };
    const key = &r.local.key;
    key.clearRetainingCapacity();
    try key.appendSlice(r.arena, std.mem.asBytes(&@as(u64, lm)));
    // Names reached through text entries, breadth first, each once.
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(r.arena);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(r.arena);
    for (names) |n| if (!(try seen.getOrPut(r.arena, n)).found_existing) try queue.append(r.arena, n);
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const n = queue.items[i];
        for (frame.scopes) |scope| {
            const e = scope.get(n) orelse {
                try key.append(r.arena, 0);
                continue;
            };
            switch (e) {
                .num => |v| {
                    try key.append(r.arena, 1);
                    try key.appendSlice(r.arena, std.mem.asBytes(&v));
                },
                .text => |t| {
                    try key.append(r.arena, 2);
                    try key.appendSlice(r.arena, std.mem.asBytes(&@as(u64, t.len)));
                    try key.appendSlice(r.arena, t);
                    switch (try localReads(r, t)) {
                        .stochastic => return null,
                        .names => |more| for (more) |m| if (!(try seen.getOrPut(r.arena, m)).found_existing) try queue.append(r.arena, m),
                    }
                },
            }
        }
    }
    return key.items;
}

/// The identifiers `text` holds, `.func` bodies followed, or
/// `.stochastic` when it calls a distribution. Keys and function
/// names count too: a superset only makes the memo key stricter.
pub fn localReads(r: *Reader, text: []const u8) Error!LocalReads {
    var out: std.ArrayList([]const u8) = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    defer todo.deinit(r.arena);
    try todo.append(r.arena, text);
    var bodies: usize = 0;
    while (todo.pop()) |t| {
        var k: usize = 0;
        while (k < t.len) {
            const c = t[k];
            if (std.ascii.isDigit(c) or c == '.') {
                // A number with its exponent and scale suffix.
                while (k < t.len and (std.ascii.isAlphanumeric(t[k]) or t[k] == '.' or t[k] == '_' or
                    ((t[k] == '+' or t[k] == '-') and k > 0 and (t[k - 1] == 'e' or t[k - 1] == 'E')))) k += 1;
                continue;
            }
            if (!(std.ascii.isAlphabetic(c) or c == '_')) {
                k += 1;
                continue;
            }
            const start = k;
            while (k < t.len and (std.ascii.isAlphanumeric(t[k]) or t[k] == '_')) k += 1;
            const ident = t[start..k];
            if (expr.isDistributionName(ident)) return .stochastic;
            if (r.decl.funcs.get(ident)) |func| {
                bodies += 1;
                // A recursive `.func` chain: give up on the memo.
                if (bodies > 64) return .stochastic;
                try todo.append(r.arena, func.body);
            }
            try out.append(r.arena, ident);
        }
    }
    return .{ .names = out.items };
}

/// Equal keys and values; an unfolded expression never compares equal.
pub fn sameValues(a: []const Kv, b: []const Kv) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key)) return false;
        const same = switch (x.value) {
            .num => |n| y.value == .num and y.value.num == n,
            .name => |n| y.value == .name and std.mem.eql(u8, y.value.name, n),
            else => false,
        };
        if (!same) return false;
    }
    return true;
}

// ---- private ----
