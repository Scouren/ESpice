//! Lever c3 (`confirm.zig`) inside `converger.newton`, on a linear 2x2
//! system. Oracles: the lever-off engine, bitwise (an accept publishes the
//! point the confirming iteration would), and the factor and solve calls
//! the fixture counts itself, written out.
//!
//! Contents (test fixtures only): `Linear2` (with `deviceSolve` and a
//! `Hook` of the converger's `assemble`, `vals` and `diagAt`), `LinearRun`

const std = @import("std");
const testing = std.testing;
const Levers = @import("core").perf.Levers;
const converger = @import("converger.zig");
const Workspace = @import("newton_workspace.zig").Workspace;
const direct = @import("direct.zig");
const Knobs = converger.Knobs;

/// F(x) = A x - b on the dense 2x2 pattern (CSC: (0,0), (1,0), (0,1),
/// (1,1)). `drift` moves A(0,0) by 2^-30 per evaluation, so the matrix
/// changes between iterations. It factors and solves through `newton`'s
/// device seam on the host solver, which is bitwise the host path, so the
/// factor and solve calls `newton` makes are counted here, independently of
/// the lever's own counters.
const Linear2 = struct {
    n: u32 = 2,
    nnz: u32 = 4,
    diag_slots: [2]u32 = .{ 0, 3 },
    current_row: []const bool = &.{ false, false },
    rhs: []f64,
    g: [4]f64 = .{ 2, -1, -1, 2 },
    b: [2]f64 = .{ 1, 0.3 },
    drift: bool = false,
    evals: u32 = 0,
    /// `factor` calls (bypassed ones included) and `solveNeg` calls.
    factor_calls: u32 = 0,
    solves: u32 = 0,

    /// `newton`'s device seam, run on the host solver: today's factor and
    /// solve, counted. A failed factor returns false, and `newton` refactors.
    pub fn deviceSolve(self: *Linear2, slv: *direct.Solver, vals: []f64, dx: []f64) ?bool {
        self.factor_calls += 1;
        slv.factor(vals, .{}) catch return false;
        slv.solveNeg(self.rhs, dx);
        self.solves += 1;
        return true;
    }

    const Hook = struct {
        pub fn assemble(_: @This(), sys: *Linear2, x: []const f64, _: f64) void {
            if (sys.drift) sys.g[0] = 2 + @as(f64, @floatFromInt(sys.evals)) * 0x1p-30;
            sys.evals += 1;
            sys.rhs[0] = sys.g[0] * x[0] + sys.g[2] * x[1] - sys.b[0];
            sys.rhs[1] = sys.g[1] * x[0] + sys.g[3] * x[1] - sys.b[1];
        }
        pub fn vals(_: @This(), sys: *Linear2) []f64 {
            return &sys.g;
        }
        pub fn diagAt(_: @This(), sys: *Linear2, slot: u32) f64 {
            return sys.g[slot];
        }
    };
};

/// Two steps of `Linear2` (the source moves between them) on one workspace:
/// each step's published x and the x_old it leaves, iterations, the
/// evaluations, factor and solve calls the fixture saw, the factorizations
/// the solver ran, and the lever's own counts (stage 1 skips, stage 2
/// accepts).
const LinearRun = struct {
    x: [2][2]f64,
    x_old: [2][2]f64,
    iters: [2]u16,
    evals: [2]u32,
    factor_calls: [2]u32,
    solves: [2]u32,
    factors: u32,
    skips: u64,
    accepts: u64,
};

// ---- private ----

/// Runs `LinearRun`'s two steps with the levers `perf` and the linear flag.
fn solveLinear(perf: Levers, linear: bool, drift: bool) !LinearRun {
    const a = testing.allocator;
    var rhs = [_]f64{ 0, 0 };
    var sys: Linear2 = .{ .rhs = &rhs, .drift = drift };
    var ws = try Workspace.init(a, 2, &.{ 0, 2, 4 }, &.{ 0, 1, 0, 1 }, null, Knobs{ .perf = perf }, .{});
    defer ws.deinit(a);
    ws.linear = linear;
    var out: LinearRun = undefined;
    var x = [_]f64{ 0, 0 };
    const sources = [2][2]f64{ .{ 1, 0.3 }, .{ 0.7, 1.1 } };
    for (sources, 0..) |b, step| {
        sys.b = b;
        sys.factor_calls = 0;
        sys.solves = 0;
        const evals = sys.evals;
        const r = try converger.newton(&sys, &ws, &x, 0, .{ .gmin = 0 }, Linear2.Hook{});
        try testing.expect(r.converged);
        out.x[step] = x;
        out.x_old[step] = ws.x_old[0..2].*;
        out.evals[step] = sys.evals - evals;
        out.iters[step] = r.iterations;
        out.factor_calls[step] = sys.factor_calls;
        out.solves[step] = sys.solves;
    }
    out.factors = ws.slv.gen;
    out.skips = ws.confirm.linear_skips;
    out.accepts = ws.confirm.linear_accepts;
    return out;
}

test "c3 stage 2: a linear circuit runs one iteration per step and leaves the two-iteration path's x and x_old bitwise" {
    // Oracle: the two-iteration path (lever off), bitwise on x and x_old,
    // and the calls the fixture counts, written out: per step 2
    // evaluations, 2 factor calls and 2 solves with the lever off, 1, 1 and
    // 1 with it on. Only step 1's first factor runs. The lever's own
    // counters are checked second.
    const off = try solveLinear(.{}, true, false);
    try testing.expectEqual([2]u16{ 2, 2 }, off.iters);
    try testing.expectEqual([2]u32{ 2, 2 }, off.evals);
    try testing.expectEqual([2]u32{ 2, 2 }, off.factor_calls);
    try testing.expectEqual([2]u32{ 2, 2 }, off.solves);
    try testing.expectEqual(@as(u32, 1), off.factors);
    try testing.expectEqual(@as(u64, 0), off.skips + off.accepts);
    {
        const perf = Levers{ .c3 = true };
        const on = try solveLinear(perf, true, false);
        try testing.expectEqual(off.iters, on.iters);
        try testing.expectEqual([2]u32{ 1, 1 }, on.evals);
        try testing.expectEqual([2]u32{ 1, 1 }, on.factor_calls);
        try testing.expectEqual([2]u32{ 1, 1 }, on.solves);
        try testing.expectEqual(@as(u32, 1), on.factors);
        try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&off.x), std.mem.sliceAsBytes(&on.x)));
        try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&off.x_old), std.mem.sliceAsBytes(&on.x_old)));
        try testing.expectEqual(@as(u64, 2), on.accepts);
        try testing.expectEqual(@as(u64, 0), on.skips);
    }
    // Without the flag nothing is skipped.
    const unflagged = try solveLinear(.{ .c3 = true }, false, false);
    try testing.expectEqual([2]u32{ 2, 2 }, unflagged.evals);
    try testing.expectEqual(@as(u64, 0), unflagged.skips + unflagged.accepts);
}

test "c3 stage 1: with stage 2 declined (n3 on), a linear circuit solves once per step and publishes lever-off's vector bitwise" {
    // Oracle: the lever-off engine, bitwise, and the calls the fixture
    // counts, written out: per step 2 evaluations, 1 factor call and 1
    // solve with the lever on. The lever's own counters are checked second.
    const off = try solveLinear(.{}, true, false);
    {
        const perf = Levers{ .c3 = true, .n3 = true };
        const on = try solveLinear(perf, true, false);
        try testing.expectEqual(off.iters, on.iters);
        try testing.expectEqual([2]u32{ 2, 2 }, on.evals);
        try testing.expectEqual([2]u32{ 1, 1 }, on.factor_calls);
        try testing.expectEqual([2]u32{ 1, 1 }, on.solves);
        try testing.expectEqual(@as(u32, 1), on.factors);
        try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&off.x), std.mem.sliceAsBytes(&on.x)));
        try testing.expectEqual(@as(u64, 2), on.skips);
        try testing.expectEqual(@as(u64, 0), on.accepts);
    }
}

test "c3: no linear flag, or a matrix that changed, takes today's solve" {
    // Oracle: the lever-off engine, bitwise, and no skip counted. The flag
    // is off on the fixed matrix and on with the moving one. Stage 2 trusts
    // the flag and cannot see a moving matrix, so it is declined (n3 on)
    // and stage 1's own matrix test is the one under test.
    for ([_]bool{ false, true }) |drift| {
        const off = try solveLinear(.{}, drift, drift);
        const on = try solveLinear(.{ .c3 = true, .n3 = true }, drift, drift);
        try testing.expectEqual(@as(u64, 0), on.skips + on.accepts);
        try testing.expectEqual(off.iters, on.iters);
        try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&off.x), std.mem.sliceAsBytes(&on.x)));
    }
}
