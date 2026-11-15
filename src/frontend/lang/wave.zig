//! Source waves of the ESPice language as legacy text. In: a wave call,
//! `pulse(v1, v2, td=, ...)`. Out: the legacy positional form,
//! `PULSE(v1 v2 td ...)`, up to the last argument given; an omitted
//! argument before it is written as the value the legacy reader takes for
//! "omitted" (net_publish.zig `resolvePulseDefaults`, the source models'
//! defaults), and refused where there is none. Each keyed argument is
//! checked against its quantity.
//! Cites: docs/using/language.md "Waveforms"; docs/using/reference.md
//! "Sources"; src/frontend/Circuit/net_waves.zig `fieldPairs` (the
//! position of each argument); models/vsource.va (each field's meaning,
//! unit, default and sentinel); src/frontend/Parse/pattern.zig (PAT).
//!
//! Contents:
//! - `pub fn lower(l: *Lowerer, node: Index) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const expr = @import("expr.zig");
const check = @import("check.zig");
const schema = @import("schema.zig");
const Quantity = @import("number.zig").Quantity;
const Lowerer = @import("lower.zig").Lowerer;
const Index = ast.Index;

const Shape = enum(u3) { pulse, sin, exp, pwl, sffm, am, pat };

/// What the legacy card holds for an omitted argument written before a
/// given one: `zero` where 0 reads as omitted (or 0 is the default),
/// `mdi` SFFM's index default 90, `none` where no value means "omitted"
/// (SFFM's FM is a -1 sentinel; PAT has no defaults).
const Filler = enum(u2) { zero, mdi, none };

/// One keyed argument, in its legacy position: its type (a quantity, a
/// unitless `real`, `expr` for a value whose unit is the source's, or
/// PAT's `string`).
const Key = struct { key: []const u8, ty: schema.Ty = .quantity, q: Quantity = .time, filler: Filler = .zero };
const Spec = struct { legacy: []const u8, keys: []const Key };

const freq: Key = .{ .key = "freq", .q = .frequency };

const specs = std.EnumArray(Shape, Spec).init(.{
    // PULSE(V1 V2 TD TR TF PW PER PHASE): the 8th is `pulse_phase`, degrees into the period.
    .pulse = .{ .legacy = "PULSE", .keys = &.{ .{ .key = "td" }, .{ .key = "tr" }, .{ .key = "tf" }, .{ .key = "pw" }, .{ .key = "per" }, .{ .key = "phase", .q = .angle } } },
    .sin = .{ .legacy = "SIN", .keys = &.{ freq, .{ .key = "td" }, .{ .key = "theta", .ty = .real }, .{ .key = "phase", .q = .angle } } },
    .exp = .{ .legacy = "EXP", .keys = &.{ .{ .key = "td1" }, .{ .key = "tau1" }, .{ .key = "td2" }, .{ .key = "tau2" } } },
    .pwl = .{ .legacy = "PWL", .keys = &.{} },
    .sffm = .{ .legacy = "SFFM", .keys = &.{
        .{ .key = "fm", .q = .frequency, .filler = .none }, .{ .key = "mdi", .ty = .real, .filler = .mdi },
        .{ .key = "fc", .q = .frequency },                  .{ .key = "td" },
        .{ .key = "phasem", .q = .angle },                  .{ .key = "phasec", .q = .angle },
    } },
    // AM(VA VO MF FC TD PHASEC PHASES OFF): `am_mf` modulates, `am_phases`
    // is its phase, `am_off` the output offset.
    .am = .{ .legacy = "AM", .keys = &.{
        .{ .key = "fm", .q = .frequency }, .{ .key = "fc", .q = .frequency }, .{ .key = "td" },
        .{ .key = "phasec", .q = .angle }, .{ .key = "phasem", .q = .angle }, .{ .key = "off", .ty = .expr },
    } },
    .pat = .{ .legacy = "PAT", .keys = &.{
        .{ .key = "td", .filler = .none },      .{ .key = "tr", .filler = .none },                  .{ .key = "tf", .filler = .none },
        .{ .key = "tsample", .filler = .none }, .{ .key = "data", .ty = .string, .filler = .none },
    } },
});

/// Writes the wave call `node` as its legacy group, `PULSE(...)`.
pub fn lower(l: *Lowerer, node: Index) Allocator.Error!void {
    const a = l.a;
    const name = a.callee(node);
    const shape = std.meta.stringToEnum(Shape, name) orelse return l.diags.add(.wrong_kind, a.at(node), name);
    const spec = specs.get(shape);
    const args = a.children(node);
    var positional: std.ArrayList(Index) = .empty;
    const given = try l.arena.alloc(Index, spec.keys.len);
    @memset(given, ast.none);
    var r: Index = ast.none;
    var td: Index = ast.none;
    for (args) |arg| {
        if (a.tag(arg) != .setting) {
            try positional.append(l.arena, arg);
            continue;
        }
        const key = a.text(a.node(arg).lhs);
        const v = a.node(arg).rhs;
        const slot: *Index = if (shape == .pwl and std.mem.eql(u8, key, "r")) &r else if (shape == .pwl and std.mem.eql(u8, key, "td")) &td else for (spec.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k.key, key)) break &given[i];
        } else {
            try l.diags.add(.unknown_key, a.at(arg), key);
            continue;
        };
        if (slot.* != ast.none) try l.diags.add(.repeated_key, a.at(arg), key);
        slot.* = v;
    }
    for (spec.keys, given) |k, g| if (g != ast.none) try check.value(l, .{ .key = k.key, .ty = k.ty, .q = k.q }, g);
    for ([_]Index{ r, td }) |g| if (g != ast.none) try check.value(l, .{ .key = "r, td", .ty = .quantity, .q = .time }, g);
    if (shape == .pwl) return pwl(l, node, positional.items, r, td);
    if (positional.items.len != 2) return l.diags.add(.arity, a.at(node), name);
    // Every key of pat is required (language.md, Waveforms).
    var last: usize = if (shape == .pat) given.len else 0;
    for (given, 0..) |g, i| if (g != ast.none) {
        last = @max(last, i + 1);
    };
    try l.print("{s}(", .{spec.legacy});
    try expr.writeValue(l, positional.items[0], .param);
    try l.put(" ");
    try expr.writeValue(l, positional.items[1], .param);
    for (spec.keys[0..last], given[0..last]) |k, g| {
        try l.put(" ");
        if (g != ast.none) {
            if (k.ty == .string) try l.put(a.name(g)) else try expr.writeValue(l, g, .param);
            continue;
        }
        switch (k.filler) {
            .zero => try l.put("0"),
            .mdi => try l.put("90"),
            .none => {
                try l.diags.add(if (shape == .pat) .missing_key else .no_filler, a.at(node), k.key);
                try l.put("0");
            },
        }
    }
    try l.put(")");
}

// ---- private ----

/// `pwl((t1, v1), ..., r=, td=)` is `PWL(t1 v1 ...) r= td=`.
fn pwl(l: *Lowerer, node: Index, points: []const Index, r: Index, td: Index) Allocator.Error!void {
    const a = l.a;
    if (points.len == 0) return l.diags.add(.arity, a.at(node), "pwl");
    try l.put("PWL(");
    for (points, 0..) |p, i| {
        if (a.tag(p) != .tuple or a.children(p).len != 2) {
            try l.diags.add(.wrong_kind, a.at(p), "a (time, value) pair");
            continue;
        }
        if (i > 0) try l.put(" ");
        try expr.writeValue(l, a.children(p)[0], .param);
        try l.put(" ");
        try expr.writeValue(l, a.children(p)[1], .param);
    }
    try l.put(")");
    if (r != ast.none) {
        try l.put(" r=");
        try expr.writeValue(l, r, .param);
    }
    if (td != ast.none) {
        try l.put(" td=");
        try expr.writeValue(l, td, .param);
    }
}
