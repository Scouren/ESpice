//! The row and lowering of `.meas`, and the measurement expressions the
//! checks share. A measurement is an expression of one of three shapes.
//! In: a bound `.meas kind name = expression [goal=] [goal_bound=]
//! [weight=] [minval=]`. Out: the legacy `.meas` card: one measurement
//! call as its function's card (`when`, `find`, `avg`, ...), `cross(a) -
//! cross(b)` as `trig b targ a`, and arithmetic over parameters and
//! earlier results as `param='...'`; a signal that is no probe as
//! `par('...')`. A measurement call anywhere else is refused: it would
//! need a hidden intermediate measurement, which the reader would print.
//! Cites: docs/using/language.md "Measurements"; src/frontend/Parse/
//! measure.zig (every form the reader takes; its `when` reads a level
//! holding `(` as a signal; a bare `find` reads only a one-row plot);
//! Netlist/reader_measures.zig `measureExpr` (a `**` reading a result or
//! a waveform is C's pow, a part reading neither folds as a `.param`
//! does, and a function, `%` or `\` of a result is refused).
//!
//! Contents:
//! - `pub const rows`
//! - `pub const Mode`
//! - `pub fn signal(l: *Lowerer, node: Index, par: bool, before: u32) Allocator.Error!void`
//! - `pub fn writeExpr(l: *Lowerer, node: Index, mode: Mode, before: u32) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const check = @import("check.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Ast = ast.Ast;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;
const Index = ast.Index;

/// This area's rows of the directive table.
pub const rows = .{
    .meas = Row{
        .subjects = &.{.{ .key = "kind", .ty = .word, .words = &kinds, .need = .required }},
        .keys = &meas_keys,
        .open = true,
        .lower = meas,
    },
};

/// Where an expression stands in a measurement.
pub const Mode = enum(u1) {
    /// A signal: `v()`, `i()` and `time` read the result's waveforms.
    signal,
    /// A value, a level or a `PARAM=`: parameters and earlier results.
    value,
};

const kinds = [_][]const u8{
    "tran", "ac",         "dc",       "sp", "fft",       "trannoise", "dcmatch", "acmatch",
    "lstb", "phasenoise", "ptdnoise", "op", "tran_cont", "ac_cont",   "dc_cont",
};

const meas_keys = [_]Slot{
    .{ .key = "goal", .ty = .expr },
    .{ .key = "goal_bound", .ty = .word, .words = &.{ "equal", "below", "above" } },
    .{ .key = "weight", .ty = .real },
    .{ .key = "minval", .ty = .expr },
};

/// The measurement functions; `at` stands only in a `cross` difference.
const Func = enum(u8) {
    cross,
    find,
    deriv,
    avg,
    rms,
    integ,
    min,
    max,
    pp,
    min_at,
    max_at,
    err,
    err1,
    err2,
    err3,
    thd,
    snr,
    sndr,
    enob,
    sfdr,
    em_avg,
    jitter,
    gain_margin,
    phase_margin,
    phase_crossover_freq,
    unity_gain_freq,
    loop_gain_minifreq,
    at,
};

/// One function's positional arguments (signals first), its keys, the
/// result kinds it reads (empty: any), and whether a signal may be an
/// expression (`par('...')`; the reader keeps FFT and ERR signals bare).
const Sig = struct { args: u2, keys: []const []const u8, kinds: []const []const u8 = &.{}, par: bool = true };

const window = [_][]const u8{ "from", "to" };
const edges = [_][]const u8{ "rise", "fall", "cross", "td", "from", "to" };
const fft = Sig{ .args = 1, .keys = &.{ "nbharm", "minfreq", "maxfreq", "binsiz" }, .kinds = &.{"fft"}, .par = false };
const err = Sig{ .args = 2, .keys = &.{ "from", "to", "ymin", "ymax" }, .par = false };
const margin = Sig{ .args = 0, .keys = &.{}, .kinds = &.{"lstb"} };
const at_when = Sig{ .args = 1, .keys = &.{ "at", "when" } };
const over = Sig{ .args = 1, .keys = &window };

const sigs = std.EnumArray(Func, Sig).init(.{
    .cross = .{ .args = 2, .keys = &edges },
    .find = at_when,
    .deriv = at_when,
    .avg = over,
    .rms = over,
    .integ = over,
    .min = over,
    .max = over,
    .pp = over,
    .min_at = over,
    .max_at = over,
    .err = err,
    .err1 = err,
    .err2 = err,
    .err3 = err,
    .thd = fft,
    .snr = fft,
    .sndr = fft,
    .enob = fft,
    .sfdr = fft,
    .em_avg = .{ .args = 1, .keys = &window, .kinds = &.{"tran"} },
    .jitter = .{ .args = 2, .keys = &.{ "rise", "fall", "cross", "td" }, .kinds = &.{ "tran", "trannoise" } },
    .gain_margin = margin,
    .phase_margin = margin,
    .phase_crossover_freq = margin,
    .unity_gain_freq = margin,
    .loop_gain_minifreq = margin,
    .at = .{ .args = 1, .keys = &.{} },
});

/// Probes a signal takes as written; in a `par()` only `v` and `i`.
const probes = std.StaticStringMap(void).initComptime(.{
    .{"v"}, .{"i"}, .{"vdb"}, .{"vm"}, .{"vp"}, .{"vr"}, .{"vi"}, .{"lstb"},
});

/// Which crossing clause is being written: a `when`, or the trigger or
/// target of a difference (only the target takes `td=trig`).
const Role = enum(u2) { when, trigger, target };

/// The statement being lowered: its result kind without `_cont`, and its
/// offset (results named before it are earlier measurements).
const M = struct { l: *Lowerer, kind: []const u8, before: u32 };

/// Writes a signal: a probe or a result column (a word) as written,
/// anything else as `par('...')` when `par`, else a refusal.
pub fn signal(l: *Lowerer, node: Index, par: bool, before: u32) Allocator.Error!void {
    const a = l.a;
    switch (a.tag(node)) {
        .word => return l.putName(node),
        .call => if (probes.has(a.callee(node))) return l.putProbe(node),
        else => {},
    }
    if (!par) return l.diags.add(.no_legacy, a.at(node), "an expression as this function's signal");
    try l.put("par('");
    try writeExpr(l, node, .signal, before);
    try l.put("')");
}

/// Writes `node` as the reader's measurement expression, unquoted: a part
/// reading no result or waveform as a `.param` expression, the rest with
/// `**` for the power and every operand grouped. A probe or `time` in a
/// `value`, a measurement call, and what the reader refuses of a result
/// (a function, `%`) are coded rows.
pub fn writeExpr(l: *Lowerer, node: Index, mode: Mode, before: u32) Allocator.Error!void {
    if (nested(l.a, node)) |call| {
        try l.diags.add(.meas_nested, l.a.at(call), l.a.callee(call));
        return l.put("0");
    }
    try term(l, node, mode, before);
}

// ---- private ----

/// `.meas kind name = expression ...` is `.meas kind name <form>
/// [goal=[<|>]g] [weight=] [minval=]`.
fn meas(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.subjects.len != 1) return; // bind reported it
    if (b.open.len != 1) return l.diags.add(.arity, a.at(b.stmt), "one name = expression");
    const name = a.node(b.open[0]).lhs;
    const e = a.node(b.open[0]).rhs;
    if (a.tag(name) != .word) return l.diags.add(.wrong_kind, a.at(name), a.text(name));
    const kind = a.text(b.subjects[0]);
    const m: M = .{ .l = l, .kind = kind[0 .. std.mem.indexOf(u8, kind, "_cont") orelse kind.len], .before = a.at(b.stmt) };
    try l.print(".meas {s} ", .{kind});
    try l.putName(name);
    var trailing = true;
    if (measCall(a, e)) |f| {
        trailing = try function(m, e, f);
    } else if (difference(a, e)) {
        try l.put(" trig");
        try clause(m, a.node(e).rhs, .trigger);
        try l.put(" targ");
        try clause(m, a.node(e).lhs, .target);
    } else {
        try l.put(" param='");
        try writeExpr(l, e, .value, m.before);
        try l.put("'");
    }
    const goal, const bound, const weight, const minval = b.keys[0..4].*;
    if (!trailing and (goal != ast.none or weight != ast.none or minval != ast.none))
        return l.diags.add(.no_legacy, a.at(b.stmt), "goal=, weight= or minval= on a bare find");
    if (goal != ast.none) {
        try l.put(" goal=");
        if (bound != ast.none) try l.put(switch (a.text(bound)[0]) {
            'a' => ">",
            'b' => "<",
            else => "",
        });
        try value(m, goal);
    } else if (bound != ast.none) try l.diags.add(.missing_key, a.at(bound), "goal");
    if (weight != ast.none) try keyed(m, " weight=", weight);
    if (minval != ast.none) try keyed(m, " minval=", minval);
    try l.endCard();
}

/// Writes one measurement call's card. False when nothing may follow it
/// (a bare `find` of a one-row plot).
fn function(m: M, call: Index, f: Func) Allocator.Error!bool {
    const l = m.l;
    const a = l.a;
    const sig = sigs.get(f);
    if (sig.kinds.len > 0 and !has(sig.kinds, m.kind)) {
        try l.diags.add(.meas_function, a.at(call), a.callee(call));
        return true;
    }
    const args = positional(a, call);
    if (args.len != sig.args) {
        try l.diags.add(.arity, a.at(call), a.callee(call));
        return true;
    }
    switch (f) {
        .at => try l.diags.add(.misplaced, a.at(call), "at() outside cross(...) - at(...)"),
        .cross => {
            try l.put(" when ");
            try crossing(m, call, .when);
        },
        .gain_margin, .phase_margin, .phase_crossover_freq, .unity_gain_freq, .loop_gain_minifreq => {
            try l.print(" find {s}", .{@tagName(f)});
            return false;
        },
        .jitter => {
            try l.put(" jitter trig ");
            try signal(l, args[0], true, m.before);
            try l.put(" val=");
            try value(m, args[1]);
            try keys(m, call, f, .trigger);
        },
        else => {
            try l.print(" {s}", .{@tagName(f)});
            for (args) |s| {
                try l.put(" ");
                try signal(l, s, sig.par, m.before);
            }
            try keys(m, call, f, .when);
            if (f != .find and f != .deriv) return true;
            if (key(a, call, "at") != null and key(a, call, "when") != null)
                try l.diags.add(.repeated_key, a.at(call), "at and when");
            if (key(a, call, "at") != null or key(a, call, "when") != null) return true;
            if (f == .deriv) try l.diags.add(.missing_key, a.at(call), "at or when");
            if (f == .find and !has(&.{ "dcmatch", "lstb", "op" }, m.kind)) try l.diags.add(.meas_function, a.at(call), "find with neither at nor when");
            return false;
        },
    }
    return true;
}

/// A trigger or target of a difference: `at(x)` is `at=x`; `cross(sig,
/// v, ...)` is `sig val=v ...`, which needs a count; its level is a value
/// (the reader's `val=` takes no signal).
fn clause(m: M, call: Index, role: Role) Allocator.Error!void {
    const a = m.l.a;
    const args = positional(a, call);
    if (args.len != sigs.get(measCall(a, call).?).args) return m.l.diags.add(.arity, a.at(call), a.callee(call));
    if (measCall(a, call).? == .at) return keyed(m, " at=", args[0]);
    if (key(a, call, "rise") == null and key(a, call, "fall") == null and key(a, call, "cross") == null)
        try m.l.diags.add(.missing_key, a.at(call), "rise, fall or cross");
    try m.l.put(" ");
    try signal(m.l, args[0], true, m.before);
    try keyed(m, " val=", args[1]);
    try keys(m, call, .cross, role);
}

/// `cross(sig, level, ...)` as a `when` clause: `sig=level ...`. A level
/// reading a waveform is a signal; a value holding `(` is written as the
/// constant signal `par('...')`, since the reader takes any `(` there for
/// a signal's.
fn crossing(m: M, call: Index, role: Role) Allocator.Error!void {
    const l = m.l;
    const a = l.a;
    if (measCall(a, call) != .cross) return l.diags.add(.wrong_kind, a.at(call), "when= takes cross(...)");
    const args = positional(a, call);
    if (args.len != 2) return l.diags.add(.arity, a.at(call), a.callee(call));
    try signal(l, args[0], true, m.before);
    try l.put("=");
    if (reads(l, args[1], 0)) {
        try signal(l, args[1], true, m.before);
    } else {
        const start = l.out.items.len;
        try value(m, args[1]);
        if (std.mem.indexOfScalar(u8, l.out.items[start..], '(') != null) {
            try l.out.insertSlice(l.arena, start, "par(");
            try l.put(")");
        }
    }
    try keys(m, call, .cross, role);
}

/// The keyed arguments of `call`, in the order written.
fn keys(m: M, call: Index, f: Func, role: Role) Allocator.Error!void {
    const l = m.l;
    const a = l.a;
    var counted = false;
    for (a.children(call)) |arg| {
        if (a.tag(arg) != .setting) continue;
        const k = a.node(arg).lhs;
        const v = a.node(arg).rhs;
        const name = a.text(k);
        if (a.tag(k) != .word or !has(sigs.get(f).keys, name)) {
            try l.diags.add(.unknown_key, a.at(k), name);
            continue;
        }
        if (std.mem.eql(u8, name, "when")) {
            try l.put(" when ");
            try crossing(m, v, .when);
            continue;
        }
        const count = has(&.{ "rise", "fall", "cross" }, name);
        if (count and counted) try l.diags.add(.repeated_key, a.at(k), "rise, fall and cross");
        counted = counted or count;
        try l.print(" {s}=", .{name});
        if (count and isWord(a, v, "last")) {
            try l.put("last");
        } else if (std.mem.eql(u8, name, "td") and isWord(a, v, "trig")) {
            if (role != .target) try l.diags.add(.misplaced, a.at(v), "td=trig outside the target of a difference");
            try l.put("trig");
        } else {
            if (count or has(&.{ "nbharm", "binsiz" }, name)) try check.value(l, .{ .key = name, .ty = .integer }, v);
            try value(m, v);
        }
    }
}

/// ` key=` and the value.
fn keyed(m: M, prefix: []const u8, v: Index) Allocator.Error!void {
    try m.l.put(prefix);
    try value(m, v);
}

/// A value: a literal or a name bare, anything else in quotes.
fn value(m: M, v: Index) Allocator.Error!void {
    const bare = expr.isLiteral(m.l.a, v) or m.l.a.tag(v) == .word;
    if (!bare) try m.l.put("'");
    try writeExpr(m.l, v, .value, m.before);
    if (!bare) try m.l.put("'");
}

fn term(l: *Lowerer, node: Index, mode: Mode, before: u32) Allocator.Error!void {
    const a = l.a;
    if (!reads(l, node, before)) return expr.write(l, node, .param);
    const n = a.node(node);
    switch (n.tag) {
        .word => {
            if (mode == .value and std.mem.eql(u8, a.text(node), "time")) try l.diags.add(.meas_signal, a.at(node), "time");
            try l.put(a.text(node));
        },
        .unary => {
            try l.put(a.tokenText(n.main));
            try group(l, n.lhs, mode, before);
        },
        .binary => {
            if (a.tokenTag(n.main) == .percent) {
                try l.diags.add(.no_legacy, a.at(node), "% of a result or a waveform");
                return l.put("0");
            }
            try group(l, n.lhs, mode, before);
            try l.put(a.tokenText(n.main));
            try group(l, n.rhs, mode, before);
        },
        .ternary => {
            try group(l, n.lhs, mode, before);
            try l.put("?");
            try group(l, a.extra[n.rhs], mode, before);
            try l.put(":");
            try group(l, a.extra[n.rhs + 1], mode, before);
        },
        .paren => try group(l, n.lhs, mode, before),
        .call => try readingCall(l, node, mode, before),
        .number, .string, .list, .tuple, .group, .setting, .instance, .directive, .row => unreachable, // reads() is false
    }
}

/// An operand: a leaf or a call bare, anything else in parentheses.
fn group(l: *Lowerer, node: Index, mode: Mode, before: u32) Allocator.Error!void {
    const bare = switch (l.a.tag(node)) {
        .number, .word, .call => true,
        else => false,
    };
    if (!bare) try l.put("(");
    try term(l, node, mode, before);
    if (!bare) try l.put(")");
}

/// A call reading a result or a waveform: `v()` and `i()` as written,
/// `soa_count()`, and `pow(x, y)` as `x**y`; the reader refuses others.
fn readingCall(l: *Lowerer, node: Index, mode: Mode, before: u32) Allocator.Error!void {
    const a = l.a;
    const f = a.callee(node);
    const args = a.children(node);
    if (std.mem.eql(u8, f, "v") or std.mem.eql(u8, f, "i")) {
        if (mode == .value) try l.diags.add(.meas_signal, a.at(node), f);
        return l.putProbe(node);
    }
    if (std.mem.eql(u8, f, "soa_count") and args.len == 0) return l.put("soa_count()");
    if (std.mem.eql(u8, f, "pow") and args.len == 2 and a.tag(args[1]) != .setting) {
        try group(l, args[0], mode, before);
        try l.put("**");
        return group(l, args[1], mode, before);
    }
    try l.diags.add(.no_legacy, a.at(node), f);
    try l.put("0");
}

/// Whether `node` reads a waveform (a probe, `time`), `soa_count()`, or
/// a result named by a `.meas` before offset `before` (0: none).
/// Recursion is bounded by the parser's depth cap.
fn reads(l: *const Lowerer, node: Index, before: u32) bool {
    const a = l.a;
    const n = a.node(node);
    return switch (n.tag) {
        .word => std.mem.eql(u8, a.text(node), "time") or (before > 0 and isResult(a, a.root, a.text(node), before)),
        .call => probes.has(a.callee(node)) or std.mem.eql(u8, a.callee(node), "soa_count") or for (a.children(node)) |c| {
            if (reads(l, if (a.tag(c) == .setting) a.node(c).rhs else c, before)) break true;
        } else false,
        .unary, .paren => reads(l, n.lhs, before),
        .binary => reads(l, n.lhs, before) or reads(l, n.rhs, before),
        .ternary => reads(l, n.lhs, before) or reads(l, a.extra[n.rhs], before) or reads(l, a.extra[n.rhs + 1], before),
        .number, .string, .list, .tuple, .group, .setting, .instance, .directive, .row => false,
    };
}

/// Whether a `.meas` in `r`, or a block in it, before offset `before`
/// names its result `word`.
/// ponytail: rescans the file per name, O(names x statements); a name set
/// built once per file if decks with thousands of `.meas` appear.
fn isResult(a: *const Ast, r: ast.Range, word: []const u8, before: u32) bool {
    for (a.span(r)) |s| {
        if (a.at(s) >= before) return false;
        if (a.tag(s) != .directive) continue;
        const st = a.statement(s);
        if (st.has_block and isResult(a, st.block, word, before)) return true;
        if (!std.mem.eql(u8, a.text(s), ".meas")) continue;
        // The name is the statement's first setting.
        for (a.span(st.items)) |it| if (a.tag(it) == .setting) {
            const k = a.node(it).lhs;
            if (a.tag(k) == .word and std.ascii.eqlIgnoreCase(a.text(k), word)) return true;
            break;
        };
    }
    return false;
}

/// The first measurement call in `node`, or null. Recursion is bounded
/// by the parser's depth cap.
fn nested(a: *const Ast, node: Index) ?Index {
    if (measCall(a, node) != null) return node;
    const n = a.node(node);
    return switch (n.tag) {
        .call => for (a.children(node)) |c| {
            if (nested(a, if (a.tag(c) == .setting) a.node(c).rhs else c)) |x| break x;
        } else null,
        .unary, .paren => nested(a, n.lhs),
        .binary => nested(a, n.lhs) orelse nested(a, n.rhs),
        .ternary => nested(a, n.lhs) orelse nested(a, a.extra[n.rhs]) orelse nested(a, a.extra[n.rhs + 1]),
        .number, .word, .string, .list, .tuple, .group, .setting, .instance, .directive, .row => null,
    };
}

/// The measurement function `node` calls. `min` and `max` of two values
/// are the expression functions.
fn measCall(a: *const Ast, node: Index) ?Func {
    if (a.tag(node) != .call) return null;
    const f = std.meta.stringToEnum(Func, a.callee(node)) orelse return null;
    if (f != .min and f != .max) return f;
    const args = a.children(node);
    return if (args.len == 1 or (args.len > 1 and a.tag(args[1]) == .setting)) f else null;
}

/// Whether `e` is `cross(...) - cross(...)`, either side may be `at(x)`.
fn difference(a: *const Ast, e: Index) bool {
    if (a.tag(e) != .binary or a.tokenTag(a.node(e).main) != .minus) return false;
    const x = measCall(a, a.node(e).lhs) orelse return false;
    const y = measCall(a, a.node(e).rhs) orelse return false;
    return (x == .cross or x == .at) and (y == .cross or y == .at) and !(x == .at and y == .at);
}

/// The positional arguments of a call: the parser puts them first.
fn positional(a: *const Ast, node: Index) []const u32 {
    const args = a.children(node);
    for (args, 0..) |c, i| if (a.tag(c) == .setting) return args[0..i];
    return args;
}

/// The value of key `name` of `call`, or null.
fn key(a: *const Ast, node: Index, name: []const u8) ?Index {
    assert(a.tag(node) == .call);
    for (a.children(node)) |c| if (a.tag(c) == .setting and std.mem.eql(u8, a.text(a.node(c).lhs), name)) return a.node(c).rhs;
    return null;
}

fn isWord(a: *const Ast, node: Index, word: []const u8) bool {
    return a.tag(node) == .word and std.mem.eql(u8, a.text(node), word);
}

fn has(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}
