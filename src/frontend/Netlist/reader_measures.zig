//! `.meas`, `.check` and `.stim` cards, the cards that read them (`FAIL=`,
//! `.wcd`), and the measure callbacks measure.zig evaluates values through.
//! Cites: ngspice measure.c, com_measure2.c, manual §11.6 (par());
//! HSPICE [CR] .MEASURE, .STIM; #238-#240.
//!
//! Contents:
//! - `pub fn readMeasures(r: *Reader) Error!void`
//! - `pub fn readStim(r: *Reader, f: *F, serials: *[2]u32) Error!void`
//! - `pub fn measureExpr(r: *Reader, text: []const u8) Error![]const core.MeasureOp`
//! - `pub fn measureOption(r: *Reader, name: []const u8) ?f64`
//! - `pub fn measureValue(r: *Reader, text: []const u8) Error!f64`
//! - `pub fn compileFails(r: *Reader) Error!void`
//! - `pub fn readWcd(r: *Reader, line: []const u8) Error!Wcd`

const std = @import("std");
const Ast = @import("../Ast.zig");
const spice_number = @import("../Parse/spice_number.zig");
const expr = @import("../Parse/expr.zig");
const measure = @import("../Parse/measure.zig");
const core = @import("core");
const assert = std.debug.assert;
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const reader_frame = @import("reader_frame.zig");
const reader_values = @import("reader_values.zig");
const reader_diag = @import("reader_diag.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const Wcd = card_rows.Wcd;
const WcdSpec = card_rows.WcdSpec;
const Frame = reader_frame.Frame;

/// Parses the `.meas` cards in deck order. A card that cannot be
/// read refuses the deck, naming it: a skipped card is an output
/// silently lost. A `.meas` card ngspice itself skips is skipped
/// with a warning (`ngspiceSkips`).
pub fn readMeasures(r: *Reader) Error!void {
    var checks: u32 = 0;
    var stims: [2]u32 = @splat(0);
    var global_level: ?measure.Levels = null;
    // `measureExpr` names `r.card` when it refuses one; the passes
    // after this one read no one card.
    defer r.diag.card = "";
    for (r.deck.meas_lines.items) |line| {
        r.diag.card = line;
        var f = try F.initLine(r.arena, line);
        const head = f.field().?[1..];
        if (std.mem.eql(u8, head, "check") or std.mem.eql(u8, head, "dout") or std.mem.eql(u8, head, "biaschk")) {
            const n = r.deck.measures.items.len;
            measure.parseCheck(r.arena, head, f.rest(), r, &global_level, checks + 1, &r.deck.measures) catch |err| return refuse(r, line, err);
            if (r.deck.measures.items.len > n) checks += 1;
            continue;
        }
        if (std.mem.eql(u8, head, "stim")) {
            readStim(r, &f, &stims) catch |err| return refuse(r, line, err);
            continue;
        }
        const text = f.rest();
        if (ngspiceSkips(text)) {
            try reader_diag.note(r, .{ .code = .meas_skipped, .subject = r.ast.written(line) });
            continue;
        }
        const m = measure.parse(r.arena, text, r, null, false) catch |err| return refuse(r, line, err);
        try r.deck.measures.append(r.arena, m);
    }
}

/// HSPICE `.stim [tran] pwl|data [filename=] [dataname] [name=]ovar
/// [node1= node2=] ... [from= to= npoints= | indepvar=(t ...)]
/// [indepout]` [CR .STIM]. Each signal is read as a `find` measure.
/// A signal with no name takes its output variable's, `v(a)` as
/// `v_a`; a `par()` one must be named, and a PWL source's name says
/// V or I. A PWL source of `v(a[,b])` defaults to terminals a and b
/// (else 0). The AC, DC and VEC forms are a ParseError.
pub fn readStim(r: *Reader, f: *F, serials: *[2]u32) Error!void {
    var form = f.field() orelse return error.ParseError;
    if (std.mem.eql(u8, form, "tran")) form = f.field() orelse return error.ParseError;
    const data = std.mem.eql(u8, form, "data");
    if (!data and !std.mem.eql(u8, form, "pwl")) return error.ParseError;
    var stim: core.Stim = .{ .data = data, .serial = serials[@intFromBool(data)] };
    var signals: std.ArrayList(core.Measure) = .empty;
    var nodes: std.ArrayList([2][]const u8) = .empty;
    var times: std.ArrayList(f64) = .empty;
    const Key = enum { filename, node1, node2, from, to, npoints, indepvar, indepout };
    var name: ?[]const u8 = null;
    while (f.peek()) |t| {
        const start = f.pos;
        _ = f.field();
        const key = if (F.isWord(t) and f.takeEq()) t else null;
        if (key == null and std.mem.eql(u8, t, "indepout")) {
            stim.indepout = true;
            continue;
        }
        const field = if (key) |k| std.meta.stringToEnum(Key, k) else null;
        if (field) |which| switch (which) {
            .filename => stim.file = try reader_values.pathOf(r, f),
            .node1, .node2 => {
                const node = f.field() orelse return error.ParseError;
                if (nodes.items.len == 0) return error.ParseError;
                nodes.items[nodes.items.len - 1][@intFromBool(which == .node2)] = node;
            },
            .from, .to => {
                const v = spice_number.spiceNumber(f.field() orelse "") orelse return error.ParseError;
                if (which == .from) stim.from = v else stim.to = v;
            },
            .npoints => stim.npoints = std.math.lossyCast(u32, spice_number.spiceNumber(f.field() orelse "") orelse return error.ParseError),
            .indepvar => {
                const paren = f.peek() != null and f.peek().?[0] == '(';
                if (paren) _ = f.field();
                while (f.peek()) |v| {
                    if (v[0] == ')') {
                        _ = f.field();
                        break;
                    }
                    const x = spice_number.spiceNumber(v) orelse if (paren) return error.ParseError else break;
                    _ = f.field();
                    try times.append(r.arena, x);
                }
            },
            .indepout => {
                const v = f.field() orelse "";
                stim.indepout = !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "off");
            },
        } else if (key) |k| {
            name = k;
        } else if (data and stim.dataname.len == 0 and signals.items.len == 0 and f.peek() != null and f.peek().?[0] != '(') {
            stim.dataname = t;
        } else {
            // An output variable: `v(a)`, `i(r1)`, `par('...')`.
            if (f.nextByte() == '(') while (f.field()) |p| if (p[0] == ')') break;
            const ovar = std.mem.trim(u8, f.line[start..f.pos], " \t");
            const text = try r.arena.print("tran s find {s} at=0", .{ovar});
            var m = try measure.parse(r.arena, text, r, .tran, true);
            m.name = name orelse blk: {
                if (m.first.ops.len != 0) return error.ParseError;
                const own = try r.arena.dupe(u8, ovar);
                for (own) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
                    c.* = '_';
                };
                break :blk std.mem.trimEnd(u8, own, "_");
            };
            name = null;
            if (m.name.len == 0 or (!data and m.name[0] != 'v' and m.name[0] != 'i')) return error.ParseError;
            var pair: [2][]const u8 = .{ "", "0" };
            if (std.mem.startsWith(u8, ovar, "v(") and std.mem.endsWith(u8, ovar, ")")) {
                var it = std.mem.tokenizeAny(u8, ovar[2 .. ovar.len - 1], ", ");
                pair[0] = it.next() orelse "";
                pair[1] = it.next() orelse "0";
            }
            try signals.append(r.arena, m);
            try nodes.append(r.arena, pair);
        }
    }
    if (signals.items.len == 0 or (data and stim.dataname.len == 0)) return error.ParseError;
    if (!data) for (nodes.items) |pair| if (pair[0].len == 0) return error.ParseError;
    stim.signals = signals.items;
    stim.nodes = nodes.items;
    stim.times = times.items;
    serials[@intFromBool(data)] += 1;
    try r.deck.stims.append(r.arena, stim);
}

/// A `PARAM=` or `par()` measure expression in postfix, read as
/// ngspice reads it: numparam over the deck's parameters and the
/// results so far (measure.c:459-466), a B source's expression for
/// `par()` (manual §11.6). Each largest part that reads no result
/// folds to a number now, as a `.param` value does, `.func` calls
/// and built-ins included. What stays reads earlier `.meas` results
/// by name, `v(a[,b])`, `i(x)`, `time` (the scale) and `soa_count()`
/// (#238), through arithmetic, comparisons, logic and `c ? a : b`.
/// A function, `%` or `\` of a result, or a name that is neither a
/// result nor a parameter, refuses the card `r.card`. The ops live
/// in the arena.
pub fn measureExpr(r: *Reader, text: []const u8) Error![]const core.MeasureOp {
    const body = if (text.len > 0 and (text[0] == '{' or F.isQuote(text[0]))) F.body(text) else text;
    const mark = r.eval.scratch.mark();
    defer r.eval.scratch.reset(mark);
    try expr.compileAll(r.arena, &r.eval.scratch, body);
    // Copies: folding a part below appends to the scratch.
    const ops = try r.arena.dupe(expr.Op, r.eval.scratch.ops.items[mark.ops..]);
    const names = try r.arena.dupe([]const u8, r.eval.scratch.names.items);
    // Which ops read a result, and the op that takes each one.
    const reads = try r.arena.alloc(bool, ops.len);
    const parent = try r.arena.alloc(usize, ops.len);
    var open: std.ArrayList(usize) = .empty;
    for (ops, 0..) |op, k| {
        reads[k] = switch (op.code) {
            .vprobe, .iprobe => true,
            .ident => measureIndex(r, names[op.a]) != null or std.mem.eql(u8, names[op.a], "time"),
            .ucall => op.b == 0 and std.ascii.eqlIgnoreCase(names[op.a], "soa_count"),
            else => false, // else: a constant, or an operator that reads what its operands read
        };
        for (0..expr.arity(op)) |_| {
            const c = open.pop().?;
            parent[c] = k;
            reads[k] = reads[k] or reads[c];
        }
        try open.append(r.arena, k);
    }
    assert(open.items.len == 1);
    var out: std.ArrayList(core.MeasureOp) = .empty;
    for (ops, 0..) |op, k| {
        if (!reads[k]) {
            if (k + 1 == ops.len or reads[parent[k]]) try out.append(r.arena, .{ .num = try foldPart(r, ops[expr.subtreeStart(ops, k) .. k + 1]) });
            continue;
        }
        try out.append(r.arena, switch (op.code) {
            .vprobe, .iprobe => {
                const letter = if (op.code == .vprobe) "v" else "i";
                try out.append(r.arena, .{ .vector = try r.arena.print("{s}({s})", .{ letter, names[op.a] }) });
                if (op.b == expr.none) continue;
                try out.append(r.arena, .{ .vector = try r.arena.print("{s}({s})", .{ letter, names[op.b] }) });
                try out.append(r.arena, .sub);
                continue;
            },
            .ident => if (measureIndex(r, names[op.a])) |i| .{ .measure = i } else .{ .vector = "time" },
            .ucall => if (op.b == 0) .soa_count else return reader_diag.unsupported(r, r.diag.card, try r.arena.print("a call of '{s}' on a .meas result or vector", .{names[op.a]})),
            .call => if (op.a == @backingInt(expr.Fn.ternary) and op.b == 3) .ternary else return reader_diag.unsupported(r, r.diag.card, "a built-in function of a .meas result or vector"),
            .neg => .neg,
            .not => .not,
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .pow => .pow,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            .@"and" => .@"and",
            .@"or" => .@"or",
            .mod, .idiv => return reader_diag.unsupported(r, r.diag.card, "% or \\ of a .meas result or vector"),
            // A number reads no result; only `subst` emits `live`.
            .num, .live => unreachable,
        });
    }
    return out.items;
}

/// A numeric `.option name=value`, the last one given; null when no
/// card sets it. `name` matches byte for byte, unlike `option`.
pub fn measureOption(r: *Reader, name: []const u8) ?f64 {
    var found: ?f64 = null;
    for (r.deck.config.items) |c| if (!c.temp) for (c.args, 0..) |a, i| {
        if (a != .name or i + 1 >= c.args.len or !std.mem.eql(u8, a.name, name)) continue;
        if (c.args[i + 1] == .num) found = c.args[i + 1].num;
    };
    return found;
}

/// A `.meas` value: a number or a global parameter expression.
/// ParseError for empty text or one that does not fold.
pub fn measureValue(r: *Reader, text: []const u8) Error!f64 {
    if (text.len == 0) return error.ParseError;
    if (spice_number.spiceNumber(text)) |n| return n;
    const body = if (text[0] == '{' or F.isQuote(text[0])) F.body(text) else text;
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    return switch (try reader_values.exprValue(r, body, &top, false)) {
        .num => |n| n,
        else => error.ParseError,
    };
}

/// Compiles each SIGMA_SCALE card's FAIL now that every `.meas`
/// card is read: a name reads that card's value (`.live`, its index
/// in `measures`). A name of no card of the analysis, a probe, a
/// distribution or an unknown function is refused, as is a second
/// MONTE card of the analysis (its trials would count too).
pub fn compileFails(r: *Reader) Error!void {
    for (r.deck.analyses.items, 0..) |*a, i| {
        if (a.sweep != .monte or a.sweep.monte.scales.len == 0) continue;
        for (r.deck.analyses.items, 0..) |b, j| if (j != i and b.kind == a.kind and b.sweep == .monte)
            return reader_diag.unsupported(r, a.line, "SIGMA_SCALE beside another MONTE card of its analysis");
        const fail = &a.sweep.monte.fail;
        const mark = r.eval.scratch.mark();
        defer r.eval.scratch.reset(mark);
        expr.compileAll(r.arena, &r.eval.scratch, fail.text) catch |err| return reader_diag.failed(r, a.line, err);
        const ops = try r.arena.dupe(expr.Op, r.eval.scratch.ops.items[mark.ops..]);
        const names = r.eval.scratch.names.items;
        for (ops) |*op| switch (op.code) {
            .ident => op.* = .{ .code = .live, .a = for (r.deck.measures.items, 0..) |m, k| {
                if (m.analysis == a.kind and std.mem.eql(u8, m.name, names[op.a])) break @intCast(k);
            } else return reader_diag.unsupported(r, a.line, "FAIL names no .meas card of its analysis") },
            .vprobe, .iprobe, .ucall => return reader_diag.unsupported(r, a.line, "FAIL reads its analysis's .meas cards, not vectors or unknown functions"),
            .call => if (expr.isDistribution(@fromBackingInt(@intCast(op.a)))) return reader_diag.unsupported(r, a.line, "a distribution in FAIL"),
            else => {}, // else: numbers, arithmetic, comparisons, logic and math calls
        };
        fail.ops = ops;
        fail.consts = try r.arena.dupe(f64, r.eval.scratch.consts.items);
    }
}

/// The `.wcd` card `line` (#240), now that every `.meas` card is
/// read: `name 'op number'` pairs, op one of `>=`, `>`, `<=`, `<`
/// and the number as a `.meas` value, then `MAXITER=`, `TOL=` and
/// `TOP=`. Refuses a name of no `.meas` card, a card named twice and
/// SWEEP OPTIMIZE (whose variant table it would share).
pub fn readWcd(r: *Reader, line: []const u8) Error!Wcd {
    r.diag.card = line;
    if (r.deck.optimize != null) return reader_diag.unsupported(r, line, ".wcd together with SWEEP OPTIMIZE");
    var w: Wcd = .{ .specs = &.{}, .line = r.ast.written(line) };
    var specs: std.ArrayList(WcdSpec) = .empty;
    var f = try F.initLine(r.arena, line);
    _ = f.field(); // the card
    while (f.field()) |t| {
        if (!F.isWord(t)) return reader_diag.failed(r, line, error.ParseError);
        if (f.takeEq()) {
            const v = spice_number.spiceNumber(f.field() orelse return reader_diag.failed(r, line, error.ParseError)) orelse return reader_diag.failed(r, line, error.ParseError);
            const count = v >= 1 and v <= 1e6 and v == @floor(v);
            if (std.mem.eql(u8, t, "maxiter") and count) {
                w.maxiter = @intFromFloat(v);
            } else if (std.mem.eql(u8, t, "top") and (count or v == 0)) {
                w.top = @intFromFloat(v);
            } else if (std.mem.eql(u8, t, "tol") and v > 0 and v < std.math.inf(f64)) {
                w.tol = v;
            } else return reader_diag.failed(r, line, error.ParseError);
            continue;
        }
        const card: u32 = for (r.deck.measures.items, 0..) |m, k| {
            if (std.mem.eql(u8, m.name, t)) break @intCast(k);
        } else return reader_diag.unsupported(r, line, "a .wcd spec that names no .meas card");
        for (specs.items) |s| if (s.measure == card) return reader_diag.unsupported(r, line, "a .meas card named twice in .wcd");
        const q = f.field() orelse return reader_diag.failed(r, line, error.ParseError);
        if (!F.isQuote(q[0]) and q[0] != '{') return reader_diag.failed(r, line, error.ParseError);
        const rel = std.mem.trim(u8, F.body(q), " \t");
        const above = rel.len != 0 and rel[0] == '>';
        if (!above and !(rel.len != 0 and rel[0] == '<')) return reader_diag.failed(r, line, error.ParseError);
        const op_len: usize = if (rel.len > 1 and rel[1] == '=') 2 else 1;
        const limit = measureValue(r, std.mem.trim(u8, rel[op_len..], " \t")) catch |err| return reader_diag.failed(r, line, err);
        if (!std.math.isFinite(limit)) return reader_diag.failed(r, line, error.ParseError);
        try specs.append(r.arena, .{ .measure = card, .above = above, .limit = limit, .bound = rel });
    }
    if (specs.items.len == 0) return reader_diag.failed(r, line, error.ParseError);
    w.specs = specs.items;
    return w;
}

// ---- private ----

/// Refuses output card `line` with `err`, recording it unless a
/// refusal already named a card.
fn refuse(r: *Reader, line: []const u8, err: Error) Error {
    if (err == error.OutOfMemory or r.diag.refusals > 0) return err;
    return reader_diag.failed(r, line, err);
}

/// Whether ngspice skips the `.meas` card `text` (after `.meas`):
/// one missing its analysis type, result name or measurement type
/// ("Incomplete measurement statement ... ignored!",
/// measure.c:286-301), or one whose analysis type it does not
/// measure (measure.c:302-311). Words split as misc/string.c
/// gettok splits them, at blanks and commas. Analysis types
/// `measure.parse` reads beyond tran, ac, dc and sp are kept.
fn ngspiceSkips(text: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t,");
    const kind = words.next() orelse return true;
    if (words.next() == null or words.next() == null) return true;
    return !measure.knowsAnalysis(kind);
}

/// The index of the `.meas` card named `name` read so far.
fn measureIndex(r: *const Reader, name: []const u8) ?u32 {
    for (r.deck.measures.items, 0..) |m, i| if (std.mem.eql(u8, m.name, name)) return @intCast(i);
    return null;
}

/// The number compiled ops `part` fold to, as a `.param` value
/// would; `part` indexes the scratch's names and constants. A name
/// that is no parameter refuses the card `r.card`.
fn foldPart(r: *Reader, part: []const expr.Op) Error!f64 {
    const from = r.eval.scratch.ops.items.len;
    defer r.eval.scratch.ops.shrinkRetainingCapacity(from);
    try r.eval.scratch.ops.appendSlice(r.arena, part);
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    return switch (try reader_values.fold(r, from, &top, false)) {
        .num => |n| n,
        // else: a name no scope defines leaves a kept expression
        else => reader_diag.unsupported(r, r.diag.card, "a .meas expression name that is no earlier .meas result and no .param"),
    };
}
