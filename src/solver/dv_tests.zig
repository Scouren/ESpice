//! `.options dv` (`converger.Options.dv`, `clampUpdate`) inside the Newton
//! loop. Oracles: the clamp by hand (a written-out vector); the gate order
//! (a clamped iterate is limited, whatever its score); a junction's root by
//! bisection; and, for the option absent, a run with a bound that never
//! fires, bitwise.
//!
//! The lane kernels' clamp (`kernels/lane.zig` `clampUpdate`) has
//! `converger.newton` at W = 1 as its oracle, lane by lane, bitwise.
//!
//! Contents (test fixtures only): `Junction` (with a `Hook` of the
//! converger's `assemble`, `vals` and `diagAt`), `Toy`, `Trace`

const std = @import("std");
const testing = std.testing;
const converger = @import("converger.zig");
const Workspace = @import("newton_workspace.zig").Workspace;
const Lanes = @import("lane/lanes.zig").Lanes;
const lk = @import("kernels/lane.zig");

/// A limiter-less exponential junction, is (e^(v/vt) - 1), fed from a 5 V
/// source through 1 kOhm: F(v) = (v - vs) / r + is (e^(v/vt) - 1), root
/// near 0.67 V. From v = 0 the first Newton step lands near 5 V, where the
/// junction carries 7e72 A, and every later step falls by about vt: some
/// 175 iterations, past the budget of 100.
const Junction = struct {
    n: u32 = 1,
    nnz: u32 = 1,
    diag_slots: [1]u32 = .{0},
    current_row: []const bool = &.{false},
    rhs: []f64,
    g: [1]f64 = .{1},

    const vs = 5.0;
    const r = 1e3;
    const is = 1e-14;
    const vt = 0.025;

    fn f(v: f64) f64 {
        return (v - vs) / r + is * (@exp(v / vt) - 1);
    }

    /// The root of `f` on [0, vs], by bisection on its sign alone to
    /// adjacent floats; `f` increases in v.
    fn root() f64 {
        var lo: f64 = 0;
        var hi: f64 = vs;
        std.debug.assert(f(lo) < 0 and f(hi) > 0);
        for (0..2100) |_| {
            const mid = lo + (hi - lo) / 2;
            if (mid == lo or mid == hi) break;
            if (f(mid) < 0) lo = mid else hi = mid;
        } else unreachable;
        return lo + (hi - lo) / 2;
    }

    const Hook = struct {
        pub fn assemble(_: @This(), sys: *Junction, x: []const f64, _: f64) void {
            sys.rhs[0] = f(x[0]);
            sys.g[0] = 1.0 / r + is / vt * @exp(x[0] / vt);
        }
        pub fn vals(_: @This(), sys: *Junction) []f64 {
            return &sys.g;
        }
        pub fn diagAt(_: @This(), sys: *Junction, slot: u32) f64 {
            return sys.g[slot];
        }
    };
};

/// The fields `finalizeStep` reads of a system with no hooks: one
/// potential row.
const Toy = struct {
    n: u32 = 1,
    nnz: u32 = 1,
    diag_slots: [1]u32 = .{0},
    current_row: []const bool = &.{false},
};

/// Every x a `Junction` Newton assembled at, in order: its iterates.
const Trace = struct {
    xs: [128]f64 = undefined,
    len: usize = 0,

    fn push(self: *Trace, v: f64) void {
        self.xs[self.len] = v;
        self.len += 1;
    }

    /// `Junction.Hook` that logs each iterate into `trace`.
    const Hook = struct {
        trace: *Trace,
        pub fn assemble(h: @This(), sys: *Junction, x: []const f64, t: f64) void {
            h.trace.push(x[0]);
            Junction.Hook.assemble(.{}, sys, x, t);
        }
        pub fn vals(_: @This(), sys: *Junction) []f64 {
            return Junction.Hook.vals(.{}, sys);
        }
        pub fn diagAt(_: @This(), sys: *Junction, slot: u32) f64 {
            return Junction.Hook.diagAt(.{}, sys, slot);
        }
    };
};

const Outcome = struct { r: converger.Result, x: f64 };

// ---- private ----

/// One `Junction` solve from `v0` with `opts`: the result and the x it
/// leaves.
fn solveJunction(opts: converger.Options, v0: f64) !struct { r: converger.Result, x: f64 } {
    const a = testing.allocator;
    var rhs = [_]f64{0};
    var sys: Junction = .{ .rhs = &rhs };
    var ws = try Workspace.init(a, 1, &.{ 0, 1 }, &.{0}, null, .{}, .{});
    defer ws.deinit(a);
    var x = [_]f64{v0};
    const r = try converger.newton(&sys, &ws, &x, 0, opts, Junction.Hook{});
    return .{ .r = r, .x = x[0] };
}

/// `solveJunction` from `v0`, logging its iterates into `trace`.
fn traceJunction(opts: converger.Options, v0: f64, trace: *Trace) !Outcome {
    const a = testing.allocator;
    var rhs = [_]f64{0};
    var sys: Junction = .{ .rhs = &rhs };
    var ws = try Workspace.init(a, 1, &.{ 0, 1 }, &.{0}, null, .{}, .{});
    defer ws.deinit(a);
    var x = [_]f64{v0};
    const r = try converger.newton(&sys, &ws, &x, 0, opts, Trace.Hook{ .trace = trace });
    return .{ .r = r, .x = x[0] };
}

/// N `Junction` lanes from `v0s` through the lane kernel bodies on the
/// host (`HostP`), lane-major, in `lane_device.zig`'s tick order: assemble,
/// the converger's own 1x1 factor and solve (the bodies' LU is bitwise
/// `LaneLu`'s, `kernels/lane.zig`'s tests), `update` (`clampUpdate` when
/// `clamp`, then `updateNorm`; false is the kernel before `dv`), `gates`
/// (the clamp is bit 0 of the flag word, the limited veto) and `finalize`.
fn laneJunctions(comptime N: usize, comptime clamp: bool, opts: converger.Options, v0s: [N]f64, traces: *[N]Trace) ![N]Outcome {
    const a = testing.allocator;
    const B = lk.Bodies(lk.HostP);
    const kopts: lk.NewtonOpts = .{ .reltol = opts.reltol, .abstol = opts.abstol, .vntol = opts.vntol, .gmin = opts.gmin, .residual_tol = opts.residual_tol, .dv = opts.dv, .max_iter = opts.max_iter };
    var ws = try Workspace.init(a, 1, &.{ 0, 1 }, &.{0}, null, .{}, .{});
    defer ws.deinit(a);
    var x: [N]f64 = v0s;
    var x_old: [N]f64 = undefined;
    var dx: [N]f64 = undefined;
    var rhs: [N]f64 = undefined;
    var g: [N]f64 = undefined;
    var limit: [N]f64 = undefined;
    var diag = [_]u32{0};
    var cur = [_]u8{0};
    var out: [N]Outcome = undefined;
    var active: [N]bool = @splat(true);
    for (0..opts.max_iter) |tick| for (0..N) |l| {
        if (!active[l]) continue;
        const L: u32 = @intCast(l);
        var r1 = [_]f64{0};
        var sys: Junction = .{ .rhs = &r1 };
        traces[l].push(x[l]);
        Junction.Hook.assemble(.{}, &sys, &.{x[l]}, 0);
        rhs[l] = r1[0];
        g[l] = sys.g[0];
        try ws.slv.factor(&sys.g, .{});
        ws.slv.solveNeg(&r1, dx[l..][0..1]);
        if (tick == 0) limit[l] = B.plausibleLimit(1, &x, &rhs, &g, &diag, N, L);
        const clamped = clamp and B.clampUpdate(1, &dx, &cur, kopts.dv, N, L);
        const scaled = B.updateNorm(1, &x, &dx, &x_old, &cur, kopts.reltol, kopts.abstol, kopts.vntol, N, L);
        var ok = !clamped and tick != 0 and !(scaled >= 1.0);
        if (ok) ok = B.plausible(1, &x, limit[l], N, L);
        if (ok) ok = B.residual(1, kopts, &x, &rhs, &g, &diag, N, L);
        if (ok) {
            x[l] = x_old[l];
            out[l] = .{ .r = .{ .converged = true, .iterations = @intCast(tick + 1) }, .x = x[l] };
            active[l] = false;
        }
    };
    for (active, x, &out) |on, xl, *o| if (on) {
        o.* = .{ .r = .{ .converged = false, .iterations = opts.max_iter }, .x = xl };
    };
    return out;
}

/// Lane l of `got` against `want`: the iterates, the result and the
/// published x, bitwise.
fn expectLaneBitwise(l: usize, want: Outcome, want_t: *const Trace, got: Outcome, got_t: *const Trace) !void {
    errdefer std.debug.print("lane {d}: converger {any} x={e} ({d} iterates), lanes {any} x={e} ({d})\n", .{ l, want.r, want.x, want_t.len, got.r, got.x, got_t.len });
    try testing.expectEqual(want.r, got.r);
    try testing.expectEqual(@as(u64, @bitCast(want.x)), @as(u64, @bitCast(got.x)));
    try testing.expectEqual(want_t.len, got_t.len);
    for (want_t.xs[0..want_t.len], got_t.xs[0..got_t.len]) |w, gx| try testing.expectEqual(@as(u64, @bitCast(w)), @as(u64, @bitCast(gx)));
}

test "dv absent is the unbounded loop: bitwise a bound that never fires" {
    // Oracle: the same solve under dv = 1e300, which no update reaches
    // (the largest is about 5 V), bitwise on x and the result. From v = 0
    // the unbounded loop exhausts its budget, so every iteration is
    // compared, failure included.
    // Spec: `Options.dv` absent is inf (its doc), checked apart from the
    // clamp so no clamp mutant can hide a finite default.
    try testing.expect(std.math.isPositiveInf((converger.Options{}).dv));
    const absent = try solveJunction(.{ .gmin = 0 }, 0);
    const inert = try solveJunction(.{ .gmin = 0, .dv = 1e300 }, 0);
    try testing.expect(!absent.r.converged);
    try testing.expectEqual(absent.r, inert.r);
    try testing.expectEqual(@as(u64, @bitCast(absent.x)), @as(u64, @bitCast(inert.x)));
}

test "dv: a junction the unbounded loop cannot reach converges under the bound, to its root" {
    // Oracle: the root by bisection; the published point lies within the
    // Newton tolerance reltol |v| + vntol of it (1e-3, 1e-6: `Options`'
    // defaults), the accuracy of any accepted point. A model of the loop in
    // double precision (scratchpad sim/dv.py): unbounded, no convergence in
    // 100; dv = 0.5, 18 iterations, 3.0e-4 V from the root against a
    // tolerance of 6.7e-4 V.
    const want = Junction.root();
    const o: converger.Options = .{ .gmin = 0 };
    const unbounded = try solveJunction(o, 0);
    try testing.expect(!unbounded.r.converged);
    const bounded = try solveJunction(.{ .gmin = 0, .dv = 0.5 }, 0);
    try testing.expect(bounded.r.converged);
    const tol = o.reltol * @abs(want) + o.vntol;
    if (!(@abs(bounded.x - want) <= tol)) {
        std.debug.print("dv=0.5: v = {e}, root {e}: {e} tolerances (tol {e} V) after {d} iterations\n", .{ bounded.x, want, @abs(bounded.x - want) / tol, tol, bounded.r.iterations });
        return error.TestUnexpectedResult;
    }
}

test "dv: the clamp by hand bounds each potential, leaves flows and NaN, and marks the iteration limited" {
    // Oracle: the vectors written out. Rows: two potentials, two flows,
    // one potential carrying NaN; dv = 1.
    const clamp = converger.test_access.clampUpdate;
    const rows = [_]bool{ false, false, true, true, false };
    var dx = [_]f64{ 5, -0.3, 0.1, 7, std.math.nan(f64) };
    try testing.expect(clamp(1, &dx, &rows, 1, true));
    try testing.expectEqualSlices(f64, &.{ 1, -0.3, 0.1, 7 }, dx[0..4]);
    try testing.expect(std.math.isNan(dx[4]));
    var neg = [_]f64{-5};
    try testing.expect(clamp(1, &neg, rows[0..1], 1, true));
    try testing.expectEqual(@as(f64, -1), neg[0]);
    // Nothing over the bound: nothing clamped, nothing marked.
    var small = [_]f64{ 0.5, -1, 9 };
    try testing.expect(!clamp(1, &small, rows[0..3], 1, true));
    try testing.expectEqualSlices(f64, &.{ 0.5, -1, 9 }, &small);
    // Four lanes: lane 2 alone asks for 5 V on the potential, and only
    // the active lanes are reported.
    const L = Lanes(4);
    var lanes_dx = [_]L.V{ .{ 0.2, -0.4, 5, 0.9 }, .{ 30, 30, 30, 30 } };
    try testing.expectEqual(@as(L.Mask, 0b0100), clamp(4, &lanes_dx, rows[1..3], 1, L.every));
    try testing.expectEqual(L.V{ 0.2, -0.4, 1, 0.9 }, lanes_dx[0]);
    try testing.expectEqual(L.V{ 30, 30, 30, 30 }, lanes_dx[1]);
    var inactive = [_]L.V{.{ 0, 0, 5, 0 }};
    try testing.expectEqual(@as(L.Mask, 0), clamp(4, &inactive, rows[0..1], 1, 0b1011));
    // The iteration that clamped is refused as limited.
    const sys: Toy = .{};
    var x = [_]f64{1};
    var x_old = [_]f64{0};
    var one = [_]f64{1};
    try testing.expect(clamp(1, &one, rows[0..1], 0.5, true));
    const st = converger.test_access.finalizeStep(1, &sys, {}, &x, &one, &x_old, &[_]f64{0}, &[_]f64{1}, 1, 0, .{}, converger.x_plausible, true, true, true, true);
    try testing.expect(!st.converged);
    try testing.expect(st.why == .limited);
}

test "dv: a clamped iterate is not accepted even when every row test passes" {
    // Oracle: the gate order, with the clamp's verdict the only input
    // that differs. An update of 1e-9 V at 1 V scores 1e-6 of its
    // tolerance and the residual is 0, so the unclamped iterate converges;
    // the same iterate marked clamped is limited.
    const sys: Toy = .{};
    for ([_]bool{ false, true }) |clamped| {
        var x = [_]f64{1};
        var x_old = [_]f64{0};
        const dx = [_]f64{1e-9};
        const st = converger.test_access.finalizeStep(1, &sys, {}, &x, &dx, &x_old, &[_]f64{0}, &[_]f64{1}, 1, 0, .{}, converger.x_plausible, true, true, true, clamped);
        try testing.expectEqual(!clamped, st.converged);
        if (clamped) try testing.expect(st.why == .limited) else try testing.expect(st.why == .converged);
    }
}

test "dv on the lane kernel bodies: every lane's iterates are bitwise converger.newton's at W = 1" {
    // Oracle: `converger.newton` from each lane's start, one run per lane.
    // dv = 0.5 clamps lane 0's first step (about 5 V) and lane 2's (about
    // 8 V up from -3 V), so the clamped value is compared; dv = 1e-4
    // clamps lane 1's every step from 0.6 V to a delta score near 0.17,
    // which only the limited veto keeps from being accepted.
    const v0s = [_]f64{ 0, 0.6, -3, 0.9 };
    for ([_]f64{ 0.5, 1e-4 }) |dv| {
        const opts: converger.Options = .{ .gmin = 0, .dv = dv };
        var traces: [v0s.len]Trace = @splat(.{});
        const got = try laneJunctions(v0s.len, true, opts, v0s, &traces);
        for (v0s, got, &traces, 0..) |v0, o, *t, l| {
            var want_t: Trace = .{};
            const want = try traceJunction(opts, v0, &want_t);
            try expectLaneBitwise(l, want, &want_t, o, t);
        }
        // dv = 0.5 is the bound that lets lane 0 converge (the test above).
        if (dv == 0.5) try testing.expect(got[0].r.converged);
        if (dv == 1e-4) try testing.expect(!got[1].r.converged);
    }
}

test "dv absent on the lane kernel bodies: today's kernel, bitwise, and converger.newton's iterates" {
    // Oracles: the bodies without `clampUpdate` (the kernel before `dv`),
    // and `converger.newton` with dv absent, lane by lane, bitwise. Lanes
    // 1 and 3 converge, so a clamp that fired at inf would show.
    const v0s = [_]f64{ 0, 0.6, -3, 0.9 };
    const opts: converger.Options = .{ .gmin = 0 };
    var with: [v0s.len]Trace = @splat(.{});
    var without: [v0s.len]Trace = @splat(.{});
    const got = try laneJunctions(v0s.len, true, opts, v0s, &with);
    const today = try laneJunctions(v0s.len, false, opts, v0s, &without);
    for (v0s, got, today, &with, &without, 0..) |v0, o, d, *t, *u, l| {
        try expectLaneBitwise(l, d, u, o, t);
        var want_t: Trace = .{};
        const want = try traceJunction(opts, v0, &want_t);
        try expectLaneBitwise(l, want, &want_t, o, t);
    }
    try testing.expect(got[1].r.converged and got[3].r.converged);
}
