//! Card values that read `temper`, the circuit temperature in °C: a device
//! card's value or a `.model` card's whose postfix reads `temper` and
//! nothing else of the circuit, which ngspice re-evaluates at every
//! temperature (inp.c inp_evaluate_temper). A B source's own fields are no
//! slot: its tape reads the temperature as it runs (models/bsource.va).
//! Nor is a V, I or linear E or G card's: ngspice reads those with
//! numparam, which has no `temper`, and stops (src/tests/temper.zig).
//! In: a parsed netlist's value tables. Out: the slots with their postfix
//! over a temperature operand, their values at any temperature, and those
//! values written into the netlist (`setTemp`), so the builder reads
//! numbers.
//! Cites: ngspice inp.c inp_evaluate_temper, inpcom.c inp_parse_temper.
//!
//! Contents:
//! - `pub const TemperSlots = struct`, `TemperSlots.count(t: TemperSlots) usize`
//! - `pub const default_temp_c: f64`
//! - `pub fn find(arena: Allocator, graph: *const hypergraph.Graph, model_kvs: []const Span, values: []Value, kvs: []Kv, ops: []const expr.Op, consts: []const f64) Error!TemperSlots`
//! - `pub fn value(t: TemperSlots, gpa: Allocator, stack: *std.ArrayList(expr.Val), consts: []const f64, k: usize, temp_c: f64) expr.Error!f64`
//! - `pub fn setTemp(nl: *Netlist, gpa: Allocator, stack: *std.ArrayList(expr.Val), temp_c: f64) expr.Error!void`
//! - `pub fn number(nl: *const Netlist, k: usize) *f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const expr = @import("expr.zig");
const hypergraph = @import("hypergraph.zig");
const card_rows = @import("card_rows.zig");
const Netlist = @import("netlist_view.zig").Netlist;
const Error = card_rows.Error;
const Span = card_rows.Span;
const Value = card_rows.Value;
const Kv = card_rows.Kv;
const Slot = card_rows.Live.Slot;

/// The netlist's values that read `temper`. Slot `k` sits at `slots[k]`
/// (a row of `Netlist.values` or `Netlist.kvs`) and is evaluated from
/// `ops[starts[k]..starts[k + 1]]`, whose one `.live 0` operand is the
/// temperature and whose `.num` operands index `Netlist.consts`. `model[k]`
/// says whether it is a `.model` card's value rather than a device's.
pub const TemperSlots = struct {
    slots: []const Slot = &.{},
    model: []const bool = &.{},
    starts: []const u32 = &.{0},
    ops: []const expr.Op = &.{},

    /// Number of slots.
    pub fn count(t: TemperSlots) usize {
        assert(t.starts.len == t.slots.len + 1);
        return t.slots.len;
    }
};

/// ngspice's circuit temperature without `.temp`: 300.15 K.
pub const default_temp_c: f64 = 27;

/// The slot table as `find` appends to it.
const Builder = struct {
    slots: std.ArrayList(Slot) = .empty,
    model: std.ArrayList(bool) = .empty,
    starts: std.ArrayList(u32) = .empty,
    ops: std.ArrayList(expr.Op) = .empty,

    /// Appends `v`, which sits at `slot`, when it reads `temper` and no
    /// other circuit quantity: a probe, `time`, an undefined name, a model
    /// geometry or a live name keeps the postfix for its own reader.
    fn add(b: *Builder, arena: Allocator, slot: Slot, v: Value, ops: []const expr.Op, model: bool) Error!void {
        const span = switch (v) {
            .expr => |s| s,
            else => return,
        };
        const own = ops[span.start..][0..span.len];
        var reads = false;
        for (own) |op| switch (op.code) {
            .ident => if (op.a == temper_ident) {
                reads = true;
            } else return,
            .vprobe, .iprobe, .live, .ucall => return,
            // A derivative has no value here, and a distribution is the
            // Monte Carlo trial's to draw.
            .call => {
                const f: expr.Fn = @fromBackingInt(@intCast(op.a));
                if (f == .ddt or expr.isDistribution(f)) return;
            },
            else => {}, // else: constants and operators
        };
        if (!reads) return;
        if (b.ops.items.len + own.len > std.math.maxInt(u32)) return error.CircuitTooLarge;
        for (own) |op| try b.ops.append(arena, if (isTemper(op)) .{ .code = .live, .a = 0 } else op);
        try b.slots.append(arena, slot);
        try b.model.append(arena, model);
        try b.starts.append(arena, @intCast(b.ops.items.len));
    }
};

/// `.ident`'s operand for `temper` in final ops (`expr.Code.ident`).
const temper_ident = 3;

/// Collects the slots of a parse's tables and writes each its value at
/// `default_temp_c`, so a reader of the tables sees numbers. `graph`'s
/// edges own `values` and `kvs` rows of their cards, `model_kvs` the `kvs`
/// rows of each `.model` card. `consts` is the constant pool the postfix
/// reads. The tables live in `arena`.
pub fn find(arena: Allocator, graph: *const hypergraph.Graph, model_kvs: []const Span, values: []Value, kvs: []Kv, ops: []const expr.Op, consts: []const f64) Error!TemperSlots {
    const reads = for (ops) |op| {
        if (isTemper(op)) break true;
    } else false;
    if (!reads) return .{};
    // Each row once: subcircuit copies may share their rows.
    var seen_values = try std.DynamicBitSetUnmanaged.initEmpty(arena, values.len);
    var seen_kvs = try std.DynamicBitSetUnmanaged.initEmpty(arena, kvs.len);
    var out: Builder = .{};
    try out.starts.append(arena, 0);
    for (graph.edges.items(.kind), graph.edges.items(.positional), graph.edges.items(.kv)) |kind, positional, kv| {
        // A B card's fields, or a behavioural E/F/G/H's: its tape reads
        // `temper`. A V, I or linear E or G card's never do: ngspice hands
        // their braces to numparam, which has no `temper` (inpcom.c
        // inp_temper_compat skips those lines; ngspice-44.2 stops on `vp p 0
        // {temper}` and `e1 o 0 a 0 {temper}`, "Undefined parameter
        // [temper]"), so the value stays postfix and its binder refuses it.
        // F and H read it: ngspice-44.2 runs `f1 0 o v1 {temper}` at 27.
        if (std.mem.indexOfScalar(u8, "bvieg", kind) != null) continue;
        for (positional.start..positional.start + positional.len) |row| if (!seen_values.isSet(row)) {
            seen_values.set(row);
            try out.add(arena, .{ .table = .values, .row = @intCast(row) }, values[row], ops, false);
        };
        for (kv.start..kv.start + kv.len) |row| if (!seen_kvs.isSet(row)) {
            seen_kvs.set(row);
            try out.add(arena, .{ .table = .kvs, .row = @intCast(row) }, kvs[row].value, ops, false);
        };
    }
    for (model_kvs) |kv| for (kv.start..kv.start + kv.len) |row| if (!seen_kvs.isSet(row)) {
        seen_kvs.set(row);
        try out.add(arena, .{ .table = .kvs, .row = @intCast(row) }, kvs[row].value, ops, true);
    };
    const t: TemperSlots = .{ .slots = out.slots.items, .model = out.model.items, .starts = out.starts.items, .ops = out.ops.items };
    var stack: std.ArrayList(expr.Val) = .empty;
    for (0..t.count()) |k| at(values, kvs, t.slots[k]).* = .{ .num = try value(t, arena, &stack, consts, k, default_temp_c) };
    return t;
}

/// Slot `k`'s value at `temp_c` °C over constant pool `consts`; NaN where
/// it has none (a division by zero). `stack` is scratch grown with `gpa`.
/// Asserts `k < t.count()`.
pub fn value(t: TemperSlots, gpa: Allocator, stack: *std.ArrayList(expr.Val), consts: []const f64, k: usize, temp_c: f64) expr.Error!f64 {
    assert(k < t.count());
    assert(t.starts[k] < t.starts[k + 1]);
    return expr.eval(gpa, stack, t.ops[t.starts[k]..t.starts[k + 1]], consts, &.{temp_c}, null);
}

/// Writes every slot of `nl` its value at `temp_c` °C, over the constant
/// pool as it stands (a variant's pool rows included).
pub fn setTemp(nl: *Netlist, gpa: Allocator, stack: *std.ArrayList(expr.Val), temp_c: f64) expr.Error!void {
    const t = nl.temper;
    for (0..t.count()) |k| number(nl, k).* = try value(t, gpa, stack, nl.consts, k, temp_c);
}

/// Slot `k`'s number in the netlist's tables: a write through it is what
/// the next build reads. Asserts that the slot holds a number.
pub fn number(nl: *const Netlist, k: usize) *f64 {
    const v = at(@constCast(nl.values), @constCast(nl.kvs), nl.temper.slots[k]);
    assert(v.* == .num);
    return &v.num;
}

// ---- private ----

fn isTemper(op: expr.Op) bool {
    return op.code == .ident and op.a == temper_ident;
}

/// The value at `slot` in the parse's tables.
fn at(values: []Value, kvs: []Kv, slot: Slot) *Value {
    return switch (slot.table) {
        .values => &values[slot.row],
        .kvs => &kvs[slot.row].value,
        .groups => unreachable, // `find` records no group argument
    };
}

test "find: a model value and a device value that read temper are slots, a B field and a probe are not" {
    // Postfix rows: [0..3) temper+1000, [3..6) v(1)*temper, [6..9)
    // 2*temper, [9..12) temper*1e-12.
    const ops = [_]expr.Op{
        .{ .code = .ident, .a = 3 },                  .{ .code = .num, .a = 0 },   .{ .code = .add },
        .{ .code = .vprobe, .a = 1, .b = expr.none }, .{ .code = .ident, .a = 3 }, .{ .code = .mul },
        .{ .code = .num, .a = 1 },                    .{ .code = .ident, .a = 3 }, .{ .code = .mul },
        .{ .code = .ident, .a = 3 },                  .{ .code = .num, .a = 2 },   .{ .code = .mul },
    };
    const consts = [_]f64{ 1000, 2, 1e-12 };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Edge 0, a diode: positional row 0 (2*temper), kv row 0 (area,
    // v(1)*temper). Edge 1, a B card: kv row 1 (2*temper). Model kv row 2.
    var values = [_]Value{.{ .expr = .{ .start = 6, .len = 3 } }};
    var kvs = [_]Kv{
        .{ .key = "area", .value = .{ .expr = .{ .start = 3, .len = 3 } } },
        .{ .key = "v", .value = .{ .expr = .{ .start = 6, .len = 3 } } },
        .{ .key = "is", .value = .{ .expr = .{ .start = 9, .len = 3 } } },
        .{ .key = "r", .value = .{ .expr = .{ .start = 0, .len = 3 } } },
    };
    var hb = try hypergraph.Builder.init(arena);
    _ = try hb.addEdge(arena, .{ .kind = 'd', .name = @fromBackingInt(0), .model = 0, .positional = .{ .start = 0, .len = 1 }, .kv = .{ .start = 0, .len = 1 }, .subckt_instance = 0 }, &.{});
    _ = try hb.addEdge(arena, .{ .kind = 'b', .name = @fromBackingInt(0), .model = card_rows.none, .positional = .{}, .kv = .{ .start = 1, .len = 1 }, .subckt_instance = 0 }, &.{});
    const graph = try hb.finish(arena);
    const t = try find(arena, &graph, &.{ .{ .start = 2, .len = 1 }, .{ .start = 3, .len = 1 } }, &values, &kvs, &ops, &consts);
    try std.testing.expectEqual(@as(usize, 3), t.count());
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, t.model);
    // Written at 27 °C; the B field and the probe keep their postfix.
    try std.testing.expectEqual(@as(f64, 54), values[0].num);
    try std.testing.expect(kvs[0].value == .expr and kvs[1].value == .expr);
    try std.testing.expectApproxEqRel(@as(f64, 27e-12), kvs[2].value.num, 1e-15);
    try std.testing.expectEqual(@as(f64, 1027), kvs[3].value.num);
    var stack: std.ArrayList(expr.Val) = .empty;
    try std.testing.expectEqual(@as(f64, 1100), try value(t, arena, &stack, &consts, 2, 100));
}

test "find: a V, I, E or G card's value over temper is no slot, an F or H card's is" {
    // ngspice-44.2: `vp p 0 {temper}`, `ip 0 p {temper}`, `e1 o 0 a 0
    // {temper}` and `g1 0 o a 0 {temper*1m}` stop it ("Undefined parameter
    // [temper]"); `f1 0 o v1 {temper}` and `h1 o 0 v1 {temper}` run at 27.
    // Red before: every card letter but B was a slot, so V read 27.
    const ops = [_]expr.Op{ .{ .code = .ident, .a = 3 }, .{ .code = .num, .a = 0 }, .{ .code = .mul } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const letters = "viegfh";
    var values: [letters.len]Value = @splat(.{ .expr = .{ .start = 0, .len = 3 } });
    var kvs: [0]Kv = .{};
    var hb = try hypergraph.Builder.init(arena);
    for (letters, 0..) |kind, i| _ = try hb.addEdge(arena, .{ .kind = kind, .name = @fromBackingInt(0), .model = card_rows.none, .positional = .{ .start = @intCast(i), .len = 1 }, .kv = .{}, .subckt_instance = 0 }, &.{});
    const graph = try hb.finish(arena);
    const t = try find(arena, &graph, &.{}, &values, &kvs, &ops, &.{1});
    try std.testing.expectEqual(@as(usize, 2), t.count());
    for (values[0..4]) |v| try std.testing.expect(v == .expr);
    for (values[4..]) |v| try std.testing.expectEqual(@as(f64, 27), v.num);
}
