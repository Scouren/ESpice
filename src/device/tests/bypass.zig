//! Tests for the latency bypass (`batch_bypass.zig`) with the C4 lever off
//! and on, and its census. Oracles, per test: the plain evaluation's
//! linearization at the recording, row by row, over generated operating
//! points and terminal ties (#256); the bypass's own tolerance contract;
//! the plain evaluation after a commit (C4's key); the shipped review rule;
//! and the shipped loop's planes (the census changes no value).
//! Cites docs/perf_research/04-levers-cpu.md (C4) and issues #256, #257.
//!
//! The tied-terminal fix this generator must catch is `src/device/sink.zig`
//! line 71, `while (!written[next.*] or ...)` in `RecordSink.rowOf`: delete
//! `!written[next.*] or ` and the mos1 g=s cases fail the first-order row
//! check (the source row does not move).
//!
//! Contents:
//! - test "bypass oracle (#256): every listed model, every tie, ..."
//! - test "bypass oracle (#256): mos1, tied gate or not, ..."
//! - test "bypass oracle (#256): diode, whose first iterate replays ..."
//! - test "C4 key: a commit that moves only charge-only fields ..."
//! - test "C4 review: a cold window turns a batch off, ..."
//! - test "C4 review: a static solve's evaluations are not counted ..."
//! - test "bypass census: each outcome counted once, ..."
//! - test "bypass census: a replay counts the entries it writes ..."
//! - test "C4 review: each turn-off doubles the backoff, ..."
//! - test "bypass tolerance class: at zero, a 1 nV potential move ..."
//! - test "C4 hold: a window under the rule leaves the batch on, ..."
//! - test "bypass census: evaluations while off count as plain, ..."

const std = @import("std");
const assert = std.debug.assert;
const impl = @import("device_eval");
const contract = @import("contract");
const Batch = impl.Batch;
const DeviceBatch = impl.DeviceBatch;
const Real = impl.test_access.Real;
const deviceVtable = impl.deviceVtable;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const ta = impl.test_access;
const models = @import("models");

// The tolerances the existing replay test uses (tests/eval.zig).
const reltol = 1e-4;
const vntol = 1e-6;
const abstol = 1e-12;
/// Every vtable has this type; mos1's in-test one is already built.
const Vtable = @TypeOf(deviceVtable(models.mos1, "bypass_oracle_test"));

/// How an instance's ports meet: `tie` puts unknown `tie[0]`'s node on
/// `tie[1]`'s; `ground` puts that unknown's node on ground (node 0); `own`
/// gives every unknown its own node whatever `collapse` says, so no two
/// entries share a cell.
const Wiring = struct { tie: ?[2]u8 = null, ground: ?u8 = null, own: bool = false };

/// One generator run of a model: the lever, the Newton iteration, the
/// seed, the cases, and the node voltages' span.
const Run = struct { c4: bool, iteration: u32, seed: u64, cases: u32, span: [2]f64 = .{ -0.3, 0.3 } };

/// Models `traits.bypass_models` lists that the batch does not bypass, by
/// base name, each with why: named markers, not skips. The generator fails
/// on a listed model the batch does not bypass that is missing here, and on
/// a marker whose model the batch now bypasses.
const not_bypassed = std.StaticStringMap([]const u8).initComptime(.{});

// ---- private ----

/// One instance of D on nodes 1..n (node 0 is ground), its pattern dense.
/// Initialized in place: the pattern view points into it.
fn Rig(comptime D: type) type {
    const n = contract.nU(D);
    return struct {
        rows: [m * m]u32,
        columns: [m + 1]u32,
        model: D.Model,
        nodes: [n]u32,
        collapse: [n]?u8,
        b: Batch,

        const R = @This();
        const m = n + 1;
        const Planes = struct {
            g: [m * m + 1]f64 = @splat(0),
            c: [m * m + 1]f64 = @splat(0),
            rhs: [m + 1]f64 = @splat(0),
            q: [m + 1]f64 = @splat(0),
            fn run(self: *Planes, f: anytype, b: Batch, x: []const f64) void {
                self.* = .{};
                f(b.ctx, &.{ .g_vals = &self.g, .c_vals = &self.c, .rhs = &self.rhs, .q_vec = &self.q }, 0, 1, x, 0);
            }
        };

        fn init(rig: *R, gpa: Allocator, vt: Vtable, model: D.Model, wiring: Wiring) !void {
            for (&rig.rows, 0..) |*row, i| row.* = @intCast(i % m);
            for (&rig.columns, 0..) |*column, i| column.* = @intCast(i * m);
            const pattern: impl.test_access.PatternView = .{ .col_ptr = &rig.columns, .row_idx = &rig.rows, .n = m, .trash_slot = m * m };
            rig.model = model;
            D.derive(Real, &rig.model);
            const instance: D.Instance = .{};
            rig.collapse = if (comptime @hasDecl(D, "collapse")) D.collapse(Real, &rig.model, &instance) else @splat(null);
            // Ties and grounds act on collapse roots, so an internal node
            // aliased to a tied port follows it.
            for (&rig.nodes, 0..) |*node, u| {
                const root: u32 = if (wiring.own) @intCast(u) else rootOf(rig.collapse, u);
                node.* = 1 + root;
                if (wiring.tie) |t| if (root == rootOf(rig.collapse, t[0])) {
                    node.* = 1 + rootOf(rig.collapse, t[1]);
                };
                if (wiring.ground) |g| if (root == rootOf(rig.collapse, g)) {
                    node.* = 0;
                };
            }
            const proto = try vt.proto_create(gpa).unwrap();
            defer proto.destroy(proto.ctx, gpa);
            try vt.proto_add(proto.ctx, gpa, @ptrCast(&rig.model), @ptrCast(&instance), &rig.nodes).unwrap();
            rig.b = try proto.finalize(proto.ctx, gpa, pattern).unwrap();
        }

        fn rootOf(collapse: [n]?u8, u: usize) u32 {
            assert(u < n);
            return collapse[u] orelse @intCast(u);
        }

        /// Draws x0 (voltages in `span`, currents within ±1e-6) and x1 - x0
        /// inside each unknown's bypass tolerance times `scale`. Ground
        /// stays 0.
        fn draw(rig: *const R, r: std.Random, span: [2]f64, scale: f64, x0: *[m]f64, x1: *[m]f64) void {
            x0.* = @splat(0);
            x1.* = @splat(0);
            for (rig.nodes, rig.collapse, 0..) |node, alias, u| if (alias == null and node != 0) {
                const voltage = isVoltage(D, u);
                const v = if (voltage) span[0] + r.float(f64) * (span[1] - span[0]) else (r.float(f64) * 2 - 1) * 1e-6;
                const within = reltol * @abs(v) + @as(f64, if (voltage) vntol else abstol);
                x0[node] = v;
                x1[node] = v + (r.float(f64) * 2 - 1) * scale * within;
            };
        }
    };
}

/// Whether unknown `u` of D is a node potential. VerA omits `u_kinds`
/// when every unknown is one (no §5.4.2 flow), as its own
/// `osdi_dyn` tables read it.
fn isVoltage(comptime D: type, u: usize) bool {
    if (comptime !@hasDecl(D, "u_kinds")) return true;
    return D.u_kinds[u] == .voltage;
}

/// The cards of the existing replay test (tests/eval.zig): tied, a
/// depletion load with series resistors, so the source row carries its
/// branch current's entry and follows the unwritten gate row.
fn mos1Card(tied: bool) models.mos1.Model {
    return .{ .vto = if (tied) -0.7 else 0.7, .kp = 110e-6, .gamma = 0.4, .lambda = 0.04, .phi = 0.65, .w = 0.5e-6, .l = 0.18e-6, .cgso = 1e-10, .cgdo = 1e-10, .rd = if (tied) 10 else 0, .rs = if (tied) 10 else 0 };
}

/// The port index of `name` in D, or null.
fn portIndex(comptime D: type, comptime name: []const u8) ?u8 {
    const names = @typeInfo(D.U).@"enum".field_names;
    for (names[0..D.num_ports], 0..) |port, i| {
        if (std.mem.eql(u8, port, name)) return @intCast(i);
    }
    return null;
}

/// #256's wirings of D: a two-terminal model with its ports distinct and
/// the second grounded; otherwise untied, then each of g=s, d=s, d=g, b=s
/// whose two ports D has.
fn wirings(comptime D: type) []const Wiring {
    comptime {
        if (D.num_ports == 2) return &.{.{ .ground = 1 }};
        var out: []const Wiring = &.{.{}};
        for ([_][2][]const u8{ .{ "g", "s" }, .{ "d", "s" }, .{ "d", "g" }, .{ "b", "s" } }) |pair| {
            const a = portIndex(D, pair[0]) orelse continue;
            const c = portIndex(D, pair[1]) orelse continue;
            out = out ++ [_]Wiring{.{ .tie = .{ a, c } }};
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

/// The #256 generator over one model and wiring: `run.cases` operating
/// points x0 and moves x1 - x0 inside the unknowns' bypass tolerance, half
/// at a thousandth of it and half at 0.3. Per case: record at x0, then
/// evaluate at x1 through the bypass. Oracles: the plain evaluation
/// (`Batch.eval`, which never bypasses) at x0 and x1. A recording or a miss
/// is the plain evaluation bit for bit; a hit stamps G0 and C0 bit for bit,
/// the charges at x1 exactly, and per row the residual f0 + G0 (x1 - x0)
/// (first order, which the reverted tied-gate fix breaks on the source
/// row) within reltol of the row plus abstol per unknown of f(x1) (the
/// bypass's contract). Replays happen exactly when the iterate may replay:
/// past the first, or with C4 for a model that does not read the iteration.
/// `linked`: `vt` is the device object's (`arp_device_<name>`), whose batch
/// layout this compilation does not know, so a hit is told by its planes
/// differing from the plain evaluation's; else the batch's hit counter is
/// read. Returns the hits, which a caller requires nonzero when replays may
/// happen: a generator whose cases all miss checks nothing.
fn checkReplays(comptime D: type, vt: Vtable, comptime linked: bool, model: D.Model, wiring: Wiring, run: Run) !usize {
    const R = Rig(D);
    const gpa = std.testing.allocator;
    var rig: R = undefined;
    try rig.init(gpa, vt, model, wiring);
    defer rig.b.hooks.deinit(rig.b.ctx, gpa);
    const b = rig.b;
    // The same instance with every port on its own node: the local rows
    // a tie or a ground sums, for the oracle's rounding scale.
    var twin: R = undefined;
    try twin.init(gpa, vt, model, .{});
    defer twin.b.hooks.deinit(twin.b.ctx, gpa);
    for ([_]Batch{ b, twin.b }) |each| {
        if (each.hooks.clear_limits) |clear| clear(each.ctx);
        each.hooks.set_sim_state(each.ctx, .{ .kind = .tran, .t = 1e-9, .dt = 1e-10, .analog_initial = false, .iteration = run.iteration });
    }
    const set_bypass = b.hooks.set_bypass orelse {
        std.debug.print("bypass oracle: {s} is listed in traits.bypass_models but has no set_bypass\n", .{@typeName(D)});
        return error.NotBypassable;
    };
    var prng = std.Random.DefaultPrng.init(run.seed);
    const r = prng.random();
    var hits: usize = 0;
    for (0..run.cases) |k| {
        // Clears every recording.
        set_bypass(b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = run.c4 });
        const hit = checkCase(R, &rig, &twin, D, linked, r, run, k) catch |err| {
            std.debug.print("bypass oracle: {s} wiring={any} c4={} iteration={d} seed=0x{x} case={d}: {s}\n", .{ ta.baseName(D), wiring, run.c4, run.iteration, run.seed, k, @errorName(err) });
            return err;
        };
        hits += @intFromBool(hit);
    }
    // A C4-only model (`traits.bypass_models_c4`) never arms with the lever
    // off: every case is then the plain evaluation, bit for bit.
    const armed = run.c4 or !c4Only(D);
    const replays = armed and (run.iteration > 1 or (run.c4 and !contract.simReads(D).iteration));
    if (!replays) try expectEqual(@as(usize, 0), hits);
    return hits;
}

/// One case of `checkReplays` on a cleared recording: draw, record at
/// x0, evaluate at x1, check. Whether the bypass replayed.
fn checkCase(comptime R: type, rig: *R, twin: *const R, comptime D: type, comptime linked: bool, r: std.Random, run: Run, k: usize) !bool {
    const m = R.m;
    const b = rig.b;
    var x0: [m]f64 = undefined;
    var x1: [m]f64 = undefined;
    rig.draw(r, run.span, if (k % 2 == 0) @as(f64, 1e-3) else 0.3, &x0, &x1);
    var plain0: R.Planes = .{};
    plain0.run(b.eval, b, &x0);
    // A device that stamps nothing (a latched §9.7.3 fatal zeroes its rows)
    // makes a hit indistinguishable from a miss: the case checks nothing.
    // Read on the untied twin at the same port voltages: a tie can cancel
    // a healthy device's assembled rows to exactly zero (drain on source).
    var t0: [m]f64 = @splat(0);
    for (rig.nodes, twin.nodes) |node, own| t0[own] = x0[node];
    var alone: R.Planes = .{};
    alone.run(twin.b.eval, twin.b, &t0);
    if (std.mem.allEqual(f64, &alone.g, 0) and std.mem.allEqual(f64, &alone.rhs, 0)) return error.StampsNothing;
    var plain1: R.Planes = .{};
    plain1.run(b.eval, b, &x1);
    var got: R.Planes = .{};
    const before = hitCount(D, linked, b);
    got.run(b.eval_newton, b, &x0);
    try expectEqual(before, hitCount(D, linked, b));
    try expectPlanesBits(R.Planes, &plain0, &got);
    got.run(b.eval_newton, b, &x1);
    const hit = if (linked) !planesBitsEqual(R.Planes, &plain1, &got) else hitCount(D, linked, b) != before;
    if (!hit) {
        try expectPlanesBits(R.Planes, &plain1, &got);
        return false;
    }
    const scale = localScale(R, rig, twin, &x0, &x1);
    try expectHit(R, &plain0, &plain0, &plain1, &got, &x0, &x1, &scale);
    return true;
}

/// Per node of `rig`, the sum over the local rows that land on it of
/// |f_r(x0)| + sum_c |J_rc| |x1_c - x0_c|, read off `twin`'s plain
/// evaluation: the same instance with every port on its own node, at the
/// same port voltages. A tie or a ground sums local rows that cancel
/// (a drain and a source carry +I and -I), so the node's own |f0| does not
/// show their size. `twin` may be `rig` itself when nothing is tied.
fn localScale(comptime R: type, rig: *const R, twin: *const R, x0: *const [R.m]f64, x1: *const [R.m]f64) [R.m]f64 {
    const m = R.m;
    var t0: [m]f64 = @splat(0);
    var t1: [m]f64 = @splat(0);
    var into: [m]u32 = @splat(0);
    for (rig.nodes, twin.nodes) |node, own| {
        t0[own] = x0[node];
        t1[own] = x1[node];
        into[own] = node;
    }
    var p: R.Planes = .{};
    p.run(twin.b.eval, twin.b, &t0);
    var scale: [m]f64 = @splat(0);
    for (1..m) |row| {
        var a = @abs(p.rhs[row]);
        for (1..m) |col| a += @abs(p.g[col * m + row]) * @abs(t1[col] - t0[col]);
        scale[into[row]] += a;
    }
    return scale;
}

/// A hit's oracles: G and C bitwise `rec`'s (the recording), charges
/// equal to `at1`'s, and each row's residual f0 + G0 dx to first order
/// against `rec`, within the bypass tolerance of `at1`. `base` holds the
/// residual the recording would give now (a commit may not move it).
fn expectHit(comptime R: type, rec: *const R.Planes, base: *const R.Planes, at1: *const R.Planes, got: *const R.Planes, x0: *const [R.m]f64, x1: *const [R.m]f64, scale: *const [R.m]f64) !void {
    const m = R.m;
    const n_u = R.m - 1;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&rec.g), std.mem.asBytes(&got.g));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&rec.c), std.mem.asBytes(&got.c));
    try std.testing.expectEqualSlices(f64, &at1.q, &got.q);
    // Row r moves by sum_c G0[r][c] (x1[c] - x0[c]); slot c * m + r.
    var moved: [m]f64 = @splat(0);
    // sum_c |G0[r][c] (x1[c] - x0[c])|: the scale of the row's dot product.
    var spread: [m]f64 = @splat(0);
    var largest: f64 = 0;
    var size: f64 = 0;
    for (1..m) |row| {
        for (1..m) |col| {
            const term = rec.g[col * m + row] * (x1[col] - x0[col]);
            moved[row] += term;
            spread[row] += @abs(term);
        }
        largest = @max(largest, @abs(moved[row]));
        size = @max(size, @abs(base.rhs[row]));
    }
    // Rounding of rows that sum several local residuals (a tie cancels them).
    const floor = 64 * std.math.floatEps(f64) * size;
    for (1..m) |row| {
        const round = 16 * std.math.floatEps(f64) * @max(@abs(base.rhs[row]), @abs(got.rhs[row])) + floor;
        const step = got.rhs[row] - base.rhs[row];
        // The oracle's own accuracy. The replay (batch_bypass.zig `replay`)
        // forms each local row as fl(v_r + fl(sum_c J_rc fl(x_c - ref_c)))
        // and the plane adds a node's local rows in order; the plain pass
        // adds the v_r in the same order; here the two are subtracted and
        // G0 dx is formed over n_u columns. A value meets at most
        // k = 2 n_u + 3 roundings (n_u products and sums, the add of v_r,
        // n_u row adds, the subtraction), each relative to a term bounded by
        // `scale` or `spread`, so |error| <= gamma_k (scale + spread).
        const k: f64 = @floatFromInt(2 * n_u + 3);
        const gamma = k * std.math.floatEps(f64) / (1 - k * std.math.floatEps(f64));
        const accuracy = gamma * (scale[row] + spread[row]);
        const first = 1e-6 * largest + round + accuracy;
        const bound = reltol * @max(@abs(base.rhs[row]), @abs(at1.rhs[row])) + @as(f64, @floatFromInt(n_u)) * abstol + round;
        const off = @abs(got.rhs[row] - at1.rhs[row]);
        if (!(@abs(step - moved[row]) <= first) or !(off <= bound)) {
            std.debug.print("  row {d}: G0 dx {e}, replay step {e}, gap {e} (first-order bound {e}); sum|G0 dx| {e}, local scale {e}, |f0| {e}, max|f0| {e}; |f - f(x1)| {e} (bound {e})\n", .{ row, moved[row], step, @abs(step - moved[row]), first, spread[row], scale[row], @abs(base.rhs[row]), size, off, bound });
            return error.FirstOrderRow;
        }
    }
}

/// Whether a move of 1e-9 from x = 0, on every potential or on D's first
/// flow, replays (C4 on, past the first iterate).
fn smallMoveHits(comptime D: type, what: enum { potentials, flow }) !bool {
    const R = Rig(D);
    const m = R.m;
    const gpa = std.testing.allocator;
    var rig: R = undefined;
    const wiring: Wiring = if (D.num_ports == 2) .{ .ground = 1 } else .{};
    try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), card(D), wiring);
    defer rig.b.hooks.deinit(rig.b.ctx, gpa);
    const b = rig.b;
    if (b.hooks.clear_limits) |clear| clear(b.ctx);
    b.hooks.set_sim_state(b.ctx, .{ .kind = .tran, .t = 1e-9, .dt = 1e-10, .analog_initial = false, .iteration = 2 });
    b.hooks.set_bypass.?(b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = true });
    const x0: [m]f64 = @splat(0);
    var x1 = x0;
    var moved: usize = 0;
    for (rig.nodes, rig.collapse, 0..) |node, alias, u| if (alias == null and node != 0) {
        const potential = isVoltage(D, u);
        if (potential == (what == .potentials) and (what == .potentials or moved == 0)) {
            x1[node] = 1e-9;
            moved += 1;
        }
    };
    if (moved == 0) return error.NothingToMove;
    var p: R.Planes = .{};
    p.run(b.eval_newton, b, &x0);
    const before = hitCount(D, false, b);
    p.run(b.eval_newton, b, &x1);
    return hitCount(D, false, b) != before;
}

/// The generator's card for D: the default, except where the default
/// latches a §9.7.3 fatal status on the rig, whose ports are all
/// connected, and the device then stamps nothing (`checkCase`); and a
/// SPICE MOS card gets series resistors, so its source row carries its
/// branch current's entry and follows the unwritten gate row on a g=s tie,
/// the case the tied-terminal fix (sink.zig `rowOf`) exists for. With the
/// default rd = rs = 0 the internal nodes collapse and no tie reaches it.
fn card(comptime D: type) D.Model {
    var model: D.Model = .{};
    const name = comptime ta.baseName(D);
    inline for (.{ "rd", "rs" }) |r| {
        if (comptime @hasField(D.Model, r)) {
            if (comptime @FieldType(D.Model, r) == f64) @field(model, r) = 10;
        }
    }
    // "6 nodes are connected but COSUBNODE = 0" (hisimhv.va:2467).
    if (comptime std.mem.eql(u8, name, "hisimhv_va")) model.COSUBNODE = 1;
    // "6 nodes are connected but COBCNODE = 0" (hisimsoi.va:1607).
    if (comptime std.mem.eql(u8, name, "hisimsoi")) model.COBCNODE = 1;
    return model;
}

/// Whether D bypasses with the C4 lever on only.
fn c4Only(comptime D: type) bool {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk ta.bypass_models_c4.has(ta.baseName(D));
    };
}

/// The in-test batch's hit counter; 0 for a linked one, whose layout this
/// compilation does not know.
fn hitCount(comptime D: type, comptime linked: bool, b: Batch) usize {
    if (linked) return 0;
    const store: *DeviceBatch(D) = @ptrCast(@alignCast(b.ctx));
    const bp = store.bypass orelse return 0;
    return bp.hits.load(.monotonic);
}

fn planesBitsEqual(comptime P: type, want: *const P, got: *const P) bool {
    return std.mem.eql(u8, std.mem.asBytes(want), std.mem.asBytes(got));
}

fn expectPlanesBits(comptime P: type, want: *const P, got: *const P) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(want), std.mem.asBytes(got));
}

/// Whether instances `a` and `b` differ only in `fields`, field by field
/// (padding is not compared), and which of `fields` differ.
fn movedOnly(comptime I: type, comptime fields: []const []const u8, a: *const I, b: *const I, moved: *[fields.len]bool) bool {
    inline for (fields, 0..) |name, k| {
        moved[k] = !std.mem.eql(u8, std.mem.asBytes(&@field(a.*, name)), std.mem.asBytes(&@field(b.*, name)));
    }
    inline for (@typeInfo(I).@"struct".field_names) |name| {
        const listed = comptime for (fields) |f| {
            if (std.mem.eql(u8, f, name)) break true;
        } else false;
        if (!listed and !std.mem.eql(u8, std.mem.asBytes(&@field(a.*, name)), std.mem.asBytes(&@field(b.*, name)))) return false;
    }
    return true;
}

// Oracle: #256, over every model `traits.bypass_models` and
// `bypass_models_c4` list (iterated, so a newly listed model is covered
// with no edit here), from the linked device objects, with the default card
// at small operating points. A C4-only model must replay with the lever on
// and evaluate plainly, bit for bit, with it off (`checkReplays`).
test "bypass oracle (#256): every listed model, every tie, the lever off and on" {
    const listed = comptime ta.bypass_models.keys() ++ ta.bypass_models_c4.keys();
    var found: [listed.len]bool = @splat(false);
    var marked: [not_bypassed.keys().len]bool = @splat(false);
    var failures: usize = 0;
    var seed: u64 = 0x256;
    const gpa = std.testing.allocator;
    inline for (@typeInfo(models).@"struct".decl_names) |name| {
        if (@TypeOf(@field(models, name)) != type) continue;
        const D = @field(models, name);
        if (comptime !@hasDecl(D, "Model") or !@hasDecl(D, "eval")) continue;
        const at: ?usize = comptime blk: {
            @setEvalBranchQuota(100_000); // a string-map probe per model name
            const today = ta.bypass_models.getIndex(ta.baseName(D));
            const c4 = ta.bypass_models_c4.getIndex(ta.baseName(D));
            if (today != null and c4 != null) @compileError(ta.baseName(D) ++ " is in both bypass_models and bypass_models_c4");
            break :blk today orelse if (c4) |k| ta.bypass_models.keys().len + k else null;
        };
        if (at == null) continue;
        found[at.?] = true;
        const get = @extern(*const fn () callconv(.c) Vtable, .{ .name = "arp_device_" ++ name });
        // The batch's own verdict: a hook only when `Bypass(D).bypassable`.
        var probe: Rig(D) = undefined;
        try probe.init(gpa, get(), .{}, .{});
        const bypassed = probe.b.hooks.set_bypass != null;
        probe.b.hooks.deinit(probe.b.ctx, gpa);
        const marker = comptime blk: {
            @setEvalBranchQuota(100_000);
            break :blk not_bypassed.getIndex(ta.baseName(D));
        };
        if (marker) |k| {
            marked[k] = true;
            if (bypassed) {
                std.debug.print("bypass oracle: {s} is bypassed now; delete its not_bypassed marker ({s})\n", .{ name, not_bypassed.values()[k] });
                failures += 1;
            }
        } else if (!bypassed) {
            std.debug.print("bypass oracle: traits.bypass_models lists {s}, which the batch does not bypass, and no not_bypassed marker says why\n", .{name});
            failures += 1;
        } else {
            var hits: usize = 0;
            var failed = false;
            // A failing run prints its own name and the next one goes on,
            // so one run lists every failing model and wiring.
            inline for (comptime wirings(D)) |wiring| for ([_]bool{ false, true }) |c4| for ([_]u32{ 1, 2 }) |iteration| {
                hits += checkReplays(D, get(), true, card(D), wiring, .{ .c4 = c4, .iteration = iteration, .seed = seed, .cases = 8 }) catch blk: {
                    failed = true;
                    break :blk 0;
                };
                seed += 1;
            };
            if (failed) {
                failures += 1;
            } else if (hits == 0) {
                std.debug.print("bypass oracle: {s} never replayed\n", .{name});
                failures += 1;
            }
        }
    }
    for (not_bypassed.keys(), marked) |key, ok| if (!ok) {
        std.debug.print("bypass oracle: not_bypassed marks {s}, which no listed model is\n", .{key});
        failures += 1;
    };
    // Finding 7: a listed name that matches no model is a model that
    // silently never bypasses.
    for (listed, found) |key, ok| if (!ok) {
        std.debug.print("bypass oracle: traits.bypass_models(_c4) lists {s}, which no model in `models` is\n", .{key});
        failures += 1;
    };
    try expectEqual(@as(usize, 0), failures);
}

test "bypass oracle (#256): mos1, tied gate or not, replays against the plain linearization with the lever off and on" {
    const D = models.mos1;
    // mos1 reads the iteration (its Meyer charges): its first iterate never
    // replays, lever on or off.
    comptime assert(contract.simReads(D).iteration);
    var seed: u64 = 0xC4_256;
    for ([_]bool{ false, true }) |c4| for ([_]bool{ false, true }) |tied| for ([_]u32{ 1, 2 }) |iteration| {
        const wiring: Wiring = if (tied) .{ .tie = .{ @backingInt(D.U.g), @backingInt(D.U.s) } } else .{};
        const hits = try checkReplays(D, deviceVtable(D, "bypass_oracle_test"), false, mos1Card(tied), wiring, .{ .c4 = c4, .iteration = iteration, .seed = seed, .cases = 24, .span = .{ -0.5, 2.5 } });
        if (iteration > 1) try expect(hits > 0);
        seed += 1;
    };
}

test "bypass oracle (#256): diode, whose first iterate replays with the lever on only" {
    const D = models.diode;
    // Else this test sees nothing the mos1 one does not.
    comptime assert(!contract.simReads(D).iteration);
    var seed: u64 = 0xD10DE;
    for ([_]bool{ false, true }) |c4| for ([_]u32{ 1, 2 }) |iteration| {
        const hits = try checkReplays(D, deviceVtable(D, "bypass_oracle_test"), false, .{ .rs = 10, .cjo = 1e-12, .tt = 1e-9 }, .{}, .{ .c4 = c4, .iteration = iteration, .seed = seed, .cases = 24, .span = .{ -1, 0.8 } });
        if (iteration > 1 or c4) try expect(hits > 0);
        seed += 1;
    };
}

// Oracle: the plain evaluation after the commit. Per `traits.charge_only`
// entry: a commit between the recording and the replay must move those
// fields and nothing else, leave the plain G, C and residual bit for bit
// (the fields reach no current or derivative), and with C4 a hit must then
// be the recording's G and C with the charges of the plain evaluation after
// the commit. Without C4 every such case misses (the bytes moved).
test "C4 key: a commit that moves only charge-only fields keeps a recording with the lever on" {
    const gpa = std.testing.allocator;
    var checked: usize = 0;
    inline for (@typeInfo(models).@"struct".decl_names) |name| {
        if (@TypeOf(@field(models, name)) != type) continue;
        const D = @field(models, name);
        if (comptime !@hasDecl(D, "Model") or !@hasDecl(D, "Instance")) continue;
        const fields = comptime ta.chargeOnlyFields(D);
        if (fields.len == 0) continue;
        checked += 1;
        const R = Rig(D);
        const m = R.m;
        var moved_ever: [fields.len]bool = @splat(false);
        for ([_]bool{ false, true }) |c4| {
            var rig: R = undefined;
            try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), .{}, .{});
            defer rig.b.hooks.deinit(rig.b.ctx, gpa);
            const b = rig.b;
            if (b.hooks.clear_limits) |clear| clear(b.ctx);
            b.hooks.set_sim_state(b.ctx, .{ .kind = .tran, .t = 1e-9, .dt = 1e-10, .analog_initial = false, .iteration = 2 });
            const store: *DeviceBatch(D) = @ptrCast(@alignCast(b.ctx));
            var prng = std.Random.DefaultPrng.init(0xC4_4E7);
            const r = prng.random();
            var hits: usize = 0;
            for (0..24) |k| {
                b.hooks.set_bypass.?(b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = c4 });
                const bp = store.bypass.?;
                var x0: [m]f64 = undefined;
                var x1: [m]f64 = undefined;
                rig.draw(r, .{ -0.3, 0.3 }, if (k % 2 == 0) @as(f64, 1e-3) else 0.3, &x0, &x1);
                // The commit's point: voltages 20 mV off, so the latches move.
                var xc = x0;
                for (rig.nodes, rig.collapse, 0..) |node, alias, u| if (alias == null and node != 0 and isVoltage(D, u)) {
                    xc[node] = x0[node] + 0.02;
                };
                var plain0: R.Planes = .{};
                plain0.run(b.eval, b, &x0);
                var got: R.Planes = .{};
                got.run(b.eval_newton, b, &x0);
                try expectPlanesBits(R.Planes, &plain0, &got);
                const inst_before = store.instances[0];
                _ = b.hooks.update_state.?(b.ctx, &xc);
                _ = b.hooks.state_ctl.?(b.ctx, .commit);
                var moved: [fields.len]bool = undefined;
                try expect(movedOnly(D.Instance, fields, &inst_before, &store.instances[0], &moved));
                for (&moved_ever, moved) |*e, mv| e.* = e.* or mv;
                const any_moved = std.mem.findScalar(bool, &moved, true) != null;
                var after0: R.Planes = .{};
                after0.run(b.eval, b, &x0);
                try std.testing.expectEqualSlices(u8, std.mem.asBytes(&plain0.g), std.mem.asBytes(&after0.g));
                try std.testing.expectEqualSlices(u8, std.mem.asBytes(&plain0.c), std.mem.asBytes(&after0.c));
                try std.testing.expectEqualSlices(u8, std.mem.asBytes(&plain0.rhs), std.mem.asBytes(&after0.rhs));
                var after1: R.Planes = .{};
                after1.run(b.eval, b, &x1);
                const before = bp.hits.load(.monotonic);
                got.run(b.eval_newton, b, &x1);
                if (bp.hits.load(.monotonic) == before) {
                    try expectPlanesBits(R.Planes, &after1, &got);
                    continue;
                }
                try expect(c4 or !any_moved);
                hits += 1;
                const scale = localScale(R, &rig, &rig, &x0, &x1);
                try expectHit(R, &plain0, &after0, &after1, &got, &x0, &x1, &scale);
            }
            if (c4) try expect(hits > 0);
        }
        // A field the commit never moved was never checked.
        try expect(std.mem.allEqual(bool, &moved_ever, true));
    }
    try expect(checked == ta.charge_only.keys().len);
}

// Oracle: the shipped rule (lever off: off for the rest of the run once a
// review sees hits under one in five) and C4's stated rule (lever on: the
// window that judged is forgotten, the batch probes again after a backoff,
// and a latent window keeps it on).
test "C4 review: a cold window turns a batch off, for good with the lever off and until a backoff with it on" {
    const D = models.mos1;
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |c4| {
        var rig: Rig(D) = undefined;
        try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(false), .{});
        defer rig.b.hooks.deinit(rig.b.ctx, gpa);
        rig.b.hooks.set_bypass.?(rig.b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = c4 });
        const store: *DeviceBatch(D) = @ptrCast(@alignCast(rig.b.ctx));
        const bp = store.bypass.?;
        const count = rig.b.count;
        // A cold start: every evaluation of the first window misses.
        bp.misses.store(4 * @as(usize, count), .monotonic);
        bp.review(count);
        try expect(bp.off);
        // Latent from here on, had the batch kept evaluating.
        var reviews: u32 = 0;
        while (bp.off and reviews < 10_000) : (reviews += 1) {
            bp.hits.store(4 * @as(usize, count), .monotonic);
            bp.misses.store(0, .monotonic);
            bp.review(count);
        }
        try expectEqual(c4, !bp.off);
        if (!c4) continue;
        // A backoff, not an immediate re-arm, and no recording survives it.
        try expect(reviews > 1);
        for (store.bypass.?.meta) |meta| try expectEqual(@as(u16, 0), meta.class);
        // A latent window keeps it on and starts the next window from zero.
        bp.hits.store(4 * @as(usize, count), .monotonic);
        bp.misses.store(0, .monotonic);
        bp.review(count);
        try expect(!bp.off);
        try expectEqual(@as(usize, 0), bp.hits.load(.monotonic));
    }
}

// Oracle: the brief's counting rule. Lever off, every evaluation the bypass
// sees counts; lever on, a static solve's (dt 0, the transient's operating
// point) do not.
test "C4 review: a static solve's evaluations are not counted with the lever on" {
    const D = models.mos1;
    const R = Rig(D);
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |c4| {
        var rig: R = undefined;
        try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(false), .{});
        defer rig.b.hooks.deinit(rig.b.ctx, gpa);
        rig.b.hooks.clear_limits.?(rig.b.ctx);
        rig.b.hooks.set_sim_state(rig.b.ctx, .{ .kind = .tran, .dt = 0, .analog_initial = false, .iteration = 2 });
        rig.b.hooks.set_bypass.?(rig.b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = c4 });
        const store: *DeviceBatch(D) = @ptrCast(@alignCast(rig.b.ctx));
        const bp = store.bypass.?;
        const x: [R.m]f64 = @splat(0);
        var planes: R.Planes = .{};
        planes.run(rig.b.eval_newton, rig.b, &x);
        planes.run(rig.b.eval_newton, rig.b, &x);
        const counted = bp.hits.load(.monotonic) + bp.misses.load(.monotonic);
        try expectEqual(@as(usize, if (c4) 0 else 2), counted);
    }
}

// Oracles: a hand count of a scripted run (a first evaluation, a replay, a
// byte miss, a tolerance miss), and the shipped loop's planes, which the
// census run must equal bit for bit.
test "bypass census: each outcome counted once, and the census changes no value" {
    const D = models.mos1;
    const R = Rig(D);
    const m = R.m;
    const gpa = std.testing.allocator;
    var x0: [m]f64 = @splat(0);
    var x2: [m]f64 = @splat(0);
    for (1..m) |node| {
        x0[node] = 0.2 * @as(f64, @floatFromInt(node));
        x2[node] = x0[node] + 0.1;
    }
    var planes: [2][4]R.Planes = undefined;
    for ([_]bool{ false, true }, 0..) |stats, run| {
        var rig: R = undefined;
        try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(false), .{});
        defer rig.b.hooks.deinit(rig.b.ctx, gpa);
        const b = rig.b;
        b.hooks.clear_limits.?(b.ctx);
        b.hooks.set_sim_state(b.ctx, .{ .kind = .tran, .t = 1e-9, .dt = 1e-10, .analog_initial = false, .iteration = 2 });
        b.hooks.set_bypass.?(b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .stats = stats });
        const store: *DeviceBatch(D) = @ptrCast(@alignCast(b.ctx));
        const bp = store.bypass.?;
        // One Planes for all four: a recording keys on the planes' addresses.
        var p: R.Planes = .{};
        p.run(b.eval_newton, b, &x0); // no recording yet
        planes[run][0] = p;
        p.run(b.eval_newton, b, &x0); // a replay
        planes[run][1] = p;
        store.instances[0].bound_step = 1; // bytes the evaluation never reads
        p.run(b.eval_newton, b, &x0); // a byte miss
        planes[run][2] = p;
        p.run(b.eval_newton, b, &x2); // a tolerance miss
        planes[run][3] = p;
        const Census = @TypeOf(bp.*).Census;
        // `replay_writes` needs an untied card to count by hand (the next
        // test); here only that the replay wrote something.
        const want = [_]?usize{ 4, 1, 1, 1, 0, 0, 0, null, 1, 0, 0, 0, 0 };
        for (std.enums.values(Census), want) |tag, w| {
            const got = bp.census[@backingInt(tag)].load(.monotonic);
            if (w) |n| try expectEqual(if (stats) n else 0, got) else try expectEqual(stats, got > 0);
        }
        try expectEqual(@as(usize, 1), bp.hits.load(.monotonic));
    }
    for (planes[0], planes[1]) |off, on| try expectPlanesBits(R.Planes, &off, &on);
}

// Oracle: the cells a plain evaluation writes, counted on planes filled
// with a signalling NaN: every `+=` into a cell quiets it (x86-64 and
// AArch64 both return the quieted operand), a write of +0.0 or -0.0
// included, and an unwritten cell keeps its bits. Every unknown sits on
// its own node (`own`: mos1's branch flows alias a port even with series
// resistors), so no two writes share a cell and the cells written are the
// entries a replay writes. The charges are re-read once per replay of a
// charge model.
test "bypass census: a replay counts the entries it writes and the charges it re-reads" {
    const D = models.mos1;
    const R = Rig(D);
    const m = R.m;
    const gpa = std.testing.allocator;
    var rig: R = undefined;
    try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(true), .{ .own = true });
    defer rig.b.hooks.deinit(rig.b.ctx, gpa);
    const b = rig.b;
    for (rig.nodes, 0..) |node, u| try expectEqual(@as(u32, @intCast(u + 1)), node);
    b.hooks.clear_limits.?(b.ctx);
    b.hooks.set_sim_state(b.ctx, .{ .kind = .tran, .t = 1e-9, .dt = 1e-10, .analog_initial = false, .iteration = 2 });
    b.hooks.set_bypass.?(b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .stats = true });
    var x0: [m]f64 = @splat(0);
    for (1..m) |node| x0[node] = 0.2 * @as(f64, @floatFromInt(node));
    const snan: u64 = 0x7ff0_0000_0000_0001;
    const unwritten: f64 = @bitCast(snan);
    var marked: R.Planes = .{};
    for ([_][]f64{ &marked.g, &marked.c, &marked.rhs }) |plane| @memset(plane, unwritten);
    b.eval(b.ctx, &.{ .g_vals = &marked.g, .c_vals = &marked.c, .rhs = &marked.rhs, .q_vec = &marked.q }, 0, 1, &x0, 0);
    var written: usize = 0;
    for ([_][]const f64{ &marked.g, &marked.c, &marked.rhs }) |plane| {
        for (plane) |v| written += @intFromBool(@as(u64, @bitCast(v)) != snan);
    }
    try expect(written > 0);
    const store: *DeviceBatch(D) = @ptrCast(@alignCast(b.ctx));
    const bp = store.bypass.?;
    var p: R.Planes = .{};
    p.run(b.eval_newton, b, &x0); // records
    p.run(b.eval_newton, b, &x0); // replays
    try expectEqual(@as(usize, 1), bp.hits.load(.monotonic));
    const Census = @TypeOf(bp.*).Census;
    try expectEqual(written, bp.census[@backingInt(Census.replay_writes)].load(.monotonic));
    try expectEqual(@as(usize, 1), bp.census[@backingInt(Census.charge_reads)].load(.monotonic));
}

// Oracle: C4's stated rule, by hand: the k-th turn-off (from 0) keeps a
// batch off for 64 * 2^k reviews, so a batch whose windows never pay is
// re-armed about log2(reviews / 64) times over a run, not once per 64.
test "C4 review: each turn-off doubles the backoff, so re-arms are bounded" {
    const D = models.mos1;
    const gpa = std.testing.allocator;
    var rig: Rig(D) = undefined;
    try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(false), .{});
    defer rig.b.hooks.deinit(rig.b.ctx, gpa);
    rig.b.hooks.set_bypass.?(rig.b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = true });
    const store: *DeviceBatch(D) = @ptrCast(@alignCast(rig.b.ctx));
    const bp = store.bypass.?;
    const count = rig.b.count;
    for ([_]u32{ 64, 128, 256, 512, 1024 }) |want| {
        // A cold window: every evaluation missed.
        bp.hits.store(0, .monotonic);
        bp.misses.store(4 * @as(usize, count), .monotonic);
        bp.review(count);
        try expect(bp.off);
        var reviews: u32 = 0;
        while (bp.off and reviews < 1 << 20) : (reviews += 1) bp.review(count);
        try expectEqual(want, reviews);
    }
}

// Oracle: the bypass's tolerance contract per unknown kind (SPICE's vntol
// for a node potential, abstol for a branch flow), at x = 0 where the
// reltol term vanishes: a move of 1e-9 lies between abstol (1e-12) and
// vntol (1e-6), so it is inside a potential's tolerance and outside a
// flow's. juncap200 has no `u_kinds` (every unknown a potential); mesa
// declares them, flows included. The potentials all move together, so no
// branch voltage moves and the predicted residual change stays ~0.
test "bypass tolerance class: at zero, a 1 nV potential move replays and a 1 nA flow move misses" {
    try expect(try smallMoveHits(models.juncap200, .potentials));
    try expect(try smallMoveHits(models.mesa, .potentials));
    try expect(!try smallMoveHits(models.mesa, .flow));
}

// Oracle: hand counts of three scripted windows. With `hold` (`c4h`) each
// window is judged, counted and forgotten, and the batch stays on; without
// it (today's `c4`) the first window turns the batch off. Windows (one
// instance, so a window is 4 evaluations): 0 hits of 4 (under 1/5 and
// 1/14), 1 of 10 (under 1/5, not 1/14), 2 of 4 (neither).
test "C4 hold: a window under the rule leaves the batch on, and the window counters see every threshold" {
    const D = models.mos1;
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |hold| {
        var rig: Rig(D) = undefined;
        try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(false), .{});
        defer rig.b.hooks.deinit(rig.b.ctx, gpa);
        rig.b.hooks.set_bypass.?(rig.b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .c4 = true, .hold = hold, .stats = true });
        const store: *DeviceBatch(D) = @ptrCast(@alignCast(rig.b.ctx));
        const bp = store.bypass.?;
        const count = rig.b.count;
        try expectEqual(@as(u32, 1), count);
        const Census = @TypeOf(bp.*).Census;
        const windows = [_][2]usize{ .{ 0, 4 }, .{ 1, 9 }, .{ 2, 2 } };
        for (windows, 0..) |w, k| {
            bp.hits.store(w[0], .monotonic);
            bp.misses.store(w[1], .monotonic);
            bp.review(count);
            if (!hold) {
                // Today's c4: the cold first window turns the batch off.
                try expect(bp.off);
                try expectEqual(@as(usize, 1), bp.census[@backingInt(Census.windows_off)].load(.monotonic));
                break;
            }
            try expect(!bp.off);
            try expectEqual(@as(usize, 0), bp.hits.load(.monotonic));
            try expectEqual(@as(usize, 0), bp.misses.load(.monotonic));
            try expectEqual(k + 1, bp.census[@backingInt(Census.windows)].load(.monotonic));
        }
        if (!hold) continue;
        try expectEqual(@as(usize, 2), bp.census[@backingInt(Census.under_5th)].load(.monotonic));
        try expectEqual(@as(usize, 1), bp.census[@backingInt(Census.under_14th)].load(.monotonic));
        try expectEqual(@as(usize, 0), bp.census[@backingInt(Census.windows_off)].load(.monotonic));
    }
}

// Oracle: a hand count of the passes. Lever off (the shipped review), one
// Newton pass through the bypass, then a cold window turns it off and two
// more passes evaluate plainly: `evals` 1 and `plain` 2 (one instance per
// pass), so `evals + plain` is the three passes made.
test "bypass census: evaluations while off count as plain, so evals + plain is every pass" {
    const D = models.mos1;
    const R = Rig(D);
    const gpa = std.testing.allocator;
    var rig: R = undefined;
    try rig.init(gpa, deviceVtable(D, "bypass_oracle_test"), mos1Card(false), .{});
    defer rig.b.hooks.deinit(rig.b.ctx, gpa);
    const b = rig.b;
    b.hooks.clear_limits.?(b.ctx);
    b.hooks.set_sim_state(b.ctx, .{ .kind = .tran, .t = 1e-9, .dt = 1e-10, .analog_initial = false, .iteration = 2 });
    b.hooks.set_bypass.?(b.ctx, .{ .reltol = reltol, .vntol = vntol, .abstol = abstol, .stats = true });
    const store: *DeviceBatch(D) = @ptrCast(@alignCast(b.ctx));
    const bp = store.bypass.?;
    const x: [R.m]f64 = @splat(0);
    var p: R.Planes = .{};
    p.run(b.eval_newton, b, &x);
    bp.hits.store(0, .monotonic);
    bp.misses.store(4 * @as(usize, b.count), .monotonic);
    bp.review(b.count);
    try expect(bp.off);
    p.run(b.eval_newton, b, &x);
    p.run(b.eval_newton, b, &x);
    const Census = @TypeOf(bp.*).Census;
    try expectEqual(@as(usize, 1), bp.census[@backingInt(Census.evals)].load(.monotonic));
    try expectEqual(@as(usize, 2), bp.census[@backingInt(Census.plain)].load(.monotonic));
}
