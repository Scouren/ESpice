//! `bsource` instances of the ESPice language. In: `name (p n) bsource
//! v=expr | i=expr` and its settings. Out: a B card over the expression,
//! or, for the five forms that stand alone as the value (`laplace`,
//! `pole`, `table`, `delay`, `poly`), the E card (`v=`) or G card (`i=`),
//! H or F for a `poly` of currents.
//! Cites: docs/using/language.md "Behavioural sources"; docs/using/
//! reference.md "Controlled sources"; src/frontend/Netlist/
//! reader_behavioural.zig (LAPLACE, POLE and DELAY on E and G only).
//!
//! Contents:
//! - `pub fn lower(l: *Lowerer, b: Bound, row: Row, name: []const u8, nodes: []const Index) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Index = ast.Index;
const Bound = schema.Bound;
const Row = schema.Row;

const Form = enum(u3) { laplace, pole, table, delay, poly };

/// Writes the card for a `bsource` whose ports are `nodes`.
pub fn lower(l: *Lowerer, b: Bound, row: Row, name: []const u8, nodes: []const Index) Allocator.Error!void {
    const a = l.a;
    const v = b.get(row, "v");
    const i = b.get(row, "i");
    if ((v == ast.none) == (i == ast.none)) return l.diags.add(if (v == ast.none) .missing_key else .repeated_key, a.at(b.stmt), "v= or i=");
    const value = if (v != ast.none) v else i;
    const voltage = v != ast.none;
    const form: ?Form = if (a.tag(value) == .call) std.meta.stringToEnum(Form, a.callee(value)) else null;
    if (form == null) {
        try l.putHead('b', name);
        try ports(l, nodes);
        try l.put(if (voltage) " v={" else " i={");
        try expr.write(l, value, .behavioural);
        try l.put("}");
    } else {
        const args = a.children(value);
        const currents = form.? == .poly and args.len > 0 and a.tag(args[0]) == .list and a.children(args[0]).len > 0 and isProbe(a, a.children(args[0])[0], "i");
        const letter: u8 = if (currents) (if (voltage) 'h' else 'f') else (if (voltage) 'e' else 'g');
        try l.putHead(letter, name);
        try ports(l, nodes);
        switch (form.?) {
            .laplace => try laplace(l, value),
            .pole => try pole(l, value),
            .table => try table(l, value),
            .delay => try delay(l, value),
            .poly => try poly(l, value, currents),
        }
    }
    for (b.open) |s| {
        try l.print(" {s}=", .{a.text(a.node(s).lhs)});
        try expr.writeValue(l, a.node(s).rhs, .param);
    }
    try l.endCard();
}

// ---- private ----

fn ports(l: *Lowerer, nodes: []const Index) Allocator.Error!void {
    for (nodes) |n| {
        try l.put(" ");
        try l.putName(n);
    }
}

fn isProbe(a: *const ast.Ast, n: Index, f: []const u8) bool {
    return a.tag(n) == .call and std.mem.eql(u8, a.callee(n), f);
}

/// The arguments of a form call: its positional ones, and its keyed ones
/// by `keys`' order (`ast.none` when absent). Null after a coded row.
fn split(l: *Lowerer, call: Index, comptime n_pos: usize, comptime keys: []const []const u8) Allocator.Error!?struct { [n_pos]Index, [keys.len]Index } {
    const a = l.a;
    var pos: [n_pos]Index = @splat(ast.none);
    var keyed: [keys.len]Index = @splat(ast.none);
    var n: usize = 0;
    for (a.children(call)) |arg| {
        if (a.tag(arg) != .setting) {
            if (n == n_pos) {
                try l.diags.add(.arity, a.at(call), a.callee(call));
                return null;
            }
            pos[n] = arg;
            n += 1;
            continue;
        }
        const key = a.text(a.node(arg).lhs);
        const k = for (keys, 0..) |want, i| {
            if (std.mem.eql(u8, want, key)) break i;
        } else {
            try l.diags.add(.unknown_key, a.at(arg), key);
            return null;
        };
        keyed[k] = a.node(arg).rhs;
    }
    if (n != n_pos) {
        try l.diags.add(.arity, a.at(call), a.callee(call));
        return null;
    }
    return .{ pos, keyed };
}

/// The control of a linear form: `v(a)` is ` a 0`, `v(a,b)` ` a b`.
fn control(l: *Lowerer, n: Index) Allocator.Error!void {
    const a = l.a;
    if (!isProbe(a, n, "v") or a.children(n).len == 0 or a.children(n).len > 2)
        return l.diags.add(.no_legacy, a.at(n), "a control other than v(a) or v(a,b)");
    for (a.children(n)) |c| {
        try l.put(" ");
        try l.putName(c);
    }
    if (a.children(n).len == 1) try l.put(" 0");
}

fn list(l: *Lowerer, n: Index) Allocator.Error!void {
    const a = l.a;
    if (n == ast.none or a.tag(n) != .list) return l.diags.add(.wrong_kind, if (n == ast.none) 0 else a.at(n), "a list");
    for (a.children(n)) |e| {
        try l.put(" ");
        try expr.writeValue(l, e, .param);
    }
}

/// `laplace(v(a,b), num=[...], den=[...])` is `laplace a b num... / den...`.
fn laplace(l: *Lowerer, call: Index) Allocator.Error!void {
    const pos, const keys = try split(l, call, 1, &.{ "num", "den" }) orelse return;
    try l.put(" laplace");
    try control(l, pos[0]);
    try list(l, keys[0]);
    try l.put(" /");
    try list(l, keys[1]);
}

/// `pole(v(a,b), gain, zeros=[(α, f)...], poles=[...])` is `pole a b gain
/// α,f ... / 1 α,f ...`: the legacy denominator's constant is 1.
fn pole(l: *Lowerer, call: Index) Allocator.Error!void {
    const pos, const keys = try split(l, call, 2, &.{ "zeros", "poles" }) orelse return;
    try l.put(" pole");
    try control(l, pos[0]);
    try l.put(" ");
    try expr.writeValue(l, pos[1], .param);
    try roots(l, keys[0]);
    try l.put(" / 1");
    try roots(l, keys[1]);
}

fn roots(l: *Lowerer, n: Index) Allocator.Error!void {
    const a = l.a;
    if (n == ast.none) return;
    if (a.tag(n) != .list) return l.diags.add(.wrong_kind, a.at(n), "a list of (alpha, f) pairs");
    for (a.children(n)) |r| {
        if (a.tag(r) != .tuple or a.children(r).len != 2) {
            try l.diags.add(.wrong_kind, a.at(r), "an (alpha, f) pair");
            continue;
        }
        try l.put(" ");
        try expr.writeValue(l, a.children(r)[0], .param);
        try l.put(",");
        try expr.writeValue(l, a.children(r)[1], .param);
    }
}

/// `table(e, (x1, y1), ...)` is `table {e} = (x1,y1) ...`.
fn table(l: *Lowerer, call: Index) Allocator.Error!void {
    const a = l.a;
    const args = a.children(call);
    if (args.len < 2 or a.tag(args[0]) == .setting) return l.diags.add(.arity, a.at(call), "table");
    try l.put(" table {");
    try expr.write(l, args[0], .behavioural);
    try l.put("} =");
    for (args[1..]) |p| {
        if (a.tag(p) != .tuple or a.children(p).len != 2) {
            try l.diags.add(.wrong_kind, a.at(p), "an (x, y) pair");
            continue;
        }
        try l.put(" (");
        try expr.writeValue(l, a.children(p)[0], .param);
        try l.put(",");
        try expr.writeValue(l, a.children(p)[1], .param);
        try l.put(")");
    }
}

/// `delay(v(a,b), td=t)` is `delay a b td=t`.
fn delay(l: *Lowerer, call: Index) Allocator.Error!void {
    const pos, const keys = try split(l, call, 1, &.{"td"}) orelse return;
    if (keys[0] == ast.none) return l.diags.add(.missing_key, l.a.at(call), "td");
    try l.put(" delay");
    try control(l, pos[0]);
    try l.put(" td=");
    try expr.writeValue(l, keys[0], .param);
}

/// `poly([v(a), v(c,d)], coeffs=[...])` is `poly(2) a 0 c d p0 ...`, and
/// `poly([i(V1)], ...)` is `poly(1) V1 p0 ...`.
fn poly(l: *Lowerer, call: Index, currents: bool) Allocator.Error!void {
    const a = l.a;
    const pos, const keys = try split(l, call, 1, &.{"coeffs"}) orelse return;
    if (a.tag(pos[0]) != .list or a.children(pos[0]).len == 0) return l.diags.add(.wrong_kind, a.at(pos[0]), "a list of controls");
    const controls = a.children(pos[0]);
    try l.print(" poly({d})", .{controls.len});
    for (controls) |c| {
        if (currents) {
            if (!isProbe(a, c, "i") or a.children(c).len != 1) {
                try l.diags.add(.wrong_kind, a.at(c), "controls all i(source) or all v(...)");
                continue;
            }
            try l.put(" ");
            try l.putName(a.children(c)[0]);
        } else try control(l, c);
    }
    try list(l, keys[0]);
}
