//! Stage 3 of the ESPice language: a statement's items against its
//! table row. In: a statement node and its `Row`. Out: `Bound` (the node
//! of each subject and key) and a coded row for every unknown, missing or
//! repeated key, unknown word, wrong kind and wrong unit. The check is
//! shallow by design: a literal's unit, or a same-file parameter's, is
//! checked; anything computed fits.
//! Cites: docs/using/language.md "Types", "What is checked, and when".
//!
//! Contents:
//! - `pub fn bind(l: *Lowerer, stmt: Index, row: Row) Allocator.Error!Bound`
//! - `pub fn value(l: *Lowerer, slot: Slot, node: Index) Allocator.Error!void`
//! - `pub fn unitOf(l: *const Lowerer, node: Index) ?number.Unit`
//! - `pub fn quotedName(l: *Lowerer, node: Index) Allocator.Error!void`
//! - `pub fn isWave(name: []const u8) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const number = @import("number.zig");
const schema = @import("schema.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Index = ast.Index;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;

const probes = std.StaticStringMap(void).initComptime(.{ .{"v"}, .{"i"}, .{"vdb"}, .{"vm"}, .{"vp"}, .{"vr"}, .{"vi"} });
const ranges = std.StaticStringMap(void).initComptime(.{ .{"lin"}, .{"dec"}, .{"oct"} });
const waves = std.StaticStringMap(void).initComptime(.{ .{"pulse"}, .{"sin"}, .{"exp"}, .{"pwl"}, .{"sffm"}, .{"am"}, .{"pat"} });

/// Matches the items of statement `stmt` to `row`'s subjects and keys and
/// checks each value. Problems are rows in `l.diags`; the result holds
/// what matched. Fails only with `OutOfMemory`.
pub fn bind(l: *Lowerer, stmt: Index, row: Row) Allocator.Error!Bound {
    const a = l.a;
    const keys = try l.arena.alloc(Index, row.keys.len);
    @memset(keys, ast.none);
    var subjects: std.ArrayList(Index) = .empty;
    var open: std.ArrayList(Index) = .empty;
    for (a.span(a.statement(stmt).items)) |it| {
        if (a.tag(it) == .setting) {
            const key = a.node(it).lhs;
            const slot = if (a.tag(key) == .word) slotOf(row, a.text(key)) else null;
            if (slot) |k| {
                if (row.keys[k].ty == .flag) try l.diags.add(.wrong_kind, a.at(key), a.text(key)) else try put(l, keys, k, a.node(it).rhs, key);
            } else if (row.open) {
                try open.append(l.arena, it);
            } else try l.diags.add(.unknown_key, a.at(key), a.text(key));
            continue;
        }
        if (a.tag(it) == .word) if (slotOf(row, a.text(it))) |k| if (row.keys[k].ty == .flag) {
            try put(l, keys, k, it, it);
            continue;
        };
        try subjects.append(l.arena, it);
    }
    var required: usize = 0;
    for (row.subjects) |s| required += @intFromBool(s.need == .required);
    const extra = subjects.items.len > row.subjects.len and !row.variadic;
    if (subjects.items.len < required or extra) {
        const at = if (extra) a.at(subjects.items[row.subjects.len]) else a.at(stmt);
        try l.diags.add(.arity, at, if (extra) "an argument too many" else row.subjects[subjects.items.len].key);
    }
    for (subjects.items, 0..) |n, i| {
        if (row.subjects.len == 0) break;
        try value(l, row.subjects[@min(i, row.subjects.len - 1)], n);
    }
    for (row.keys, keys) |s, n| {
        if (n == ast.none) {
            if (s.need == .required) try l.diags.add(.missing_key, a.at(stmt), s.key);
        } else if (s.ty != .flag) try value(l, s, n);
    }
    return .{ .stmt = stmt, .sweep = a.statement(stmt).sweep, .subjects = subjects.items, .keys = keys, .open = open.items };
}

/// Checks one value against its slot's type.
pub fn value(l: *Lowerer, slot: Slot, node: Index) Allocator.Error!void {
    const a = l.a;
    const tag = a.tag(node);
    const at = a.at(node);
    switch (slot.ty) {
        .expr => if (!isExpression(tag)) try l.diags.add(.wrong_kind, at, a.text(node)),
        .quantity, .real, .integer => {
            if (!isExpression(tag)) return l.diags.add(.wrong_kind, at, a.text(node));
            if (slot.ty == .integer and tag == .number) if (number.read(a.text(node)).number) |n| {
                if (n.value != @trunc(n.value)) try l.diags.add(.fraction, at, a.text(node));
            };
            const unit = unitOf(l, node) orelse return;
            const fits = switch (slot.ty) {
                .quantity => number.quantityOf(unit) == slot.q,
                else => unit == .pct and slot.ty == .real,
            };
            if (!fits) try l.diags.add(.wrong_unit, at, a.text(node));
        },
        .flag => {},
        .word => if (tag != .word) {
            try l.diags.add(.wrong_kind, at, a.text(node));
        } else for (slot.words) |w| {
            if (std.mem.eql(u8, w, a.text(node))) break;
        } else try l.diags.add(.unknown_word, at, a.text(node)),
        .string => if (tag != .string) try l.diags.add(.wrong_kind, at, a.text(node)),
        .node, .reference => switch (tag) {
            .word => {},
            .number => if (slot.ty == .reference) try l.diags.add(.wrong_kind, at, a.text(node)),
            .string => try quotedName(l, node),
            else => try l.diags.add(.wrong_kind, at, a.text(node)),
        },
        .probe => if (tag != .call or !probes.has(a.callee(node))) try l.diags.add(.wrong_kind, at, a.text(node)),
        .range => if (tag != .list and !(tag == .call and ranges.has(a.callee(node)))) try l.diags.add(.wrong_kind, at, a.text(node)),
        .wave => if (tag != .call or !isWave(a.callee(node))) try l.diags.add(.wrong_kind, at, a.text(node)),
        .list => if (tag != .list) {
            try l.diags.add(.wrong_kind, at, a.text(node));
        } else for (a.children(node)) |e| try value(l, .{ .key = slot.key, .ty = slot.elem, .q = slot.q }, e),
        .pair => if (tag != .tuple or a.children(node).len != 2) try l.diags.add(.wrong_kind, at, a.text(node)),
        .ports => if (tag != .group and tag != .paren and tag != .tuple) try l.diags.add(.wrong_kind, at, a.text(node)),
        .any => {},
    }
}

/// The unit a value carries: a literal's, a negated literal's, or the
/// unit of the literal a same-file `.param` gave the name.
pub fn unitOf(l: *const Lowerer, node: Index) ?number.Unit {
    const a = l.a;
    return switch (a.tag(node)) {
        .number => if (number.read(a.text(node)).number) |n| n.unit else null,
        .unary => if (a.tag(a.node(node).lhs) == .number) unitOf(l, a.node(node).lhs) else null,
        .word => l.unitOfParam(a.text(node)),
        else => null,
    };
}

/// Reports a quoted name holding a character names may not hold.
pub fn quotedName(l: *Lowerer, node: Index) Allocator.Error!void {
    assert(l.a.tag(node) == .string);
    const body = l.a.name(node);
    if (body.len == 0 or std.mem.indexOfAny(u8, body, " \t(),=\"{}'") != null) try l.diags.add(.bad_quoted_name, l.a.at(node), l.a.text(node));
}

/// Whether `name` is a wave.
pub fn isWave(name: []const u8) bool {
    return waves.has(name);
}

// ---- private ----

fn slotOf(row: Row, key: []const u8) ?usize {
    for (row.keys, 0..) |s, i| if (std.mem.eql(u8, s.key, key)) return i;
    return null;
}

fn put(l: *Lowerer, keys: []Index, k: usize, n: Index, key: Index) Allocator.Error!void {
    if (keys[k] != ast.none) return l.diags.add(.repeated_key, l.a.at(key), l.a.text(key));
    keys[k] = n;
}

fn isExpression(tag: ast.Tag) bool {
    return switch (tag) {
        .number, .word, .unary, .binary, .ternary, .call, .paren => true,
        .string, .list, .tuple, .group, .setting, .instance, .directive, .row => false,
    };
}
