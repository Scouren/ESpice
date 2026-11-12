//! The lane kernels' hold rows, gmin stamps and diagonal gmin
//! (`kernels/lane.zig` `loadExtras`, `gminRow`) inside the lane Newton,
//! lane-uniform and per lane (the ladder's `[gmin, hold scale]` plane and
//! INITFIX). Oracle: `converger.newton` at W = 1 from each lane's start
//! with that lane's gmin, holds at value * scale and INITFIX, one run per
//! lane, bitwise on every iterate, the result and the published x.
//!
//! Contents (test fixtures only): `Pair` (with a `Hook` of the converger's
//! `assemble`, `vals` and `diagAt` that logs its iterates)

const std = @import("std");
const testing = std.testing;
const converger = @import("converger.zig");
const Workspace = @import("newton_workspace.zig").Workspace;
const lk = @import("kernels/lane.zig");

/// Two nodes: a limiter-less junction at node 0, fed from 5 V through
/// 1 kOhm, coupled to node 1 through 2 kOhm, and node 1 to ground through
/// 3 kOhm. Dense 2 x 2 pattern in CSC order: slot 0 (0,0), 1 (1,0),
/// 2 (0,1), 3 (1,1).
const Pair = struct {
    n: u32 = 2,
    nnz: u32 = 4,
    diag_slots: [2]u32 = .{ 0, 3 },
    current_row: []const bool = &.{ false, false },
    rhs: []f64,
    g: [4]f64 = @splat(0),
    /// Every x[0] and x[1] the Newton assembled at, in order.
    log: [256]f64 = undefined,
    len: usize = 0,

    const col_ptr = [_]u32{ 0, 2, 4 };
    const row_idx = [_]u32{ 0, 1, 0, 1 };
    const vs = 5.0;
    const r = 1e3;
    const r2 = 2e3;
    const r3 = 3e3;
    const is = 1e-14;
    const vt = 0.025;

    fn load(sys: *Pair, x: []const f64) void {
        sys.log[sys.len] = x[0];
        sys.log[sys.len + 1] = x[1];
        sys.len += 2;
        const e = @exp(x[0] / vt);
        sys.rhs[0] = (x[0] - vs) / r + is * (e - 1) + (x[0] - x[1]) / r2;
        sys.rhs[1] = (x[1] - x[0]) / r2 + x[1] / r3;
        sys.g = .{ 1.0 / r + is / vt * e + 1.0 / r2, -1.0 / r2, -1.0 / r2, 1.0 / r2 + 1.0 / r3 };
    }

    const Hook = struct {
        pub fn assemble(_: @This(), sys: *Pair, x: []const f64, _: f64) void {
            sys.load(x);
        }
        pub fn vals(_: @This(), sys: *Pair) []f64 {
            return &sys.g;
        }
        pub fn diagAt(_: @This(), sys: *Pair, slot: u32) f64 {
            return sys.g[slot];
        }
    };
};

const Outcome = struct { r: converger.Result, x: [2]f64, log: []const f64 };

/// Lanes and their starts.
const N = 3;
const v0s = [N][2]f64{ .{ 0, 0 }, .{ 0.3, 0.1 }, .{ 0.8, 0.5 } };

// ---- private ----

/// `converger.newton` on one `Pair` from `x0`.
fn hostPair(opts: converger.Options, x0: [2]f64, sys: *Pair) !Outcome {
    const a = testing.allocator;
    var ws = try Workspace.init(a, 2, &Pair.col_ptr, &Pair.row_idx, null, .{}, .{});
    defer ws.deinit(a);
    var x = x0;
    const r = try converger.newton(sys, &ws, &x, 0, opts, Pair.Hook{});
    return .{ .r = r, .x = x, .log = sys.log[0..sys.len] };
}

/// N `Pair` lanes through the lane kernel bodies on the host (`HostP`),
/// lane-major, in `lane_device.zig`'s tick order: assemble, `extras`
/// (`loadExtras` from the lane-uniform tables), the converger's own factor
/// and solve (the bodies' LU is bitwise `LaneLu`'s, `kernels/lane.zig`'s
/// tests), `update`, `gates` and `finalize` with INITFIX. Lane l takes
/// gmin `h[l][0]`, its holds at value * `h[l][1]` and INITFIX `fix[l]`
/// (`lane_device.zig`'s `gmin` and `extras` under `per_lane`); `opts`
/// gives the tables and tolerances.
fn lanePairs(opts: converger.Options, h: [N][2]f64, fix_in: [N]bool, syss: *[N]Pair) ![N]Outcome {
    const a = testing.allocator;
    const B = lk.Bodies(lk.HostP);
    std.debug.assert(opts.force.len <= 8 and opts.gmin_stamps.len <= 8);
    // One workspace per lane, as each host run has its own: the factor
    // keeps its pivot order from one call to the next.
    var wss: [N]Workspace = undefined;
    var made: usize = 0;
    defer for (wss[0..made]) |*w| w.deinit(a);
    for (&wss) |*w| {
        w.* = try Workspace.init(a, 2, &Pair.col_ptr, &Pair.row_idx, null, .{}, .{});
        made += 1;
    }
    var force: [8]lk.ForceRow = undefined;
    for (force[0..opts.force.len], opts.force) |*r, f| r.* = .{ .value = f.value, .slot = f.slot, .row = f.row };
    var stamps: [8]lk.GminStamp = undefined;
    for (stamps[0..opts.gmin_stamps.len], opts.gmin_stamps) |*s, g| s.* = .{ .slot = g.slot, .row = g.row, .col = g.col };
    const n_force: u32 = @intCast(opts.force.len);
    const n_stamps: u32 = @intCast(opts.gmin_stamps.len);
    const kopts: lk.NewtonOpts = .{ .reltol = opts.reltol, .abstol = opts.abstol, .vntol = opts.vntol, .gmin = opts.gmin, .residual_tol = opts.residual_tol, .dv = opts.dv, .max_iter = opts.max_iter, .n_force = n_force, .n_stamps = n_stamps };
    var x: [2 * N]f64 = undefined;
    for (v0s, 0..) |v, l| for (v, 0..) |e, i| {
        x[i * N + l] = e;
    };
    var x_old: [2 * N]f64 = undefined;
    var dx: [2 * N]f64 = undefined;
    var rhs: [2 * N]f64 = undefined;
    var g: [4 * N]f64 = undefined;
    var limit: [N]f64 = undefined;
    var diag = [_]u32{ 0, 3 };
    var cur: [2]u8 = @splat(0);
    var out: [N]Outcome = undefined;
    var active: [N]bool = @splat(true);
    var fix = fix_in;
    for (0..opts.max_iter) |tick| for (0..N) |l| {
        if (!active[l]) continue;
        const L: u32 = @intCast(l);
        const sys = &syss[l];
        sys.load(&[_]f64{ x[l], x[N + l] });
        for (0..2) |i| rhs[i * N + l] = sys.rhs[i];
        for (0..4) |p| g[p * N + l] = sys.g[p];
        // `linearTick`: the diagonal `gmin` kernel without stamps, then `extras`.
        if (n_stamps == 0) for (0..2) |i| B.gminRow(i, h[l][0], &x, &rhs, &g, &diag, N, L);
        B.loadExtras(n_stamps, &stamps, h[l][0], n_force, &force, h[l][1], &x, &rhs, &g, N, L);
        if (tick == 0) limit[l] = B.plausibleLimit(2, &x, &rhs, &g, &diag, N, L);
        var v: [4]f64 = undefined;
        for (&v, 0..) |*e, p| e.* = g[p * N + l];
        var r1: [2]f64 = undefined;
        for (&r1, 0..) |*e, i| e.* = rhs[i * N + l];
        var d: [2]f64 = undefined;
        try wss[l].slv.factor(&v, .{});
        wss[l].slv.solveNeg(&r1, &d);
        for (d, 0..) |e, i| dx[i * N + l] = e;
        const clamped = B.clampUpdate(2, &dx, &cur, kopts.dv, N, L);
        const scaled = B.updateNorm(2, &x, &dx, &x_old, &cur, kopts.reltol, kopts.abstol, kopts.vntol, N, L);
        var ok = !clamped and tick != 0 and !(scaled >= 1.0);
        if (ok) ok = B.plausible(2, &x, limit[l], N, L);
        if (ok) ok = B.residual(2, kopts, &x, &rhs, &g, &diag, N, L);
        if (ok and fix[l]) {
            fix[l] = false;
        } else if (ok) {
            for (0..2) |i| x[i * N + l] = x_old[i * N + l];
            out[l] = .{ .r = .{ .converged = true, .iterations = @intCast(tick + 1) }, .x = .{ x[l], x[N + l] }, .log = sys.log[0..sys.len] };
            active[l] = false;
        }
    };
    for (active, &out, syss, 0..) |on, *o, *sys, l| if (on) {
        o.* = .{ .r = .{ .converged = false, .iterations = opts.max_iter }, .x = .{ x[l], x[N + l] }, .log = sys.log[0..sys.len] };
    };
    return out;
}

/// Every lane of `lanePairs` against its own `hostPair`, bitwise, with
/// `opts` on every lane.
fn expectLanesBitwise(opts: converger.Options) ![N]Outcome {
    return expectLanesEach(opts, @splat(.{ opts.gmin, 1.0 }), @splat(opts.init_fix));
}

/// `expectLanesBitwise` with lane l at gmin `h[l][0]`, holds scaled by
/// `h[l][1]` and INITFIX `fix[l]`; its `hostPair` gets them as plain
/// `converger.Options`, the holds' values multiplied out.
fn expectLanesEach(opts: converger.Options, h: [N][2]f64, fix: [N]bool) ![N]Outcome {
    var lane_sys: [N]Pair = undefined;
    var lane_rhs: [N][2]f64 = undefined;
    for (&lane_sys, &lane_rhs) |*s, *r| s.* = .{ .rhs = r };
    const got = try lanePairs(opts, h, fix, &lane_sys);
    for (got, v0s, 0..) |o, v0, l| {
        var rhs: [2]f64 = undefined;
        var sys: Pair = .{ .rhs = &rhs };
        var scaled: [8]converger.Force = undefined;
        for (scaled[0..opts.force.len], opts.force) |*sc, f| sc.* = .{ .slot = f.slot, .row = f.row, .value = f.value * h[l][1] };
        var lopts = opts;
        lopts.gmin = h[l][0];
        lopts.force = scaled[0..opts.force.len];
        lopts.init_fix = fix[l];
        const want = try hostPair(lopts, v0, &sys);
        errdefer std.debug.print("lane {d}: converger {any} x={any} ({d} iterates), lanes {any} x={any} ({d})\n", .{ l, want.r, want.x, want.log.len / 2, o.r, o.x, o.log.len / 2 });
        try testing.expectEqual(want.r, o.r);
        for (want.x, o.x) |w, e| try testing.expectEqual(@as(u64, @bitCast(w)), @as(u64, @bitCast(e)));
        try testing.expectEqual(want.log.len, o.log.len);
        for (want.log, o.log) |w, e| try testing.expectEqual(@as(u64, @bitCast(w)), @as(u64, @bitCast(e)));
    }
    return got;
}

test "lane extras: hold rows in the lane Newton are bitwise converger.newton's per lane, INITFIX and not" {
    // Two holds, node 1 at 0.2 V (slot 3) and node 0 at 0.65 V (slot 0),
    // as `op.forceNodeset` forces nodesets and the plain rung `.ic` rows.
    // A hold pins its node within force_g of its value, so a held lane's
    // published x sits there: the check that the rows were loaded at all.
    const holds = [_]converger.Force{ .{ .slot = 3, .row = 1, .value = 0.2 }, .{ .slot = 0, .row = 0, .value = 0.65 } };
    for ([_]bool{ true, false }) |init_fix| {
        const got = try expectLanesBitwise(.{ .gmin = 0, .force = &holds, .init_fix = init_fix });
        for (got) |o| {
            try testing.expect(o.r.converged);
            try testing.expect(@abs(o.x[1] - 0.2) < 1e-6);
        }
    }
}

test "lane extras: gmin stamps in the lane Newton are bitwise converger.newton's per lane" {
    // Off-diagonal and repeated stamps (row 1, col 0 twice), then a hold
    // on slot 0, which a stamp also loads: the table order is the sum
    // order. gmin 1e-3 S is large enough to move every iterate.
    const stamps = [_]converger.GminStamp{ .{ .slot = 1, .row = 1, .col = 0 }, .{ .slot = 0, .row = 0, .col = 0 }, .{ .slot = 1, .row = 1, .col = 0 } };
    const holds = [_]converger.Force{.{ .slot = 0, .row = 0, .value = 0.6 }};
    _ = try expectLanesBitwise(.{ .gmin = 1e-3, .gmin_stamps = &stamps });
    _ = try expectLanesBitwise(.{ .gmin = 1e-3, .gmin_stamps = &stamps, .force = &holds, .init_fix = true });
}

test "lane extras: per-lane gmin, hold scale and INITFIX are each lane's converger.newton, bitwise" {
    // The ladder's lanes on different rungs: lane 0 a gmin step with no
    // stamps (the diagonal), lane 1 a source step at lambda 0.375, lane 2
    // the final solve (gmin 0, full holds), INITFIX on lane 0 only. Then
    // the same planes with stamps, where gmin lands only at them.
    const holds = [_]converger.Force{.{ .slot = 3, .row = 1, .value = 0.2 }};
    const h = [N][2]f64{ .{ 1e-3, 1.0 }, .{ 0, 0.375 }, .{ 0, 1.0 } };
    const fix = [N]bool{ true, false, false };
    const got = try expectLanesEach(.{ .gmin = 1e-3, .force = &holds }, h, fix);
    // A hold at value * scale pins its node there: lane 1 at 0.075 V.
    try testing.expect(@abs(got[1].x[1] - 0.075) < 1e-6);
    const stamps = [_]converger.GminStamp{ .{ .slot = 1, .row = 1, .col = 0 }, .{ .slot = 0, .row = 0, .col = 0 } };
    const hs = [N][2]f64{ .{ 1e-2, 0.5 }, .{ 1e-4, 1.0 }, .{ 0, 0 } };
    _ = try expectLanesEach(.{ .gmin = 1e-2, .gmin_stamps = &stamps, .force = &holds }, hs, fix);
}
