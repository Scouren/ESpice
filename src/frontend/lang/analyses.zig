//! Rows and lowerings of the analyses `.op .dc .ac .tran`, and of ranges.
//! In: a bound analysis statement. Out: its legacy analysis card, each
//! range as the legacy grid (`start stop step`, `lin|dec|oct k start
//! stop`, `poi N v...`).
//! Cites: docs/using/language.md "Ranges", "Analyses"; docs/using/
//! analyses.md `.op`, `.dc`, `.ac`, `.tran`; src/frontend/Jobs/
//! analysis_time.zig `dcJob` (both `.dc` axes take every grid).
//!
//! Contents:
//! - `pub const rows`
//! - `pub const Grid`
//! - `pub fn range(l: *Lowerer, node: Index, grid: Grid) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const check = @import("check.zig");
const sweeps = @import("sweeps.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Bound = schema.Bound;
const Index = ast.Index;

/// This area's rows of the directive table.
pub const rows = .{
    .op = Row{ .keys = &.{.{ .key = "at", .ty = .list, .elem = .quantity, .q = .time }}, .sweeps = true, .lower = op },
    .dc = Row{ .open = true, .sweeps = true, .lower = dc },
    .ac = Row{ .keys = &.{.{ .key = "freq", .ty = .range, .need = .required }}, .sweeps = true, .lower = ac },
    .tran = Row{ .keys = &tran_keys, .sweeps = true, .lower = tran },
};

/// What a range sweeps: a `.dc` axis takes every form, a frequency grid
/// no `lin` with `step=`.
pub const Grid = enum(u1) { sweep, frequency };

const tran_keys = [_]schema.Slot{
    .{ .key = "stop", .ty = .quantity, .q = .time, .need = .required },
    .{ .key = "step", .ty = .quantity, .q = .time, .need = .required },
    .{ .key = "start", .ty = .quantity, .q = .time },
    .{ .key = "maxstep", .ty = .quantity, .q = .time },
    .{ .key = "uic", .ty = .flag },
};

/// Writes ` <legacy grid>` for the range `node`.
pub fn range(l: *Lowerer, node: Index, grid: Grid) Allocator.Error!void {
    const a = l.a;
    if (a.tag(node) == .list) {
        const items = a.children(node);
        try l.print(" poi {d}", .{items.len});
        for (items) |v| try value(l, v);
        return;
    }
    if (a.tag(node) != .call) return l.diags.add(.wrong_kind, a.at(node), a.text(node));
    const f = a.callee(node);
    const args = a.children(node);
    const kinds = std.StaticStringMap(void).initComptime(.{ .{"lin"}, .{"dec"}, .{"oct"} });
    if (!kinds.has(f)) return l.diags.add(.wrong_kind, a.at(node), f);
    if (args.len != 3 or a.tag(args[0]) == .setting or a.tag(args[1]) == .setting or a.tag(args[2]) != .setting)
        return l.diags.add(.arity, a.at(node), f);
    const key = a.text(a.node(args[2]).lhs);
    const k = a.node(args[2]).rhs;
    const by_step = std.mem.eql(u8, key, "step");
    if (!by_step and !std.mem.eql(u8, key, "n")) return l.diags.add(.unknown_key, a.at(args[2]), key);
    if (by_step and (grid == .frequency or !std.mem.eql(u8, f, "lin"))) return l.diags.add(.unknown_key, a.at(args[2]), key);
    if (!by_step) try check.value(l, .{ .key = "n", .ty = .integer }, k);
    if (by_step) {
        try value(l, args[0]);
        try value(l, args[1]);
        return value(l, k);
    }
    try l.print(" {s}", .{f});
    try value(l, k);
    try value(l, args[0]);
    try value(l, args[1]);
}

// ---- private ----

/// An analysis card reads a bare name as a name, never a parameter's
/// value (reader_directives.zig `readArgs`): `analysis_args.num` quotes it.
fn value(l: *Lowerer, v: Index) Allocator.Error!void {
    try @import("analysis_args.zig").num(l, v);
}

/// `.op` is `.op`; `.op at=[t1, t2]` is `.op t1 t2`.
fn op(l: *Lowerer, b: Bound) Allocator.Error!void {
    try l.put(".op");
    if (b.keys[0] != ast.none and l.a.tag(b.keys[0]) == .list) for (l.a.children(b.keys[0])) |t| try value(l, t);
    try sweeps.tail(l, b);
}

/// `.dc a=range [b=range]` is `.dc a <grid> [b <grid>]`, the first fastest.
fn dc(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    // `.dc sweep data(name)` and `.dc sweep monte(n)` sweep no target.
    const alone = b.sweep != ast.none and a.tag(b.sweep) == .call and !std.mem.eql(u8, a.callee(b.sweep), "optimize");
    if (b.open.len == 0 and !alone) return l.diags.add(.arity, a.at(b.stmt), ".dc target=range");
    if (b.open.len > 2) return l.diags.add(.no_legacy, a.at(b.open[2]), "a third .dc target");
    try l.put(".dc");
    for (b.open) |s| {
        const target = a.node(s).lhs;
        if (a.tag(target) != .word and a.tag(target) != .string) {
            try l.diags.add(.wrong_kind, a.at(target), a.text(target));
            continue;
        }
        try l.put(" ");
        try l.putName(target);
        try check.value(l, .{ .key = "range", .ty = .range }, a.node(s).rhs);
        try range(l, a.node(s).rhs, .sweep);
    }
    try sweeps.tail(l, b);
}

/// `.ac freq=dec(f1, f2, n=k)` is `.ac dec k f1 f2`.
fn ac(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".ac");
    try range(l, b.keys[0], .frequency);
    try sweeps.tail(l, b);
}

/// `.tran stop= step= [start=] [maxstep=] [uic]` is `.tran step stop
/// [start [maxstep]] [uic]`; a `maxstep` without `start` starts at 0,
/// the legacy default.
fn tran(l: *Lowerer, b: Bound) Allocator.Error!void {
    const stop, const step, const start, const maxstep, const uic = b.keys[0..5].*;
    if (stop == ast.none or step == ast.none) return;
    try l.put(".tran");
    try value(l, step);
    try value(l, stop);
    if (start != ast.none) try value(l, start) else if (maxstep != ast.none) try l.put(" 0");
    if (maxstep != ast.none) try value(l, maxstep);
    if (uic != ast.none) try l.put(" uic");
    try sweeps.tail(l, b);
}
