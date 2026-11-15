//! Rows and lowerings of the checks the reader runs as measurements:
//! `.check`, `.dout`, `.biaschk` and `.stim`. In: a bound statement. Out:
//! its legacy card, each check's keyed limits as the card's `( ... )`
//! group in the reader's order.
//! Cites: docs/using/language.md "Checks"; src/frontend/Parse/
//! measure_check.zig (`check`, `digitalOut`, `biasCheck`, `parseLevels`:
//! a threshold ending in `%` is a share of the swing); Netlist/
//! reader_measures.zig `readStim` (literal numbers only; a data table
//! name before the signals; `node1=`, `node2=` after their signal).
//!
//! Contents:
//! - `pub const rows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const check = @import("check.zig");
const number = @import("number.zig");
const meas = @import("meas.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;
const Index = ast.Index;

/// This area's rows of the directive table.
pub const rows = .{
    .check = Row{ .subjects = &.{.{ .key = "kind", .ty = .word, .words = &check_kinds, .need = .required }}, .keys = &check_keys, .lower = checkCard },
    .dout = Row{ .keys = &dout_keys, .lower = dout },
    .biaschk = Row{ .subjects = &.{.{ .key = "expression", .ty = .expr, .need = .required }}, .keys = &bias_keys, .lower = biaschk },
    .stim = Row{
        .subjects = &.{ .{ .key = "form", .ty = .word, .words = &.{ "pwl", "data" }, .need = .required }, .{ .key = "signal", .ty = .any } },
        .variadic = true,
        .keys = &stim_keys,
        .open = true,
        .lower = stim,
    },
};

const edge_words = [_][]const u8{ "rise", "fall" };

const check_kinds = [_][]const u8{ "rise", "fall", "slew", "setup", "hold", "edge", "irdrop", "global_level" };

const check_keys = [_]Slot{
    .{ .key = "min", .ty = .quantity, .q = .time },
    .{ .key = "max", .ty = .quantity, .q = .time },
    .{ .key = "ref", .ty = .any },
    .{ .key = "ref_edge", .ty = .word, .words = &edge_words },
    .{ .key = "limit", .ty = .quantity, .q = .time },
    .{ .key = "edge", .ty = .word, .words = &edge_words },
    .{ .key = "level", .ty = .quantity, .q = .voltage },
    .{ .key = "duration", .ty = .quantity, .q = .time },
    .{ .key = "hi", .ty = .quantity, .q = .voltage },
    .{ .key = "lo", .ty = .quantity, .q = .voltage },
    .{ .key = "hi_th", .ty = .any },
    .{ .key = "lo_th", .ty = .any },
    .{ .key = "nodes", .ty = .list, .elem = .any },
};

/// The thresholds, in the reader's `(hi lo hi_th lo_th)` order.
const levels = [_][]const u8{ "hi", "lo", "hi_th", "lo_th" };

/// One `.check` form: its group's keys in the reader's order, and
/// whether it takes nodes and its own thresholds.
const Form = struct { group: []const []const u8, nodes: bool = true, levels: bool = true };

const forms = std.StaticStringMap(Form).initComptime(.{
    .{ "rise", Form{ .group = &.{ "min", "max" } } },
    .{ "fall", Form{ .group = &.{ "min", "max" } } },
    .{ "slew", Form{ .group = &.{ "min", "max" } } },
    .{ "setup", Form{ .group = &.{ "ref", "ref_edge", "limit", "edge" } } },
    .{ "hold", Form{ .group = &.{ "ref", "ref_edge", "limit", "edge" } } },
    .{ "edge", Form{ .group = &.{ "ref", "ref_edge", "min", "max", "edge" } } },
    .{ "irdrop", Form{ .group = &.{ "level", "duration" }, .levels = false } },
    .{ "global_level", Form{ .group = &levels, .nodes = false, .levels = false } },
});

const dout_keys = [_]Slot{
    .{ .key = "nodes", .ty = .list, .elem = .any, .need = .required },
    .{ .key = "vth", .ty = .quantity, .q = .voltage },
    .{ .key = "vlo", .ty = .quantity, .q = .voltage },
    .{ .key = "vhi", .ty = .quantity, .q = .voltage },
    .{ .key = "states", .ty = .list, .elem = .any, .need = .required },
};

const bias_keys = [_]Slot{
    .{ .key = "max", .ty = .expr },
    .{ .key = "min", .ty = .expr },
    .{ .key = "tstart", .ty = .quantity, .q = .time },
    .{ .key = "tstop", .ty = .quantity, .q = .time },
};

const stim_keys = [_]Slot{
    .{ .key = "table", .ty = .reference },
    .{ .key = "file", .ty = .string },
    .{ .key = "from", .ty = .quantity, .q = .time },
    .{ .key = "to", .ty = .quantity, .q = .time },
    .{ .key = "npoints", .ty = .integer },
    .{ .key = "times", .ty = .list, .elem = .quantity, .q = .time },
    .{ .key = "indepout", .ty = .flag },
};

// ---- private ----

/// `.check rise min= max= nodes=[a, b]` is `.check rise (min max) a b`,
/// and `hi= lo= hi_th= lo_th=` its own `(hi lo hi_th lo_th)` after them.
fn checkCard(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.subjects.len != 1) return;
    const kind = a.text(b.subjects[0]);
    const form = forms.get(kind) orelse return; // bind reported the word
    const row = schema.rows.get(.check);
    var given_levels: usize = 0;
    for (row.keys, b.keys) |s, n| {
        const lv = has(&levels, s.key) and form.levels;
        given_levels += @intFromBool(lv and n != ast.none);
        const need = has(form.group, s.key) or (form.nodes and std.mem.eql(u8, s.key, "nodes"));
        if (n == ast.none and need) try l.diags.add(.missing_key, a.at(b.stmt), s.key);
        if (n != ast.none and !need and !lv) try l.diags.add(.unknown_key, a.at(n), s.key);
    }
    if (given_levels != 0 and given_levels != levels.len) try l.diags.add(.missing_key, a.at(b.stmt), "hi, lo, hi_th and lo_th");
    try l.print(".check {s}", .{kind});
    try groupOf(l, b, form.group);
    const nodes = b.get(row, "nodes");
    if (form.nodes and nodes != ast.none and a.tag(nodes) == .list) for (a.children(nodes)) |n| {
        try l.put(" ");
        try node(l, n);
    };
    if (given_levels == levels.len) try groupOf(l, b, &levels);
    try l.endCard();
}

/// ` (v1 v2 ...)`: the values of `keys`, absent ones skipped (reported).
fn groupOf(l: *Lowerer, b: Bound, keys: []const []const u8) Allocator.Error!void {
    const a = l.a;
    const row = schema.rows.get(.check);
    try l.put(" (");
    for (keys, 0..) |k, i| {
        const v = b.get(row, k);
        if (v == ast.none) continue;
        if (i > 0) try l.put(" ");
        if (std.mem.eql(u8, k, "ref")) {
            try node(l, v);
        } else if (std.mem.eql(u8, k, "ref_edge") or std.mem.eql(u8, k, "edge")) {
            try l.put(a.text(v));
        } else if (std.mem.endsWith(u8, k, "_th")) {
            try threshold(l, v);
        } else try expr.writeValue(l, v, .param);
    }
    try l.put(")");
}

/// A threshold: a ratio literal (`80%`) is the reader's share of the
/// swing, `80%`; anything else a voltage.
fn threshold(l: *Lowerer, v: Index) Allocator.Error!void {
    const a = l.a;
    if (a.tag(v) == .number) if (number.read(a.text(v)).number) |n| if (n.unit == .pct) return l.print("{s}%", .{n.mantissa});
    try check.value(l, .{ .key = "threshold", .ty = .quantity, .q = .voltage }, v);
    try expr.writeValue(l, v, .param);
}

/// A node by name, or a `v(..)`/`i(..)` probe as written.
fn node(l: *Lowerer, n: Index) Allocator.Error!void {
    const a = l.a;
    switch (a.tag(n)) {
        .word, .string, .number => try l.putName(n),
        .call => if (std.mem.eql(u8, a.callee(n), "v") or std.mem.eql(u8, a.callee(n), "i")) try l.putProbe(n) else try l.diags.add(.wrong_kind, a.at(n), a.text(n)),
        else => try l.diags.add(.wrong_kind, a.at(n), a.text(n)),
    }
}

/// `.dout nodes=[a, b] vth=0.9 states=[(1ns, 1, x)]` is `.dout a b 0.9
/// (1n 1 x)`. The reader takes a number after the first node for a
/// threshold, so a later numbered node is written `v(n)`.
/// ponytail: a later node named as a parameter reads as a threshold too.
fn dout(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const nodes, const vth, const vlo, const vhi, const states = b.keys[0..5].*;
    if (nodes == ast.none or states == ast.none or a.tag(nodes) != .list or a.tag(states) != .list) return;
    if (vth != ast.none and (vlo != ast.none or vhi != ast.none)) try l.diags.add(.repeated_key, a.at(vth), "vth with vlo and vhi");
    if ((vlo == ast.none) != (vhi == ast.none)) try l.diags.add(.missing_key, a.at(b.stmt), "vlo and vhi");
    const names = a.children(nodes);
    if (names.len == 0) return l.diags.add(.arity, a.at(nodes), "nodes");
    try l.put(".dout");
    for (names, 0..) |n, i| {
        try l.put(" ");
        if (i > 0 and a.tag(n) == .number) try l.print("v({s})", .{a.text(n)}) else try node(l, n);
    }
    for ([_]Index{ vth, vlo, vhi }) |v| if (v != ast.none) {
        try l.put(" ");
        try expr.writeValue(l, v, .param);
    };
    try l.put(" (");
    for (a.children(states), 0..) |row, r| {
        if (a.tag(row) != .tuple or a.children(row).len != names.len + 1) {
            try l.diags.add(.arity, a.at(row), "a state row is (time, one state per node)");
            continue;
        }
        if (r > 0) try l.put(" ");
        const cells = a.children(row);
        try expr.writeValue(l, cells[0], .param);
        for (cells[1..]) |s| {
            const t = a.text(s);
            const ok = (a.tag(s) == .number and (std.mem.eql(u8, t, "0") or std.mem.eql(u8, t, "1"))) or (a.tag(s) == .word and std.mem.eql(u8, t, "x"));
            if (!ok) try l.diags.add(.unknown_word, a.at(s), t);
            try l.print(" {s}", .{t});
        }
    }
    try l.put(")");
    try l.endCard();
}

/// `.biaschk v(a) - v(b) max=1V` is `.biaschk 'v(a)-v(b)' max=1`.
fn biaschk(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.subjects.len != 1) return;
    try l.put(".biaschk '");
    try meas.writeExpr(l, b.subjects[0], .signal, l.a.at(b.stmt));
    try l.put("'");
    for (bias_keys, b.keys) |s, v| if (v != ast.none) {
        try l.print(" {s}=", .{s.key});
        try expr.writeValue(l, v, .param);
    };
    try l.endCard();
}

/// `.stim pwl vin=v(a) (v(b), b, 0) from=0 to=1ns npoints=11` is `.stim
/// tran pwl vin=v(a) v(b) node1=b node2=0 from=0 to=1n npoints=11`;
/// `.stim data table=t ...` names the table before the signals.
fn stim(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.subjects.len == 0) return;
    const row = schema.rows.get(.stim);
    const table, const file, const from, const to, const npoints, const times, const indepout = b.keys[0..7].*;
    const data = std.mem.eql(u8, a.text(b.subjects[0]), "data");
    if (data and table == ast.none) try l.diags.add(.missing_key, a.at(b.stmt), "table");
    if (!data and table != ast.none) try l.diags.add(.unknown_key, a.at(table), "table");
    if (b.subjects.len + b.open.len < 2) try l.diags.add(.missing_key, a.at(b.stmt), "a signal");
    try l.print(".stim tran {s}", .{a.text(b.subjects[0])});
    if (file != ast.none) try l.print(" filename={s}", .{a.text(file)});
    if (table != ast.none) {
        try l.put(" ");
        try l.putName(table);
    }
    // Signals in the order written: named ones are settings no key names.
    for (a.span(a.statement(b.stmt).items)) |it| {
        if (it == b.subjects[0] or it == indepout) continue;
        if (a.tag(it) != .setting) {
            try l.put(" ");
            try stimSignal(l, it, b.stmt, false);
            continue;
        }
        const k = a.node(it).lhs;
        if (a.tag(k) != .word) {
            try l.diags.add(.wrong_kind, a.at(k), a.text(k));
            continue;
        }
        if (slotNamed(row, a.text(k))) continue;
        // A PWL source's kind is its name's first letter (reader_measures).
        const first = std.ascii.toLower(a.text(k)[0]);
        if (!data and first != 'v' and first != 'i') try l.diags.add(.stim_name, a.at(k), a.text(k));
        try l.put(" ");
        try l.putName(k);
        try l.put("=");
        try stimSignal(l, a.node(it).rhs, b.stmt, true);
    }
    for ([_]Index{ from, to, npoints }, [_][]const u8{ "from", "to", "npoints" }) |v, k| if (v != ast.none) {
        try l.print(" {s}=", .{k});
        try literal(l, v);
    };
    if (times != ast.none and a.tag(times) == .list) {
        try l.put(" indepvar=(");
        for (a.children(times), 0..) |t, i| {
            if (i > 0) try l.put(" ");
            try literal(l, t);
        }
        try l.put(")");
    }
    if (indepout != ast.none) try l.put(" indepout");
    try l.endCard();
}

/// A `.stim` signal: a signal, or `(signal, p[, n])` naming a PWL
/// source's terminals. The reader names an unnamed one after its probe,
/// so an expression must be named.
fn stimSignal(l: *Lowerer, s: Index, stmt: Index, named: bool) Allocator.Error!void {
    const a = l.a;
    const parts: []const Index = if (a.tag(s) == .tuple) a.children(s) else &.{s};
    if (parts.len == 0 or parts.len > 3) return l.diags.add(.arity, a.at(s), "(signal, p, n)");
    const probe = a.tag(parts[0]) == .call and (std.mem.eql(u8, a.callee(parts[0]), "v") or std.mem.eql(u8, a.callee(parts[0]), "i"));
    if (!named and !probe) try l.diags.add(.missing_key, a.at(s), "a name for this signal");
    try meas.signal(l, parts[0], true, a.at(stmt));
    const terminals = [_][]const u8{ " node1=", " node2=" };
    for (parts[1..], terminals[0 .. parts.len - 1]) |t, k| {
        try l.put(k);
        try node(l, t);
    }
}

/// A number the reader takes only as a literal.
fn literal(l: *Lowerer, v: Index) Allocator.Error!void {
    if (!expr.isLiteral(l.a, v)) try l.diags.add(.no_legacy, l.a.at(v), "a computed .stim value");
    try expr.write(l, v, .param);
}

fn slotNamed(row: Row, k: []const u8) bool {
    for (row.keys) |s| if (std.mem.eql(u8, s.key, k)) return true;
    return false;
}

fn has(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}
