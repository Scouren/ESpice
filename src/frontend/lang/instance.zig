//! Instances of the ESPice language. In: `name (ports) master [value]
//! settings`. Out: a primitive as `<letter>@name` and its legacy fields
//! (named ports put in the primitive's order here), and any other master
//! as `?@name (ports) master settings`, which the reader resolves.
//! Cites: docs/using/language.md "Instances", "Primitives", "Sources",
//! "Behavioural sources"; contract item 3; docs/using/reference.md
//! "Elements", "Controlled sources".
//!
//! Contents:
//! - `pub fn lower(l: *Lowerer, s: Index) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const check = @import("check.zig");
const expr = @import("expr.zig");
const wave = @import("wave.zig");
const behavioural = @import("behavioural.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Index = ast.Index;
const Slot = schema.Slot;

const Prim = enum(u4) { resistor, capacitor, inductor, mutual, vsource, isource, vcvs, vccs, cccs, ccvs, bsource, tline, sparam, wline };

/// A primitive: its legacy letter, its ports (null: any number), its
/// principal parameter (as a subject and as the key `principal_key`),
/// its keys, and whether other keys pass to the device.
const Info = struct {
    letter: u8,
    ports: ?[]const []const u8,
    principal: ?Slot = null,
    principal_key: []const u8 = "",
    keys: []const Slot,
    open: bool = false,
};

const two = [_][]const u8{ "p", "n" };
const four = [_][]const u8{ "p", "n", "cp", "cn" };

const prims = std.EnumArray(Prim, Info).init(.{
    .resistor = .{ .letter = 'r', .ports = &two, .principal = q("r", .resistance), .principal_key = "r", .keys = &.{ q("r", .resistance), real("tc1"), real("tc2"), real("m") }, .open = true },
    .capacitor = .{ .letter = 'c', .ports = &two, .principal = q("c", .capacitance), .principal_key = "c", .keys = &.{ q("c", .capacitance), q("ic", .voltage), real("m"), .{ .key = "q", .ty = .expr } }, .open = true },
    .inductor = .{ .letter = 'l', .ports = &two, .principal = q("l", .inductance), .principal_key = "l", .keys = &.{ q("l", .inductance), q("ic", .current), real("m") }, .open = true },
    .mutual = .{ .letter = 'k', .ports = &.{}, .principal = real("k"), .principal_key = "k", .keys = &.{ real("k"), .{ .key = "inductors", .ty = .list, .elem = .reference, .need = .required } } },
    .vsource = .{ .letter = 'v', .ports = &two, .principal = .{ .key = "value", .ty = .any }, .keys = &source_keys(.voltage) },
    .isource = .{ .letter = 'i', .ports = &two, .principal = .{ .key = "value", .ty = .any }, .keys = &source_keys(.current) },
    .vcvs = .{ .letter = 'e', .ports = &four, .principal = real("gain"), .principal_key = "gain", .keys = &.{real("gain")} },
    .vccs = .{ .letter = 'g', .ports = &four, .principal = q("gm", .conductance), .principal_key = "gm", .keys = &.{ q("gm", .conductance), real("m") } },
    .cccs = .{ .letter = 'f', .ports = &two, .principal = real("gain"), .principal_key = "gain", .keys = &.{ real("gain"), .{ .key = "probe", .ty = .reference, .need = .required } } },
    .ccvs = .{ .letter = 'h', .ports = &two, .principal = q("r", .resistance), .principal_key = "r", .keys = &.{ q("r", .resistance), .{ .key = "probe", .ty = .reference, .need = .required } } },
    .bsource = .{ .letter = 'b', .ports = &two, .keys = &.{ .{ .key = "v", .ty = .expr }, .{ .key = "i", .ty = .expr } }, .open = true },
    .tline = .{ .letter = 't', .ports = &.{ "a1", "b1", "a2", "b2" }, .keys = &.{ q("z0", .resistance), q("td", .time), q("f", .frequency), real("nl") } },
    .sparam = .{ .letter = 's', .ports = null, .keys = &.{}, .open = true },
    .wline = .{ .letter = 'w', .ports = null, .keys = &.{}, .open = true },
});

/// Lowers the instance statement `s`.
pub fn lower(l: *Lowerer, s: Index) Allocator.Error!void {
    const a = l.a;
    const st = a.statement(s);
    if (st.sweep != ast.none) return l.diags.add(.unexpected, a.at(st.sweep), "sweep");
    if (st.has_block and st.block.end > st.block.start) return l.diags.add(.misplaced, a.at(s), "statements in an instance's { }");
    const name = a.tokenText(a.node(s).main);
    if (a.tokenTag(a.node(s).main) == .string) try checkQuoted(l, name, a.at(s));
    const master = st.master;
    if (a.tag(master) == .string) try check.quotedName(l, master);
    const prim = if (a.tag(master) == .word) std.meta.stringToEnum(Prim, a.text(master)) else null;
    const p = prim orelse return generic(l, s, st);
    const info = prims.get(p);
    const row: schema.Row = .{ .subjects = if (info.principal) |pr| &.{pr} else &.{}, .keys = info.keys, .open = info.open };
    const b = try check.bind(l, s, row);
    const value = try principal(l, b, info);
    const nodes = try portList(l, st.ports, info.ports) orelse return;
    if (p == .bsource) return behavioural.lower(l, b, row, unquote(name), nodes);
    try l.putHead(info.letter, unquote(name));
    switch (p) {
        .mutual => return mutual(l, b, row, value, nodes),
        .vsource, .isource => {
            try putNodes(l, nodes);
            return source(l, b, row, value, p == .vsource);
        },
        else => {},
    }
    try putNodes(l, nodes);
    if (p == .cccs or p == .ccvs) {
        const probe = b.get(row, "probe");
        if (probe == ast.none) return l.diags.add(.missing_key, a.at(s), "probe");
        try l.put(" ");
        try l.putName(probe);
    }
    const reads = value != ast.none and (p == .resistor or p == .capacitor or p == .inductor) and expr.readsCircuit(a, value);
    if (value != ast.none) {
        try l.put(" ");
        try expr.writeValue(l, value, if (reads) .behavioural else .param);
    }
    for (row.keys, b.keys) |k, n| {
        if (n == ast.none or std.mem.eql(u8, k.key, info.principal_key) or std.mem.eql(u8, k.key, "probe")) continue;
        try l.print(" {s}=", .{k.key});
        try expr.writeValue(l, n, if (std.mem.eql(u8, k.key, "q")) .behavioural else .param);
    }
    try openSettings(l, b.open);
    try l.endCard();
}

// ---- private ----

fn q(comptime key: []const u8, comptime quantity: @import("number.zig").Quantity) Slot {
    return .{ .key = key, .ty = .quantity, .q = quantity };
}

fn real(comptime key: []const u8) Slot {
    return .{ .key = key, .ty = .real };
}

fn source_keys(comptime unit: @import("number.zig").Quantity) [7]Slot {
    return .{
        q("dc", unit),                                                                                      q("ac", unit),        q("acphase", .angle),
        .{ .key = if (unit == .voltage) "port" else "m", .ty = if (unit == .voltage) .integer else .real }, q("z0", .resistance), .{ .key = "distof1", .ty = .any },
        .{ .key = "distof2", .ty = .any },
    };
}

/// The principal value, bare or keyed; both is a repeated key.
fn principal(l: *Lowerer, b: schema.Bound, info: Info) Allocator.Error!Index {
    const bare: Index = if (b.subjects.len > 0) b.subjects[0] else ast.none;
    if (info.principal_key.len == 0) return bare;
    const keyed = for (info.keys, b.keys) |k, n| {
        if (std.mem.eql(u8, k.key, info.principal_key)) break n;
    } else ast.none;
    if (bare != ast.none and keyed != ast.none) try l.diags.add(.repeated_key, l.a.at(keyed), info.principal_key);
    return if (bare != ast.none) bare else keyed;
}

/// The port nodes in the master's order: positional as written, or
/// `port=node` put in `names`' order. Null after a coded row.
fn portList(l: *Lowerer, node: Index, names: ?[]const []const u8) Allocator.Error!?[]const Index {
    const a = l.a;
    const items: []const Index = switch (a.tag(node)) {
        // Copied: a slice of a temporary would dangle once returned.
        .paren => try l.arena.dupe(Index, &.{a.node(node).lhs}),
        .group => a.children(node),
        .tuple => if (a.children(node).len == 0) &.{} else {
            try l.diags.add(.wrong_kind, a.at(node), "ports are separated by blanks");
            return null;
        },
        else => unreachable, // the parser reads `(` after an instance name
    };
    var named: usize = 0;
    for (items) |it| named += @intFromBool(a.tag(it) == .setting);
    if (named != 0 and named != items.len) {
        try l.diags.add(.mixed_ports, a.at(node), "(");
        return null;
    }
    if (named == 0) {
        for (items) |it| switch (a.tag(it)) {
            .word, .number => {},
            .string => try check.quotedName(l, it),
            else => try l.diags.add(.wrong_kind, a.at(it), a.text(it)),
        };
        if (names) |n| if (n.len != items.len) {
            try l.diags.add(.arity, a.at(node), "ports");
            return null;
        };
        return items;
    }
    // The reader puts a modelled device's named ports in order.
    const order = names orelse return items;
    const out = try l.arena.alloc(Index, order.len);
    @memset(out, ast.none);
    for (items) |it| {
        const key = a.text(a.node(it).lhs);
        const k = for (order, 0..) |want, i| {
            if (std.mem.eql(u8, want, key)) break i;
        } else {
            try l.diags.add(.unknown_key, a.at(it), key);
            continue;
        };
        if (out[k] != ast.none) try l.diags.add(.repeated_key, a.at(it), key);
        out[k] = a.node(it).rhs;
    }
    for (order, out) |want, slot| if (slot == ast.none) {
        try l.diags.add(.missing_key, a.at(node), want);
        return null;
    };
    return out;
}

fn putNodes(l: *Lowerer, nodes: []const Index) Allocator.Error!void {
    for (nodes) |n| {
        try l.put(" ");
        try l.putName(n);
    }
}

fn openSettings(l: *Lowerer, items: []const Index) Allocator.Error!void {
    const a = l.a;
    for (items) |s| {
        const key = a.node(s).lhs;
        if (a.tag(key) != .word) try l.diags.add(.wrong_kind, a.at(key), a.text(key));
        try l.print(" {s}=", .{a.text(key)});
        const v = a.node(s).rhs;
        if (a.tag(v) == .string) try l.put(a.text(v)) else try expr.writeValue(l, v, .param);
    }
}

/// `K1 () mutual 0.99 inductors=[L1, L2]` is `k@K1 L1 L2 0.99`.
fn mutual(l: *Lowerer, b: schema.Bound, row: schema.Row, value: Index, nodes: []const Index) Allocator.Error!void {
    const a = l.a;
    assert(nodes.len == 0);
    const list = b.get(row, "inductors");
    if (list == ast.none or a.tag(list) != .list) return;
    if (a.children(list).len != 2) return l.diags.add(.arity, a.at(list), "inductors=[L1, L2]");
    try putNodes(l, a.children(list));
    if (value == ast.none) return l.diags.add(.missing_key, a.at(b.stmt), "k");
    try l.put(" ");
    try expr.writeValue(l, value, .param);
    try l.endCard();
}

/// `vsource [value | wave] dc= ac= acphase= port= z0= distof1= distof2=`
/// is `V p n [DC v] [AC mag [phase]] [WAVE(...)] [portnum n [z0 Z]]
/// [DISTOF1 mag [phase]] [DISTOF2 ...]`; an `isource` takes `m=` for the port keys.
fn source(l: *Lowerer, b: schema.Bound, row: schema.Row, value: Index, voltage: bool) Allocator.Error!void {
    const a = l.a;
    const dc, const ac, const acphase, const port_or_m, const z0, const d1, const d2 = b.keys[0..7].*;
    const is_wave = value != ast.none and a.tag(value) == .call and check.isWave(a.callee(value));
    if (value != ast.none and !is_wave) try check.value(l, row.keys[0], value);
    if (value != ast.none and !is_wave and dc != ast.none) try l.diags.add(.repeated_key, a.at(dc), "dc");
    const dc_value = if (is_wave) dc else if (value != ast.none) value else dc;
    if (dc_value != ast.none) {
        try l.put(" DC ");
        try expr.writeValue(l, dc_value, .param);
    }
    if (acphase != ast.none and ac == ast.none) try l.diags.add(.no_filler, a.at(acphase), "acphase without ac");
    if (ac != ast.none) {
        try l.put(" AC ");
        try expr.writeValue(l, ac, .param);
        if (acphase != ast.none) {
            try l.put(" ");
            try expr.writeValue(l, acphase, .param);
        }
    }
    if (is_wave) {
        try l.put(" ");
        try wave.lower(l, value);
    }
    if (voltage) {
        if (z0 != ast.none and port_or_m == ast.none) try l.diags.add(.missing_key, a.at(z0), "port");
        if (port_or_m != ast.none) {
            try l.put(" portnum ");
            try expr.writeValue(l, port_or_m, .param);
            if (z0 != ast.none) {
                try l.put(" z0 ");
                try expr.writeValue(l, z0, .param);
            }
        }
    } else if (z0 != ast.none) try l.diags.add(.unknown_key, a.at(z0), "z0");
    for ([_]Index{ d1, d2 }, [_][]const u8{ "DISTOF1", "DISTOF2" }) |d, word| if (d != ast.none) {
        try l.print(" {s}", .{word});
        const parts: []const Index = if (a.tag(d) == .tuple and a.children(d).len == 2) a.children(d) else &.{d};
        for (parts) |part| {
            try l.put(" ");
            try expr.writeValue(l, part, .param);
        }
    };
    if (!voltage and port_or_m != ast.none) {
        try l.put(" m=");
        try expr.writeValue(l, port_or_m, .param);
    }
    try l.endCard();
}

/// `?@name (ports) master settings`: the reader resolves `master` and
/// reorders named ports to its declared order.
fn generic(l: *Lowerer, s: Index, st: ast.Statement) Allocator.Error!void {
    const a = l.a;
    const name = a.tokenText(a.node(s).main);
    const nodes = try portList(l, st.ports, null) orelse return;
    try l.print("?@{s} (", .{unquote(name)});
    if (a.tag(st.ports) == .group and a.tag(a.children(st.ports)[0]) == .setting) {
        for (a.children(st.ports), 0..) |p, i| {
            if (i > 0) try l.put(" ");
            try l.print("{s}=", .{a.text(a.node(p).lhs)});
            try l.putName(a.node(p).rhs);
        }
    } else for (nodes, 0..) |n, i| {
        if (i > 0) try l.put(" ");
        try l.putName(n);
    }
    try l.put(") ");
    try l.putName(st.master);
    for (a.span(st.items)) |it| switch (a.tag(it)) {
        .setting => try openSettings(l, &.{it}),
        .word => try l.print(" {s}", .{a.text(it)}),
        else => try l.diags.add(.wrong_kind, a.at(it), "a modelled device takes key=value settings"),
    };
    try l.endCard();
}

fn checkQuoted(l: *Lowerer, text: []const u8, at: u32) Allocator.Error!void {
    const body = unquote(text);
    if (body.len == 0 or std.mem.indexOfAny(u8, body, " \t(),=\"{}'") != null) try l.diags.add(.bad_quoted_name, at, text);
}

fn unquote(text: []const u8) []const u8 {
    return if (text.len >= 2 and text[0] == '"') text[1 .. text.len - 1] else text;
}
