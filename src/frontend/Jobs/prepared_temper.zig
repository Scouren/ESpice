//! The deck's `temper` table (`core.Temper`): which device parameters each
//! card value that reads `temper` sets, and the evaluator the analysis
//! calls at every temperature move, as ngspice re-evaluates such values
//! (inp.c inp_evaluate_temper). In: a netlist whose `temper` slots hold
//! their values at the deck's temperature, and the circuit built from it.
//! Out: the table in the session arena, or a coded refusal. The map comes
//! from one rebuild with every slot moved to a distinct nearby value: a
//! parameter that takes slot k's moved value bit for bit is slot k's, as
//! the variant planner's identity probe reads a live slot
//! (dev/analysis/variants.md).
//! Cites: ngspice inp.c inp_evaluate_temper, cktdojob.c:133, dctrcurv.c:217.
//!
//! Contents:
//! - `pub fn table(lib: *const device.Library, sim: Allocator, scratch: Allocator, nl: *Netlist, nominal: *const device.Circuit, names: core.query.CardNames) !?core.Temper`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const core = @import("core");
const device = @import("device");
const netlist = @import("netlist");
const variant_circuit = @import("variant_circuit.zig");
const variant_params = @import("variant_params.zig");
const expr = netlist.expr;
const temper_slots = netlist.temper_slots;
const Netlist = netlist.Netlist;

/// The expressions `core.Temper.eval` reads: expression `k` is
/// `ops[starts[k]..starts[k + 1]]`, its `.live 0` the temperature, its
/// `.num` operands rows of `consts`.
const Exprs = struct {
    starts: []const u32,
    ops: []const expr.Op,
    consts: []const f64,
};

/// A parameter ordinal and the slot whose value it takes.
const Hit = struct {
    ord: u32,
    slot: u32,

    fn bySlot(_: void, a: Hit, b: Hit) bool {
        return a.slot < b.slot;
    }
};

/// Which slots a probe moves: all, or all but those at zero.
const Moved = enum { all, nonzero };

/// The table for `nl`'s slots over `nominal` (built from `nl` as it
/// stands), null without a slot that reaches a parameter. `names` labels a
/// refusal. Leaves the slots at their values. Fails with `UnsupportedCard`,
/// logged, when a moved value re-wires the circuit, reaches a parameter
/// through a factor the card applies, or is a device value no parameter
/// takes. The table lives in `sim`; the probes' tables in `scratch`.
pub fn table(lib: *const device.Library, sim: Allocator, scratch: Allocator, nl: *Netlist, nominal: *const device.Circuit, names: core.query.CardNames) !?core.Temper {
    const slots = nl.temper;
    const n = slots.count();
    if (n == 0) return null;
    const base = try scratch.alloc(f64, n);
    for (base, 0..) |*b, k| b.* = temper_slots.number(nl, k).*;
    defer for (base, 0..) |b, k| {
        temper_slots.number(nl, k).* = b;
    };
    const at = try variant_params.collect(scratch, nominal);

    // Every slot moved; when that re-wires a device, the zeros stay put
    // (`rs=0` makes no internal node), as ngspice keeps the nodes its setup
    // made: such a parameter stays at zero at every temperature.
    var moved: Moved = .all;
    const hits = try probe(lib, scratch, nl, nominal, at, names, base, moved) orelse blk: {
        moved = .nonzero;
        break :blk try probe(lib, scratch, nl, nominal, at, names, base, moved) orelse {
            if (!@import("builtin").is_test) std.log.err("netlist: a card value that reads temper re-wires the circuit as it moves, which no temperature sweep can rebuild", .{});
            return error.UnsupportedCard;
        };
    };
    std.mem.sort(Hit, hits, {}, Hit.bySlot);

    // A device value that moved and reached no parameter would stay at
    // its nominal; a `.model` card's may belong to a card no device reads.
    var next: usize = 0;
    for (base, slots.model, 0..) |b, model, k| {
        while (next < hits.len and hits[next].slot < k) next += 1;
        const reached = next < hits.len and hits[next].slot == k;
        if (reached or model or !movesIn(b, moved)) continue;
        const slot = slots.slots[k];
        const key = if (slot.table == .kvs) nl.kvs[slot.row].key else "value";
        if (!@import("builtin").is_test) std.log.err("netlist: '{s}': its {s} reads temper but sets no device parameter, so it cannot follow the temperature", .{ cardOf(nl, slot), key });
        return error.UnsupportedCard;
    }
    if (hits.len == 0) return null;
    return try publish(sim, nl, hits);
}

// ---- private ----

/// The parameters slot moves reach, from one rebuild with each slot that
/// `which` moves at a distinct value near its `base`; null when that
/// re-wires the circuit. `at` is `nominal`'s parameters. Leaves the slots
/// moved.
fn probe(lib: *const device.Library, scratch: Allocator, nl: *Netlist, nominal: *const device.Circuit, at: variant_params.Params, names: core.query.CardNames, base: []const f64, which: Moved) !?[]Hit {
    var by_bits: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (base, 0..) |b, k| {
        const x = temper_slots.number(nl, k);
        x.* = b;
        if (!movesIn(b, which)) continue;
        // A distinct nearby value per slot, far from any rounding tie; a
        // zero moves by a small step of its own.
        const step: f64 = @floatFromInt(k + 1);
        var v = if (b == 0) step * 0x1p-40 else b * (1 + step * 0x1p-24);
        for (0..base.len) |_| {
            if (!by_bits.contains(@bitCast(v))) break;
            v = std.math.nextAfter(f64, v, std.math.inf(f64));
        } else unreachable; // base.len values cannot hold base.len + 1 neighbours
        try by_bits.put(scratch, @bitCast(v), @intCast(k));
        x.* = v;
    }
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    defer arena.deinit();
    var c = try variant_circuit.circuitOf(lib, arena.allocator(), arena.allocator(), nl);
    defer c.deinit();
    if (!variant_circuit.sameTopology(nominal, &c)) return null;
    const after = try variant_params.collect(arena.allocator(), &c);
    assert(after.len == at.len);
    var hits: std.ArrayList(Hit) = .empty;
    var it_at = at.iterator();
    var it_after = after.iterator();
    for (0..at.len) |i| {
        const was: u64 = @bitCast(it_at.next().?.*);
        const now: u64 = @bitCast(it_after.next().?.*);
        if (was == now) continue;
        const k = by_bits.get(now) orelse return refuseFactor(at, names, i);
        if (was != @as(u64, @bitCast(base[k]))) return refuseFactor(at, names, i);
        try hits.append(scratch, .{ .ord = @intCast(i), .slot = k });
    }
    return hits.items;
}

/// Whether a probe of kind `which` moves a slot at `b`.
fn movesIn(b: f64, which: Moved) bool {
    return std.math.isFinite(b) and (b != 0 or which == .all);
}

/// Logs parameter `ord`, which moved with a slot but not to its value.
fn refuseFactor(at: variant_params.Params, names: core.query.CardNames, ord: usize) error{UnsupportedCard} {
    const r = at.at(ord);
    if (!@import("builtin").is_test) std.log.err("netlist: '{s}': its {s} follows a value that reads temper through a factor the card applies (m=, scale= or a value computed from it), which a temperature move does not re-evaluate", .{ names.get(r.type, r.index) orelse "?", r.param_name });
    return error.UnsupportedCard;
}

/// The card device slot `slot` belongs to, for a diagnostic. O(devices).
fn cardOf(nl: *const Netlist, slot: netlist.Live.Slot) []const u8 {
    const edges = nl.graph.edges;
    for (edges.items(.name), edges.items(.positional), edges.items(.kv)) |name, positional, kv| {
        const span = if (slot.table == .values) positional else kv;
        if (slot.row >= span.start and slot.row - span.start < span.len) return nl.pool.str(name);
    }
    return "?";
}

/// The table over `hits`, sorted by slot: each slot that reached a
/// parameter becomes an expression, its constants copied into `sim`.
fn publish(sim: Allocator, nl: *const Netlist, hits: []const Hit) !core.Temper {
    const slots = nl.temper;
    var starts: std.ArrayList(u32) = .empty;
    const refs = try sim.alloc(u32, hits.len);
    var ops: std.ArrayList(expr.Op) = .empty;
    var consts: std.ArrayList(f64) = .empty;
    var expr_starts: std.ArrayList(u32) = .empty;
    try expr_starts.append(sim, 0);
    for (hits, 0..) |h, i| {
        refs[i] = h.ord;
        if (i != 0 and hits[i - 1].slot == h.slot) continue;
        assert(i == 0 or hits[i - 1].slot < h.slot);
        try starts.append(sim, @intCast(i));
        for (slots.ops[slots.starts[h.slot]..slots.starts[h.slot + 1]]) |op| {
            var own = op;
            if (op.code == .num) {
                try consts.append(sim, nl.consts[op.a]);
                own.a = @intCast(consts.items.len - 1);
            }
            try ops.append(sim, own);
        }
        try expr_starts.append(sim, @intCast(ops.items.len));
    }
    try starts.append(sim, @intCast(hits.len));
    const e = try sim.create(Exprs);
    e.* = .{ .starts = expr_starts.items, .ops = ops.items, .consts = consts.items };
    const t: core.Temper = .{ .starts = starts.items, .refs = refs, .eval = evalAt, .ctx = e };
    assert(t.count() + 1 == expr_starts.items.len);
    return t;
}

/// `core.Temper.eval` over an `Exprs`.
fn evalAt(ctx: *const anyopaque, k: u32, temp_c: f64) error{OutOfMemory}!f64 {
    const e: *const Exprs = @ptrCast(@alignCast(ctx));
    assert(k + 1 < e.starts.len);
    var buf: [64 * @sizeOf(expr.Val)]u8 align(@alignOf(expr.Val)) = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&buf, core.gpa);
    const gpa = fallback.allocator();
    var stack: std.ArrayList(expr.Val) = .empty;
    defer stack.deinit(gpa);
    return expr.eval(gpa, &stack, e.ops[e.starts[k]..e.starts[k + 1]], e.consts, &.{temp_c}, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => unreachable, // eval fails only with OutOfMemory (expr.zig)
    };
}
