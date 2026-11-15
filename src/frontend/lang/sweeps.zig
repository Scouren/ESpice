//! Rows and lowerings of the sweeps and runs: the `sweep` clause every
//! analysis takes, `.step`, `.data`, `.wcd`, and the `optimize(...)`
//! parameter declaration. In: a bound statement, or a `.param` value. Out:
//! the legacy SWEEP tail, `.step` card, `.data` ... `.enddata` block,
//! `.wcd` card, or `opt(...)` parameter text.
//! Cites: docs/using/language.md "Sweeps and runs"; docs/using/
//! reference.md "Sweeps and statistics"; src/frontend/Netlist/
//! reader_sweeps.zig (`readSweep`: every analysis card takes the tail;
//! `readOptimize`, `readStep`, `readBlock`), reader_directives.zig
//! (`readArgs` expands `list(a b:c)`; `cutFail` wants a quoted FAIL;
//! SIGMA_SCALE only on `.tran`, `.ac` and a `.dc` with a sweep),
//! reader_measures.zig `readWcd`.
//!
//! Contents:
//! - `pub const rows`
//! - `pub fn tail(l: *Lowerer, b: Bound) Allocator.Error!void`
//! - `pub fn optimizeParam(l: *Lowerer, v: Index) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const check = @import("check.zig");
const args = @import("analysis_args.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;
const Index = ast.Index;

/// This area's rows of the directive table.
pub const rows = .{
    .step = Row{ .open = true, .lower = step },
    .data = Row{
        .subjects = &.{ .{ .key = "name", .ty = .reference, .need = .required }, .{ .key = "columns", .ty = .any, .need = .required } },
        .block = true,
        .lower = data,
    },
    .wcd = Row{ .subjects = &.{.{ .key = "spec", .ty = .any, .need = .required }}, .variadic = true, .keys = &wcd_keys, .lower = wcd },
};

const wcd_keys = [_]Slot{
    .{ .key = "maxiter", .ty = .integer },
    .{ .key = "tol", .ty = .real },
    .{ .key = "top", .ty = .integer },
};

const optimize_keys = [_]Slot{
    .{ .key = "lo", .ty = .expr },
    .{ .key = "hi", .ty = .expr },
    .{ .key = "step", .ty = .expr },
    .{ .key = "grid", .ty = .expr },
};

const monte_keys = [_]Slot{
    .{ .key = "first", .ty = .integer },
    .{ .key = "runs", .ty = .list, .elem = .any },
    .{ .key = "sigma_scale", .ty = .list, .elem = .real },
    .{ .key = "fail", .ty = .expr },
};

const optimize_sweep_keys = [_]Slot{
    .{ .key = "results", .ty = .list, .elem = .reference },
    .{ .key = "model", .ty = .reference },
};

/// A call's positional arguments and its keyed ones by slot.
const Call = struct { pos: []const Index, keys: []Index };

/// Writes the statement's sweep clause as its legacy SWEEP tail, if it
/// has one, and ends the card.
pub fn tail(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.sweep != ast.none) try clause(l, b);
    try l.endCard();
}

/// Writes `optimize(name, init, lo=, hi=, step=, grid=)`, a `.param`
/// value, as `name(init,lo,hi[,step[,grid]])`. A `grid` without `step`
/// writes step 0, which `readOptimize` reads as it reads an absent one
/// (its argument row starts zeroed).
pub fn optimizeParam(l: *Lowerer, v: Index) Allocator.Error!void {
    const a = l.a;
    const got = try bindCall(l, v, &optimize_keys);
    if (got.pos.len != 2) return l.diags.add(.arity, a.at(v), "optimize(name, init, lo=, hi=)");
    if (a.tag(got.pos[0]) != .word) return l.diags.add(.wrong_kind, a.at(got.pos[0]), a.text(got.pos[0]));
    try check.value(l, .{ .key = "init", .ty = .expr }, got.pos[1]);
    const lo, const hi, const del, const grid = got.keys[0..4].*;
    if (lo == ast.none or hi == ast.none) return l.diags.add(.missing_key, a.at(v), if (lo == ast.none) "lo" else "hi");
    try l.putName(got.pos[0]);
    try l.put("(");
    try expr.write(l, got.pos[1], .param);
    for ([_]Index{ lo, hi }) |x| {
        try l.put(",");
        try expr.write(l, x, .param);
    }
    if (del != ast.none or grid != ast.none) {
        try l.put(",");
        if (del == ast.none) try l.put("0") else try expr.write(l, del, .param);
    }
    if (grid != ast.none) {
        try l.put(",");
        try expr.write(l, grid, .param);
    }
    try l.put(")");
}

// ---- private ----

/// Binds the arguments of call `node` to `slots`, checking each keyed
/// value; an unknown or repeated key is a row.
fn bindCall(l: *Lowerer, node: Index, slots: []const Slot) Allocator.Error!Call {
    const a = l.a;
    const keys = try l.arena.alloc(Index, slots.len);
    @memset(keys, ast.none);
    var pos: std.ArrayList(Index) = .empty;
    for (a.children(node)) |arg| {
        if (a.tag(arg) != .setting) {
            try pos.append(l.arena, arg);
            continue;
        }
        const key = a.node(arg).lhs;
        const k = for (slots, 0..) |s, i| {
            if (a.tag(key) == .word and std.mem.eql(u8, s.key, a.text(key))) break i;
        } else {
            try l.diags.add(.unknown_key, a.at(key), a.text(key));
            continue;
        };
        if (keys[k] != ast.none) {
            try l.diags.add(.repeated_key, a.at(key), a.text(key));
            continue;
        }
        keys[k] = a.node(arg).rhs;
        try check.value(l, slots[k], keys[k]);
    }
    return .{ .pos = pos.items, .keys = keys };
}

/// ` sweep data=name`, ` sweep monte=...`, ` sweep optimize=...`, or a
/// target's points.
fn clause(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const s = b.sweep;
    if (a.tag(s) == .setting) return targetSweep(l, a.node(s).lhs, a.node(s).rhs);
    if (a.tag(s) != .call) return l.diags.add(.wrong_kind, a.at(s), a.text(s));
    const Kind = enum { data, monte, optimize };
    const kind = std.meta.stringToEnum(Kind, a.callee(s)) orelse return l.diags.add(.wrong_kind, a.at(s), a.callee(s));
    switch (kind) {
        .data => {
            const got = try bindCall(l, s, &.{});
            if (got.pos.len != 1 or a.tag(got.pos[0]) != .word) return l.diags.add(.arity, a.at(s), "data(name)");
            try l.put(" sweep data=");
            try l.putName(got.pos[0]);
        },
        .monte => try monte(l, b),
        .optimize => {
            const got = try bindCall(l, s, &optimize_sweep_keys);
            if (got.pos.len != 1 or a.tag(got.pos[0]) != .word) return l.diags.add(.arity, a.at(s), "optimize(name, results=, model=)");
            const results, const model = got.keys[0..2].*;
            if (results == ast.none or model == ast.none) return l.diags.add(.missing_key, a.at(s), if (results == ast.none) "results" else "model");
            if (a.tag(results) != .list or a.children(results).len == 0) return l.diags.add(.arity, a.at(results), "results=[m1, ...]");
            try l.put(" sweep optimize=");
            try l.putName(got.pos[0]);
            try l.put(" results=");
            for (a.children(results), 0..) |m, i| {
                if (i > 0) try l.put(",");
                try l.putName(m);
            }
            try l.put(" model=");
            try l.putName(model);
        },
    }
}

/// `monte(n, first=k)`, `monte(runs=[10, (20, 30)])` and `monte(n,
/// sigma_scale=[...], fail=expr)`.
fn monte(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const s = b.sweep;
    const got = try bindCall(l, s, &monte_keys);
    const first, const runs, const scales, const fail = got.keys[0..4].*;
    if (got.pos.len > 1) return l.diags.add(.arity, a.at(got.pos[1]), "an argument too many");
    if (runs != ast.none) {
        if (got.pos.len != 0 or first != ast.none or scales != ast.none or fail != ast.none)
            return l.diags.add(.no_legacy, a.at(s), "runs= with a count, first=, sigma_scale= or fail=");
        if (a.tag(runs) != .list or a.children(runs).len == 0) return l.diags.add(.arity, a.at(runs), "runs=[...]");
        try l.put(" sweep monte=list(");
        for (a.children(runs), 0..) |r, i| {
            if (i > 0) try l.put(" ");
            try trial(l, r);
        }
        return l.put(")");
    }
    if (got.pos.len == 0) return l.diags.add(.arity, a.at(s), "monte(n)");
    try check.value(l, .{ .key = "n", .ty = .integer }, got.pos[0]);
    if ((scales == ast.none) != (fail == ast.none)) return l.diags.add(.missing_key, a.at(s), if (scales == ast.none) "sigma_scale" else "fail");
    if (scales != ast.none) {
        const word = a.text(b.stmt);
        const dc_alone = std.mem.eql(u8, word, ".dc") and b.open.len == 0;
        const kinds = std.StaticStringMap(void).initComptime(.{ .{".tran"}, .{".ac"}, .{".dc"} });
        if (!kinds.has(word) or dc_alone) return l.diags.add(.no_legacy, a.at(scales), "sigma_scale on a card other than .tran, .ac or a .dc with a target");
    }
    try l.put(" sweep monte=");
    try args.bare(l, got.pos[0]);
    if (first != ast.none) {
        try l.put(" firstrun=");
        try args.bare(l, first);
    }
    if (scales == ast.none) return;
    try l.put(" sigma_scale=");
    for (a.children(scales), 0..) |x, i| {
        if (i > 0) try l.put(",");
        try args.bare(l, x);
    }
    try l.put(" fail='");
    try expr.write(l, fail, .param);
    try l.put("'");
}

/// One `runs` element: a trial number, or `(a, b)` as `a:b`. The reader
/// reads them as literal numbers, before any parameter is known.
fn trial(l: *Lowerer, r: Index) Allocator.Error!void {
    const a = l.a;
    const one = [1]Index{r};
    const ends: []const Index = if (a.tag(r) == .tuple) a.children(r) else &one;
    if (ends.len != 1 and ends.len != 2) return l.diags.add(.wrong_kind, a.at(r), a.text(r));
    for (ends, 0..) |e, i| {
        if (a.tag(e) != .number) return l.diags.add(.wrong_kind, a.at(e), a.text(e));
        try check.value(l, .{ .key = "runs", .ty = .integer }, e);
        if (i > 0) try l.put(":");
        try expr.write(l, e, .param);
    }
}

/// `.step x=range` is `.step x <grid>`: `lin(a, b, step=s)` `a b s`,
/// `dec(a, b, n=k)` `dec x a b k` (and `oct`), `[v1, ...]` `list v1 ...`.
/// `readStep` has no lin-by-count grid.
fn step(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.open.len == 0) return l.diags.add(.arity, a.at(b.stmt), ".step target=range");
    if (b.open.len > 1) return l.diags.add(.no_legacy, a.at(b.open[1]), "a second .step target: write one .step per target");
    const target = a.node(b.open[0]).lhs;
    const r = a.node(b.open[0]).rhs;
    if (a.tag(target) != .word and a.tag(target) != .string) return l.diags.add(.wrong_kind, a.at(target), a.text(target));
    try check.value(l, .{ .key = "range", .ty = .range }, r);
    if (a.tag(r) == .list) {
        if (a.children(r).len == 0) return l.diags.add(.arity, a.at(r), "[v1, ...]");
        try l.put(".step");
        try args.name(l, target);
        try l.put(" list");
        for (a.children(r)) |v| try args.num(l, v);
        return l.endCard();
    }
    if (a.tag(r) != .call) return;
    const f = a.callee(r);
    const xs = a.children(r);
    if (xs.len != 3 or a.tag(xs[0]) == .setting or a.tag(xs[1]) == .setting or a.tag(xs[2]) != .setting) return l.diags.add(.arity, a.at(r), f);
    const key = a.text(a.node(xs[2]).lhs);
    const by_step = std.mem.eql(u8, key, "step");
    const lin = std.mem.eql(u8, f, "lin");
    if (by_step != lin) return l.diags.add(if (lin) .no_legacy else .unknown_key, a.at(xs[2]), if (lin) "lin(start, stop, n=): .step steps lin by step=" else key);
    if (!by_step and !std.mem.eql(u8, key, "n")) return l.diags.add(.unknown_key, a.at(xs[2]), key);
    if (!by_step) try check.value(l, .{ .key = "n", .ty = .integer }, a.node(xs[2]).rhs);
    try l.put(".step");
    if (!lin) try l.print(" {s}", .{f});
    try args.name(l, target);
    try args.num(l, xs[0]);
    try args.num(l, xs[1]);
    try args.num(l, a.node(xs[2]).rhs);
    try l.endCard();
}

/// `sweep target=range` is the legacy per-analysis tail ` sweep target
/// start stop step` (`lin` by step), ` sweep target lin|dec|oct n start
/// stop` (by count) or ` sweep target poi N v1 ...` (a list):
/// reader_sweeps.zig `readSweep`, the card run once per point.
fn targetSweep(l: *Lowerer, target: Index, r: Index) Allocator.Error!void {
    const a = l.a;
    if (a.tag(target) != .word and a.tag(target) != .string) return l.diags.add(.wrong_kind, a.at(target), a.text(target));
    try check.value(l, .{ .key = "range", .ty = .range }, r);
    if (a.tag(r) == .list) {
        if (a.children(r).len == 0) return l.diags.add(.arity, a.at(r), "[v1, ...]");
        try l.put(" sweep");
        try args.name(l, target);
        try l.print(" poi {d}", .{a.children(r).len});
        for (a.children(r)) |v| try args.num(l, v);
        return;
    }
    if (a.tag(r) != .call) return;
    const f = a.callee(r);
    const xs = a.children(r);
    if (xs.len != 3 or a.tag(xs[0]) == .setting or a.tag(xs[1]) == .setting or a.tag(xs[2]) != .setting) return l.diags.add(.arity, a.at(r), f);
    const key = a.text(a.node(xs[2]).lhs);
    const by_step = std.mem.eql(u8, key, "step");
    if (!by_step and !std.mem.eql(u8, key, "n")) return l.diags.add(.unknown_key, a.at(xs[2]), key);
    if (by_step and !std.mem.eql(u8, f, "lin")) return l.diags.add(.unknown_key, a.at(xs[2]), key);
    try l.put(" sweep");
    try args.name(l, target);
    if (by_step) {
        try args.num(l, xs[0]);
        try args.num(l, xs[1]);
        return args.num(l, a.node(xs[2]).rhs);
    }
    try check.value(l, .{ .key = "n", .ty = .integer }, a.node(xs[2]).rhs);
    try l.print(" {s}", .{f});
    try args.num(l, a.node(xs[2]).rhs);
    try args.num(l, xs[0]);
    try args.num(l, xs[1]);
}

/// `.data name (p1, p2) { rows }` is `.data name p1 p2`, one line per
/// row, `.enddata`.
fn data(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.subjects.len != 2) return;
    const cols = b.subjects[1];
    const one = [1]Index{if (a.tag(cols) == .paren) a.node(cols).lhs else ast.none};
    const names: []const Index = switch (a.tag(cols)) {
        .paren => &one,
        .tuple => a.children(cols),
        else => return l.diags.add(.wrong_kind, a.at(cols), a.text(cols)),
    };
    if (names.len == 0) return l.diags.add(.arity, a.at(cols), "(p1, ...)");
    try l.put(".data");
    try args.name(l, b.subjects[0]);
    for (names) |n| {
        if (a.tag(n) != .word) try l.diags.add(.wrong_kind, a.at(n), a.text(n));
        try args.name(l, n);
    }
    try l.endCard();
    for (a.span(a.statement(b.stmt).block)) |row| {
        if (a.tag(row) != .row) {
            try l.diags.add(.misplaced, a.at(row), "a statement in a .data block");
            continue;
        }
        const items = a.span(a.statement(row).items);
        if (items.len != names.len) try l.diags.add(.arity, a.at(row), "a row with one value per column");
        for (items, 0..) |v, i| {
            try check.value(l, .{ .key = "value", .ty = .expr }, v);
            if (i > 0) try l.put(" ");
            try args.bare(l, v);
        }
        try l.endCard();
    }
    try l.put(".enddata");
    try l.endCard();
}

/// `.wcd (m1 >= L1) (m2 < L2) maxiter=20` is `.wcd m1 '>=L1' m2 '<L2'
/// maxiter=20`.
fn wcd(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    try l.put(".wcd");
    for (b.subjects) |s| {
        const rel = if (a.tag(s) == .paren) a.node(s).lhs else s;
        const ops = std.StaticStringMap(void).initComptime(.{ .{">="}, .{">"}, .{"<="}, .{"<"} });
        if (a.tag(s) != .paren or a.tag(rel) != .binary or !ops.has(a.tokenText(a.node(rel).main)) or a.tag(a.node(rel).lhs) != .word) {
            try l.diags.add(.wrong_kind, a.at(s), a.text(s));
            continue;
        }
        try args.name(l, a.node(rel).lhs);
        try l.print(" '{s}", .{a.tokenText(a.node(rel).main)});
        try expr.write(l, a.node(rel).rhs, .param);
        try l.put("'");
    }
    try args.pairs(l, &wcd_keys, b.keys);
    try l.endCard();
}
