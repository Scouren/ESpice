//! Directive cards: analyses, `.options`, `.ic`, `.save`, `.probe`, `.step`,
//! `.wcd`, `.mosra`, `.sample`, and the global `.param` fold.
//! Cites: ngspice inp.c, inpc_probe.c; HSPICE [CR] .SAMPLE, .MOSRA, [SA]
//! Ch.29; #236-#240.
//!
//! Contents:
//! - `pub const max_trials = 1 << 20`
//! - `pub fn readArgs(r: *Reader, f: *F) Error![]const Value`
//! - `pub fn cutFail(r: *Reader, line: []const u8, f: *F) Error![]const u8`
//! - `pub fn readFileOptions(r: *Reader, card: F) Error!void`
//! - `pub fn readDirective(r: *Reader, card_in: F) Error!void`
//! - `pub fn readMosra(r: *Reader, line: []const u8, args: []const Value) Error!Mosra`
//! - `pub fn readSample(args: []const Value) Error!core.query.NoiseSample`
//! - `pub fn option(r: *const Reader, name: []const u8) ?f64`
//! - `pub fn binOptions(r: *Reader) Error!void`

const std = @import("std");
const Ast = @import("../Ast.zig");
const spice_number = @import("../Parse/spice_number.zig");
const core = @import("core");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_nets = @import("reader_nets.zig");
const reader_sweeps = @import("reader_sweeps.zig");
const reader_values = @import("reader_values.zig");
const reader_diag = @import("reader_diag.zig");
const tokenizer = @import("../tokenizer.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const Value = card_rows.Value;
const appendAnalysis = reader_frame.appendAnalysis;
const Mosra = card_rows.Mosra;
const cardOf = tokenizer.Token.getKeyword;
const nodeText = reader_frame.nodeText;
const Frame = reader_frame.Frame;
const setsKey = card_table.setsKey;

/// Trials one `MONTE=list(...)` names in all, its `a:b` ranges
/// expanded: each is an argument row of 24 B, so a short card
/// cannot ask for gigabytes. A million runs is past any budget.
pub const max_trials = 1 << 20;

pub fn readArgs(r: *Reader, f: *F) Error![]const Value {
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    var args: std.ArrayList(Value) = .empty;
    while (f.field()) |t| {
        if (t[0] == ',' or t[0] == '=') continue;
        const last = if (args.items.len != 0) args.items[args.items.len - 1] else Value{ .num = 0 };
        if (last == .name and std.mem.eql(u8, last.name, "monte") and std.ascii.eqlIgnoreCase(t, "list")) {
            // `MONTE=list(10 20:30)`, parentheses optional: the trial
            // numbers follow `list`, each `a:b` range expanded.
            try args.append(r.arena, .{ .name = "list" });
            var trials: f64 = 0;
            while (f.field()) |n| {
                if (n[0] == ')') break;
                if (n[0] == '(' or n[0] == ',') continue;
                const colon = std.mem.indexOfScalar(u8, n, ':') orelse n.len;
                const lo = spice_number.spiceNumber(n[0..colon]) orelse return error.ParseError;
                const hi = if (colon == n.len) lo else spice_number.spiceNumber(n[colon + 1 ..]) orelse return error.ParseError;
                if (!(lo >= 1 and hi >= lo and hi <= std.math.maxInt(u32)) or lo != @trunc(lo) or hi != @trunc(hi)) return error.ParseError;
                trials += hi - lo + 1;
                if (trials > max_trials) return error.ParseError;
                var k = lo;
                while (k <= hi) : (k += 1) try args.append(r.arena, .{ .num = k });
            }
            continue;
        }
        try args.append(r.arena, try reader_values.valueAt(r, t, f, &top, false, false));
    }
    return args.items;
}

/// Cuts `fail='expr'` (quoted or braced) out of analysis card
/// `line` and points `f`, past the card, at what is left; returns
/// the expression's text, "" when no field is `fail=`.
pub fn cutFail(r: *Reader, line: []const u8, f: *F) Error![]const u8 {
    var g = f.*;
    while (g.field()) |t| {
        if (!std.mem.eql(u8, t, "fail") or !g.takeEq()) continue;
        const v = g.field() orelse return reader_diag.failed(r, line, error.ParseError);
        if (!F.isQuote(v[0]) and !(v[0] == '{' and v[v.len - 1] == '}')) return reader_diag.failed(r, line, error.ParseError);
        const start = @intFromPtr(t.ptr) - @intFromPtr(line.ptr);
        const end = @intFromPtr(v.ptr) - @intFromPtr(line.ptr) + v.len;
        f.* = try F.initLine(r.arena, try std.mem.concat(r.arena, u8, &.{ line[0..start], " ", line[end..] }));
        _ = f.field(); // the card
        return F.body(v);
    }
    return "";
}

/// A `.options` card that names a file, path case kept: each
/// `vpi="app.so"` (ESPice's, #197) a VPI application (LRM 12.33) for
/// `vpi_apps`, `soalimits="file.json"` (#238) the SOA limits for
/// `soa_file`, `emirfile="f"` (#237) the `--emir` file. The card's
/// other options read as any `.options`.
pub fn readFileOptions(r: *Reader, card: F) Error!void {
    const line = card.line;
    var f = card;
    _ = f.field(); // the card
    var rest: std.ArrayList(u8) = .empty;
    try rest.appendSlice(r.arena, ".options");
    while (f.field()) |t| {
        if (std.mem.eql(u8, t, "vpi") or std.mem.eql(u8, t, "soalimits") or std.mem.eql(u8, t, "emirfile")) {
            const eq = f.field() orelse return reader_diag.failed(r, line, error.ParseError);
            if (eq[0] != '=') return reader_diag.failed(r, line, error.ParseError);
            const path = reader_values.pathOf(r, &f) catch |err| return reader_diag.failed(r, line, err);
            switch (t[0]) {
                'v' => try r.deck.vpi_apps.append(r.arena, path),
                's' => r.deck.soa_file = path,
                else => r.deck.emir_file = path,
            }
            continue;
        }
        try rest.append(r.arena, ' ');
        try rest.appendSlice(r.arena, t);
    }
    var g = try F.initLine(r.arena, rest.items);
    _ = g.field();
    const args = readArgs(r, &g) catch |err| return reader_diag.failed(r, line, err);
    try r.deck.config.append(r.arena, .{ .temp = false, .args = args, .line = r.ast.written(line) });
}

/// Reads directive card `card`, a cursor at its start, into the deck tables.
pub fn readDirective(r: *Reader, card_in: F) Error!void {
    const line = card_in.line;
    r.diag.card = line;
    var f = card_in;
    const card = cardOf(f.field().?[1..]);
    // Read after the walk (`readMeasures`).
    if (card != null and card.? == .meas) return r.deck.meas_lines.append(r.arena, line);
    const c = card orelse return reader_diag.unsupported(r, line, "unsupported card");
    if (c == .wcd) {
        if (r.deck.wcd_line != null) return reader_diag.unsupported(r, line, "a second .wcd card");
        r.deck.wcd_line = line;
        return;
    }
    if (c == .ignored) {
        if (!std.ascii.startsWithIgnoreCase(line, ".probe")) return;
        return ngspiceProbe(r, line);
    }
    if (c == .save and isSaveOp(line)) return readSaveOp(r, line, &f);
    // HSPICE `.store` checkpoints the process on a wall-clock
    // schedule for an OS-level restore [CR .STORE]; the results do not
    // depend on it.
    if (c == .store) return reader_diag.note(r, .{ .code = .store_ignored });
    if (c == .options and (setsKey(line, "vpi") or setsKey(line, "soalimits") or setsKey(line, "emirfile"))) return readFileOptions(r, card_in);
    // `FAIL='expr'` keeps its text: `readArgs` would fold it before
    // the `.meas` cards it names are read.
    const fail = if (c == .analysis and setsKey(line, "fail")) try cutFail(r, line, &f) else "";
    const args = readArgs(r, &f) catch |err| return reader_diag.failed(r, line, err);
    switch (c) {
        .step => try r.deck.steps.append(r.arena, reader_sweeps.readStep(r, args) catch |err| return reader_diag.failed(r, line, err)),
        .analysis => |kind| {
            // Every `.temp` card is configuration, never an analysis:
            // analysis_options.zig folds the last one as ngspice 44.2
            // does (measured). A temperature sweep is `.dc temp`.
            if (kind == .temp) return r.deck.config.append(r.arena, .{ .temp = true, .args = args, .line = r.ast.written(line) });
            const refusals = r.diag.refusals;
            var swept = reader_sweeps.readSweep(r, kind, args, line) catch |err| return if (r.diag.refusals > refusals) err else reader_diag.failed(r, line, err);
            const scaled = swept.sweep == .monte and swept.sweep.monte.scales.len != 0;
            if (scaled != (fail.len != 0)) return reader_diag.unsupported(r, line, "SIGMA_SCALE= without FAIL=, or FAIL= without SIGMA_SCALE=");
            if (scaled) {
                if (kind != .tran and kind != .ac and kind != .dc) return reader_diag.unsupported(r, line, "SIGMA_SCALE on a card other than .tran, .ac or .dc");
                // The lane ensemble (`.dc MONTE=n`) measures no trial.
                if (kind == .dc and swept.args.len == 0) return reader_diag.unsupported(r, line, "SIGMA_SCALE on a .dc with no sweep of its own");
                swept.sweep.monte.fail.text = fail;
            }
            try appendAnalysis(r.arena, &r.deck.analyses, .{ .kind = kind, .args = swept.args, .sweep = swept.sweep, .line = r.ast.written(line) });
        },
        .options => try r.deck.config.append(r.arena, .{ .temp = false, .args = args, .line = r.ast.written(line) }),
        .ic, .nodeset => {
            // ngspice 44.2 reads `v(net)=value` pairs and `.nodeset
            // all=value`; HSPICE's bare `net value` is its `.ic syntax
            // error` (measured).
            var i: usize = 0;
            while (i < args.len) : (i += 2) if (args[i] != .group and !(c == .nodeset and std.ascii.eqlIgnoreCase(Value.nameAt(args, i) orelse "", "all")))
                return reader_diag.failed(r, line, error.ParseError);
            try (if (c == .ic) &r.deck.ic_cards else &r.deck.nodeset_cards).append(r.arena, args);
        },
        .sample => r.deck.sample = readSample(args) catch |err| return reader_diag.failed(r, line, err),
        .mosra => r.deck.mosra = try readMosra(r, line, args),
        .appendmodel => {
            // `.appendmodel src mosra dst nmos`; HSPICE's other
            // appended kinds (a second model card) are not modeled.
            if (args.len != 4 or args[0] != .name or args[2] != .name or args[1] != .name or !std.mem.eql(u8, args[1].name, "mosra"))
                return reader_diag.unsupported(r, line, ".appendmodel other than `src mosra dst type`");
            try r.deck.appendmodels.append(r.arena, .{ .src = args[0].name, .dst = args[2].name });
        },
        .global => for (args) |a| {
            var buf: [24]u8 = undefined;
            const name = nodeText(a, &buf) orelse return error.ParseError;
            try r.nl.global_nets.put(r.arena, try r.arena.dupe(u8, name), {});
        },
        .connect => {
            if (args.len != 2) return error.ParseError;
            // ponytail: top level only; a subcircuit's `.connect` needs
            // per-instance aliases.
            for (r.decl.subckts.items) |s| for (r.ast.lines()[s.first..s.end]) |l| if (l.ptr == line.ptr)
                return reader_diag.unsupported(r, line, ".connect inside a subcircuit");
            var bufs: [2][24]u8 = undefined;
            try reader_nets.connect(r, nodeText(args[0], &bufs[0]) orelse return error.ParseError, nodeText(args[1], &bufs[1]) orelse return error.ParseError);
        },
        .save => for (args) |a| try saveItem(r, line, a),
        else => {},
    }
}

/// HSPICE `.mosra k=v ...` [SA Ch.29]. Keys outside `Key` (DEC, LIN,
/// AgingPeriod, AgingInst, ...) and SimMode 1 or 3 are refused.
pub fn readMosra(r: *Reader, line: []const u8, args: []const Value) Error!Mosra {
    var m: Mosra = .{ .line = r.ast.written(line) };
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i] != .name or args[i + 1] != .num) return reader_diag.failed(r, line, error.ParseError);
        const v = args[i + 1].num;
        const Key = enum { reltotaltime, relstarttime, relstep, simmode, relmode, agingstart, agingstop, hcithreshold, nbtithreshold, degf };
        switch (std.meta.stringToEnum(Key, args[i].name) orelse return reader_diag.unsupported(r, line, ".mosra key other than RelTotalTime, RelStartTime, RelStep, SimMode, RelMode, AgingStart, AgingStop, HciThreshold, NbtiThreshold, DegF")) {
            .reltotaltime => m.rel_total_time = v,
            .relstarttime => m.rel_start_time = v,
            .relstep => m.rel_step = v,
            .simmode => m.aged_runs = if (v == 2) true else if (v == 0) false else return reader_diag.unsupported(r, line, ".mosra SimMode other than 0 or 2"),
            .relmode => m.rel_mode = if (v == 0 or v == 1 or v == 2) @intFromFloat(v) else return reader_diag.failed(r, line, error.ParseError),
            .agingstart => m.aging_start = v,
            .agingstop => m.aging_stop = v,
            .hcithreshold => m.hci_threshold = v,
            .nbtithreshold => m.nbti_threshold = v,
            .degf => m.deg_f = v,
        }
    }
    if (i != args.len or !(m.rel_total_time > 0) or !(m.rel_step >= 0) or !(m.rel_start_time >= 0) or !(m.aging_stop > m.aging_start))
        return reader_diag.failed(r, line, error.ParseError);
    return m;
}

/// HSPICE `.sample FS= [TOL=] [NUMF=] [MAXFLD=] [BETA=]` [CR .SAMPLE].
/// TOL and NUMF size HSPICE's adaptive fold count; MAXFLD bounds it
/// here, so they are checked and unused.
pub fn readSample(args: []const Value) Error!core.query.NoiseSample {
    var s: core.query.NoiseSample = .{ .fs = 0 };
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i] != .name or args[i + 1] != .num) return error.ParseError;
        const v = args[i + 1].num;
        const Key = enum { fs, tol, numf, maxfld, beta };
        switch (std.meta.stringToEnum(Key, args[i].name) orelse return error.ParseError) {
            .fs => s.fs = v,
            .maxfld => s.max_fold = v,
            .beta => s.beta = v,
            .tol, .numf => {},
        }
    }
    if (i != args.len or !(s.fs > 0) or !(s.max_fold >= 1) or !(s.beta >= 0 and s.beta <= 1)) return error.ParseError;
    return s;
}

/// The last `.options name=value` number in the deck, null when none
/// sets it.
pub fn option(r: *const Reader, name: []const u8) ?f64 {
    var out: ?f64 = null;
    for (r.deck.config.items) |c| if (!c.temp) for (c.args, 0..) |a, i| {
        if (a == .name and std.ascii.eqlIgnoreCase(a.name, name) and i + 1 < c.args.len and c.args[i + 1] == .num) out = c.args[i + 1].num;
    };
    return out;
}

/// `.option scale` and `wnflag`, which bin selection reads.
pub fn binOptions(r: *Reader) Error!void {
    r.deck.wnflag = false;
    for (r.deck.config.items) |c| {
        if (c.temp) continue;
        for (c.args, 0..) |arg, i| {
            if (arg != .name) continue;
            const is_scale = std.mem.eql(u8, arg.name, "scale");
            if (!is_scale and !std.mem.eql(u8, arg.name, "wnflag")) continue;
            if (i + 1 == c.args.len or c.args[i + 1] != .num) return error.ParseError;
            if (is_scale) r.deck.scale = c.args[i + 1].num else r.deck.wnflag = c.args[i + 1].num != 0;
        }
    }
    if (!(r.deck.scale > 0) or !std.math.isFinite(r.deck.scale)) return error.ParseError;
}

// ---- private ----

/// One item of an ngspice `.save`, as ngspice 44.2 saves it (manual
/// 11.6.1; measured with `-b -r`): `all` and `allv` save everything,
/// a node `n`, `v(n)`, `v(a, b)` and `vm`, `vp`, `vr`, `vdb` of nodes
/// each node, `i(x)` and `x#branch` the branch current, `@dev[p]`
/// the operating-point variable (#236), which `prepare` resolves or
/// refuses. `.save` narrows the output, so an item it cannot read
/// (`alli`, `vi(n)`, a quoted expression) refuses the card rather
/// than drop a vector. Two skips are ngspice's: the operator tail of
/// `v(a)/10`, which saves v(a), and a name nothing publishes, which
/// `prepare` drops (`keepSaved`) where ngspice saves nothing.
fn saveItem(r: *Reader, line: []const u8, a: Value) Error!void {
    var buf: [24]u8 = undefined;
    switch (a) {
        .name => |n| if (std.ascii.eqlIgnoreCase(n, "all") or std.ascii.eqlIgnoreCase(n, "allv")) {
            r.deck.save_all = true;
        } else if (n[0] == '@') {
            const label = try r.arena.dupe(u8, n);
            try r.deck.opvar_saves.append(r.arena, std.ascii.lowerString(label, label));
            // Holds `saves` non-empty, so the probes narrow.
            try r.deck.saves.append(r.arena, label);
        } else if (std.ascii.endsWithIgnoreCase(n, "#branch")) {
            try save(r, 'i', n[0 .. n.len - "#branch".len]);
        } else if (std.ascii.eqlIgnoreCase(n, "alli")) {
            return reader_diag.unsupported(r, line, ".save alli: device terminal currents are not written");
        } else if (!reader_values.operatorLed(n)) try save(r, 'v', n),
        .num => try save(r, 'v', nodeText(a, &buf) orelse return reader_diag.unsupported(r, line, "a .save number that names no node")),
        .group => |g| {
            const voltage = std.StaticStringMap(void).initComptime(.{ .{"v"}, .{"vm"}, .{"vp"}, .{"vr"}, .{"vdb"} });
            var name_buf: [4]u8 = undefined;
            const fun = if (g.name().len <= name_buf.len) std.ascii.lowerString(&name_buf, g.name()) else "";
            const current = std.mem.eql(u8, fun, "i") and g.args().len == 1;
            if (!current and !voltage.has(fun)) return reader_diag.unsupported(r, line, "a .save function other than v, vm, vp, vr, vdb or i");
            for (g.args()) |arg| try save(r, if (current) 'i' else 'v', nodeText(arg, &buf) orelse return reader_diag.unsupported(r, line, "a .save argument that names no node or device"));
        },
        else => return reader_diag.unsupported(r, line, "a .save item other than a node, v(), i(), x#branch, @dev[p], all or allv"),
    }
}

/// Appends the output label `kind(name)`, lowercased, to the saves.
fn save(r: *Reader, kind: u8, name: []const u8) Error!void {
    const label = try r.arena.print("{c}({s})", .{ kind, name });
    try r.deck.saves.append(r.arena, std.ascii.lowerString(label, label));
}

/// ngspice's `.probe` (inpc_probe.c). `v(node)` saves the node as
/// `.save v(node)` does (:375-378); with no `.save` in the deck
/// ngspice adds `.save all` (:66-95), which every output already is.
/// `i()`, `vd()`, `p()`, `alli` and a bare `.probe` insert measuring
/// sources ESPice does not build, so they refuse the card by name
/// rather than lose its vectors. An item led by none of these is
/// skipped with a warning, as ngspice skips it (:118-128, :921-924).
fn ngspiceProbe(r: *Reader, line: []const u8) Error!void {
    var rest = std.mem.trim(u8, line[".probe".len..], " \t");
    var words = std.mem.tokenizeAny(u8, rest, " \t,()");
    while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, "alli")) return reader_diag.unsupported(r, line, "ngspice .probe alli");
    if (rest.len == 0) return reader_diag.unsupported(r, line, "a bare ngspice .probe, which is .probe alli");
    const narrowed = for (r.ast.lines()) |l| {
        if (std.ascii.startsWithIgnoreCase(l, ".save") and !isSaveOp(l)) break true;
    } else false;
    // Items end at their `)`, as ngspice cuts them (gettok_char).
    while (rest.len != 0) {
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len - 1;
        const item = std.mem.trim(u8, rest[0 .. close + 1], " \t");
        rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
        if (std.ascii.startsWithIgnoreCase(item, "vd(") or std.ascii.startsWithIgnoreCase(item, "i(") or std.ascii.startsWithIgnoreCase(item, "p("))
            return reader_diag.unsupported(r, line, "an ngspice .probe of i(), vd() or p(): its measuring sources are not built");
        if (!std.ascii.startsWithIgnoreCase(item, "v(") or item[item.len - 1] != ')') {
            try reader_diag.note(r, .{ .code = .probe_skipped, .subject = r.ast.written(line), .text = item });
            continue;
        }
        var nodes = std.mem.tokenizeAny(u8, item[2 .. item.len - 1], " \t,");
        if (narrowed) while (nodes.next()) |node| try save(r, 'v', node);
    }
}

/// ESPice's operating-point `.save` (HSPICE's [CR .SAVE] spelling):
/// `.save [TYPE=NODESET|IC] [FILE=] [LEVEL=ALL|TOP|SELECT|NONE]
/// [TIME=]`. SELECT saves every node, as ALL; NONE saves nothing.
/// The last card wins. ngspice's `.save` vector list never carries a
/// `key=value` field, so one of these keys selects this reading.
fn readSaveOp(r: *Reader, line: []const u8, f: *F) Error!void {
    var op: core.SaveOp = .{};
    var none_level = false;
    while (f.field()) |key| {
        if (!F.isWord(key) or !f.takeEq()) return reader_diag.failed(r, line, error.ParseError);
        const Key = enum { type, file, level, time };
        switch (std.meta.stringToEnum(Key, key) orelse return reader_diag.failed(r, line, error.ParseError)) {
            .file => op.file = try reader_values.pathOf(r, f),
            .time => op.time = spice_number.spiceNumber(f.field() orelse "") orelse return reader_diag.failed(r, line, error.ParseError),
            .type => {
                const v = f.field() orelse "";
                if (!std.mem.eql(u8, v, "ic") and !std.mem.eql(u8, v, "nodeset")) return reader_diag.failed(r, line, error.ParseError);
                op.ic = std.mem.eql(u8, v, "ic");
            },
            .level => {
                const v = f.field() orelse "";
                const levels = std.StaticStringMap(void).initComptime(.{ .{"all"}, .{"top"}, .{"select"}, .{"none"} });
                if (!levels.has(v)) return reader_diag.failed(r, line, error.ParseError);
                op.top_only = std.mem.eql(u8, v, "top");
                none_level = std.mem.eql(u8, v, "none");
            },
        }
    }
    if (!(op.time >= 0)) return reader_diag.failed(r, line, error.ParseError);
    r.deck.save_op = if (none_level) null else op;
}

/// True when the `.save` card `line` carries a `type=`, `file=`,
/// `level=` or `time=` key: the operating-point save, not ngspice's
/// vector list.
fn isSaveOp(line: []const u8) bool {
    return setsKey(line, "type") or setsKey(line, "file") or setsKey(line, "level") or setsKey(line, "time");
}
