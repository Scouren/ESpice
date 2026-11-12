//! The operating point for the lanes of one batch: the setup and the plain
//! rung run as W host lanes (`solveLanes`) or every lane on the GPU
//! (`solveGpuLanes`); a lane the plain rung leaves unconverged or singular
//! peels to its own scalar ladder from rung 2 (class E: the stepping rungs
//! are not masked yet).
//! In: W circuits on one pattern and their start vectors. Out: one
//! `op.LaneOutcome` per lane.
//! Cites dev/research/lane-batched-simulation.md §6 (the `.op` ladder);
//! 06 6.9 (GPU lanes).
//!
//! Contents:
//! - `pub fn solveLanes(comptime W: usize, ckts, xs, options, nodeset, ic, out: []LaneOutcome) !void`
//! - `pub fn solveGpuLanes(comptime W: usize, ckts, xs, options, nodeset, ic, out: []LaneOutcome) !void`

const std = @import("std");
const assert = std.debug.assert;
const solver = @import("solver");
const converger = solver.converger;
const Ic = @import("core").Ic;
const root = @import("../types.zig");
const gpu_lanes = @import("../gpu/lanes.zig");
const lanes_static = @import("../gpu/lanes_static.zig");
const op = @import("op.zig");
const op_ladder = @import("op_ladder.zig");
const op_ladder_steps = @import("op_ladder_steps.zig");
const gmin_stamps = @import("gmin_stamps.zig");
const Options = op.Options;
const LaneOutcome = op.LaneOutcome;

/// `op.solve` for the lanes of one batch, each lane bitwise its own
/// `op.solve`. A batch with nodesets, a floating start, a JFNK pin or
/// `-Dcertify` runs every lane's scalar `op.solve`. Lane l's outcome lands
/// in `out[l]`; the call itself fails only when the lane solve does (out of
/// memory), which fails every lane. Asserts 1 <= `ckts.len` <= W and that
/// `xs` and `out` match it.
pub fn solveLanes(comptime W: usize, ckts: []const *root.Circuit, xs: []const []f64, options: Options, nodeset: []const Ic, ic: []const Ic, out: []LaneOutcome) !void {
    const g = ckts.len;
    assert(g >= 1);
    assert(g <= W);
    assert(xs.len == g);
    assert(out.len == g);
    const c0 = ckts[0];
    const held = if (options.tran_op) ic else &.{};
    const laned = W > 1 and g > 1 and nodeset.len == 0 and !(c0.needs_tran_op and held.len == 0) and op.lanesAllowed(c0);
    if (!laned) {
        for (ckts, xs, out) |c, x, *o| o.* = op.solve(c, x, options, nodeset, ic);
        return;
    }
    const System = solver.lane_system.LaneSystem(W, root.Circuit, root.EvalHook);
    const L = solver.lanes.Lanes(W);
    // Unused lanes repeat lane 0 and stay inactive.
    var lanes: [W]*root.Circuit = undefined;
    var wss: [W]*converger.Workspace = undefined;
    for (&lanes, &wss, 0..) |*c, *w, l| {
        c.* = ckts[if (l < g) l else 0];
        if (l < g) {
            try op.beginSolve(c.*, xs[l], options);
            w.* = try c.*.workspace();
        } else w.* = wss[0];
    }
    const gpa = wss[0].slv.gpa;
    const force = try gpa.alloc(converger.Force, held.len);
    defer gpa.free(force);

    for (held, force) |h, *f| f.* = .{ .slot = c0.diag_slots[h.node], .row = h.node, .value = h.value };
    var sys = try System.init(gpa, lanes, .{});
    defer sys.deinit(gpa);

    sys.active = @truncate(@as(u64, std.math.maxInt(L.Mask)) >> @intCast(W - g));
    var lws = try converger.LaneWorkspace(W).init(gpa, wss);
    defer lws.deinit(gpa);

    const xv = try gpa.alloc(L.V, c0.n);
    defer gpa.free(xv);

    for (xs, 0..) |x, l| System.putLane(xv, x, l);
    // The plain rung, as `op_ladder.solve` and `converger.run` run it.
    var copts = converger.optionsFromTolerances(options.tol, null);
    copts.gmin = 0;
    copts.init_fix = !options.warm_start;
    copts.force = force;
    const res = converger.newtonLanes(W, &sys, &lws, xv, @splat(0), copts, System.LaneHook{});
    sys.clearLimits();
    const plain = try res;
    for (xs, 0..) |x, l| System.getLane(x, xv, l);

    for (ckts, xs, out, 0..) |c, x, *o, l| {
        const bit = @as(L.Mask, 1) << @intCast(l);
        const p: ?converger.Result = if (plain.singular & bit != 0) null else .{ .converged = plain.converged & bit != 0, .iterations = plain.iterations[l] };
        const r = op_ladder.afterPlain(c, wss[l], x, options, force, p) catch |e| {
            o.* = e;
            continue;
        };
        op.endSolve(c, r.converged, options);
        o.* = r;
    }
}

/// `solveLanes` for any number of lanes with every lane's plain rung on the
/// GPU: one device Newton from INITFIX, as `op.solve` runs it; a lane it
/// leaves unconverged, singular or with a flipped latch takes its own
/// ladder from rung 2 on the host, from the device state it started with.
/// Within tolerance of `solveLanes`, not bitwise: the device replays one LU
/// pivot order. A batch the device cannot take (nodesets, `.ic` holds, a
/// floating start, a JFNK pin, `-Dcertify`, `gpu_lanes.staticRefusal`, a
/// driver error) runs `solveLanes` W lanes at a time. Asserts that `xs` and
/// `out` match `ckts`.
pub fn solveGpuLanes(comptime W: usize, ckts: []const *root.Circuit, xs: []const []f64, options: Options, nodeset: []const Ic, ic: []const Ic, out: []LaneOutcome) !void {
    assert(xs.len == ckts.len);
    assert(out.len == ckts.len);
    if (ckts.len == 0) return;
    const c0 = ckts[0];
    const held = if (options.tran_op) ic else &.{};
    const why: ?[]const u8 = if (ckts.len < 2 or nodeset.len != 0 or held.len != 0 or c0.needs_tran_op)
        "nodesets, holds or a floating start"
    else if (!op.lanesAllowed(c0))
        "a JFNK pin or certify"
    else if (options.tol.dv != null)
        "a Newton voltage bound (dv)"
    else
        gpu_lanes.staticRefusal(c0);
    if (why) |w| {
        if (c0.knobs.gpu_stats != .off) std.debug.print("gpu-lanes: op lanes on the CPU: {s}\n", .{w});
    } else if (solveOnDevice(ckts, xs, options, nodeset, ic, out)) return else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (c0.knobs.gpu_stats != .off) std.debug.print("gpu-lanes: op lanes declined ({s})\n", .{@errorName(e)}),
    }
    var i: usize = 0;
    while (i < ckts.len) : (i += W) {
        const end = @min(ckts.len, i + W);
        try solveLanes(W, ckts[i..end], xs[i..end], options, nodeset, ic, out[i..end]);
    }
}

// ---- private ----

/// `solveGpuLanes`' device half, `op.solve` on every lane at once: the
/// `.nodeset` step (`op.forceNodeset`: INITFIX with every hold and nodeset
/// row forced, from x at their values; a lane that fails it restarts from
/// there) and the plain rung holding the `.ic` rows under TRANOP, both as
/// device Newtons, the plain rung once for the cold lanes (INITFIX) and
/// once for those the step left warm. A lane whose device asked for a
/// reject in the step reruns `op.solve` from its start on the host, since
/// DC Newton iterates past a flipped latch and the device does not. Fails
/// before any lane's outcome is set (a driver error or `GpuLanes`
/// refusal) or with out of memory.
fn solveOnDevice(ckts: []const *root.Circuit, xs: []const []f64, options: Options, nodeset: []const Ic, ic: []const Ic, out: []LaneOutcome) !void {
    assert(ckts.len >= 2);
    const c0 = ckts[0];
    const gpa = c0.gpa;
    const n: usize = c0.n;
    const held = if (options.tran_op) ic else &.{};
    // `op.solve`'s rows: the holds, then the nodesets on rows no hold names.
    var force: std.ArrayList(converger.Force) = .empty;
    defer force.deinit(gpa);
    try force.ensureTotalCapacityPrecise(gpa, held.len + nodeset.len);
    for (held) |h| force.appendAssumeCapacity(.{ .slot = c0.diag_slots[h.node], .row = h.node, .value = h.value });
    for (nodeset) |ns| {
        for (held) |h| {
            if (h.node == ns.node) break;
        } else force.appendAssumeCapacity(.{ .slot = c0.diag_slots[ns.node], .row = ns.node, .value = ns.value });
    }
    const holds = force.items[0..held.len];
    const forcing = force.items.len > held.len;
    // Each lane's x as handed in, for a lane that reruns `op.solve`.
    const orig = try gpa.alloc(f64, ckts.len * n);
    defer gpa.free(orig);
    for (xs, 0..) |x, l| @memcpy(orig[l * n ..][0..n], x[0..n]);
    const res = try gpa.alloc(gpu_lanes.LaneNewton, ckts.len);
    defer gpa.free(res);
    const warm = try gpa.alloc(bool, ckts.len);
    defer gpa.free(warm);
    @memset(warm, options.warm_start);
    const host = try gpa.alloc(bool, ckts.len);
    defer gpa.free(host);
    @memset(host, false);
    for (ckts, xs) |c, x| try op.beginSolve(c, x, options);

    {
        if (forcing) for (xs) |x| for (force.items) |f| {
            x[f.row] = f.value;
        };
        const dev = try gpu_lanes.GpuLanes.initStatic(gpa, ckts, xs);
        defer dev.deinit();

        dev.prof.on = c0.knobs.gpu_stats != .off;
        if (forcing) {
            const start = try gpa.alloc(f64, ckts.len * n);
            defer gpa.free(start);
            for (xs, 0..) |x, l| @memcpy(start[l * n ..][0..n], x[0..n]);
            var fopts = converger.optionsFromTolerances(options.tol, null);
            fopts.init_fix = true;
            fopts.force = force.items;
            try dev.solveStatic(xs, fopts, res);
            for (res, xs, host, warm, 0..) |r, x, *h, *w, l| {
                if (r.reject) {
                    h.* = true;
                } else if (!r.singular and r.result.converged) {
                    w.* = true;
                } else @memcpy(x[0..n], start[l * n ..][0..n]);
            }
            try lanes_static.putX(dev, xs);
        }
        // The plain rung, as `op_ladder.solve` runs it: no gmin, the holds.
        var copts = converger.optionsFromTolerances(options.tol, null);
        copts.gmin = 0;
        copts.force = holds;
        for ([_]bool{ false, true }) |pass_warm| {
            var any = false;
            for (dev.round, warm, host) |*r, w, h| {
                r.* = @intFromBool(!h and w == pass_warm);
                any = any or r.* != 0;
            }
            if (!any) continue;
            copts.init_fix = !pass_warm;
            try dev.solveStatic(xs, copts, res);
        }
        // `deinit` copies back the device state of the lanes it settled; the
        // rest keep the host's start.
        for (res, dev.detached, host) |r, *d, h| d.* = h or !(r.result.converged and !r.singular and !r.reject);
    }
    for (ckts, xs, out, res, host, 0..) |c, x, *o, r, h, l| {
        if (h) {
            @memcpy(x[0..n], orig[l * n ..][0..n]);
            o.* = op.solve(c, x, options, nodeset, ic);
            continue;
        }
        const plain: ?converger.Result = if (r.singular) null else if (r.reject) .{ .converged = false, .iterations = r.result.iterations } else r.result;
        o.* = blk: {
            const ws = c.workspace() catch |e| break :blk e;
            // Rung 2 reads the plain rung's last assembly off the planes.
            if (plain == null or !plain.?.converged) c.evalNewton(x, 0);
            break :blk op_ladder.afterPlain(c, ws, x, options, holds, plain);
        };
        op.endSolve(c, if (o.*) |rr| rr.converged else |_| false, options);
    }
}

/// `op_ladder.afterPlain`'s rungs 2 and 3 and its final Newton on the
/// device, for each lane the plain rung (`res`) left unconverged or
/// singular: every lane its own `op_ladder_steps.Ladder`. The host keeps
/// the rung sequence, sets each lane's homotopy on its circuit (uploaded
/// as Model rows, `lanes_static.refreshModels`) and builds its gmin stamps
/// from its host planes evaluated at its x; the card runs each request's
/// Newton for every lane on it, with the lane's gmin, hold scale and
/// INITFIX in the per-lane planes. Lanes whose requests share an iteration
/// budget and a stamp table run as one round. A converged lane's result
/// lands in `done[l]`. A lane the ladder leaves unconverged (rungs 4 and 5
/// are the host's), whose device asked for a reject, or whose homotopy a
/// batch caches in its Instance rows (VerA `setup_simparams`: the device's
/// rows are live and stay as they were) is marked in `host`, its homotopy
/// put back. Within tolerance of the host ladder, not bitwise: the device
/// replays one LU pivot order. The host's half is
/// `tests/ladder_steps.zig`'s oracle.
fn ladderOnDevice(dev: *gpu_lanes.GpuLanes, ckts: []const *root.Circuit, xs: []const []f64, options: Options, holds: []const converger.Force, res: []gpu_lanes.LaneNewton, host: []bool, done: []?converger.Result) !void {
    const N = ckts.len;
    const n: usize = ckts[0].n;
    const gpa = ckts[0].gpa;
    const max = op_ladder.ladder_solves_max;
    assert(res.len == N and host.len == N and done.len == N);
    const on = try gpa.alloc(bool, N);
    defer gpa.free(on);
    const pending = try gpa.alloc(bool, N);
    defer gpa.free(pending);
    const fix = try gpa.alloc(bool, N);
    defer gpa.free(fix);
    const plane = try gpa.alloc([2]f64, N);
    defer gpa.free(plane);
    const ladders = try gpa.alloc(op_ladder_steps.Ladder, N);
    defer gpa.free(ladders);
    // ponytail: 16 KB of gmin history per lane; size it by the lanes on
    // the ladder if wide batches mostly converge plainly.
    const steps = try gpa.alloc(op_ladder.GminStep, N * max);
    defer gpa.free(steps);
    const x_good = try gpa.alloc(f64, N * n);
    defer gpa.free(x_good);
    const stamps = try gpa.alloc([]converger.GminStamp, N);
    defer gpa.free(stamps);
    @memset(stamps, &.{});
    defer for (stamps) |st| gpa.free(st);
    @memset(plane, .{ 0, 1.0 });
    @memset(fix, false);
    for (res, host, on, ladders, 0..) |r, h, *o, *lad, l| {
        o.* = !h and !(r.result.converged and !r.singular and !r.reject);
        if (!o.*) continue;
        const plain: ?converger.Result = if (r.singular) null else .{ .converged = false, .iterations = r.result.iterations };
        lad.* = .init(options.tol, steps[l * max ..][0..max], plain);
    }
    // Each pass feeds every lane still on the ladder one solve; a lane's
    // ladder is at most `max` gmin solves, a clean one, `max` source
    // solves, 11 sources-off ones and the final one.
    var passes: usize = 0;
    while (true) : (passes += 1) {
        assert(passes <= 2 * max + 13);
        var moved = false;
        var any = false;
        @memset(pending, false);
        for (ckts, xs, on, ladders, 0..) |c, x, *o, *lad, l| {
            if (!o.*) continue;
            const q = lad.next() orelse {
                o.* = false;
                if (lad.converged) done[l] = .{ .converged = true, .iterations = lad.total } else abandon(c, options, host, l);
                continue;
            };
            if (q.build_stamps) {
                // `op_ladder` reads the last assembly off the planes.
                c.evalNewton(x, 0);
                gpa.free(stamps[l]);
                stamps[l] = &.{};
                stamps[l] = try gmin_stamps.build(c, gpa);
            }
            switch (q.x_start) {
                .keep => {},
                .cold => op.coldStart(c, x),
                .good => @memcpy(x[0..n], x_good[l * n ..][0..n]),
            }
            if (q.rung != .source_off) {
                if (!try homotopyInModels(c, q.homotopy, gpa)) {
                    o.* = false;
                    abandon(c, options, host, l);
                    continue;
                }
                moved = true;
            }
            plane[l] = .{ q.gmin, q.hold_scale };
            fix[l] = q.init_fix;
            pending[l] = true;
            any = true;
        }
        if (!any) break;
        if (moved) try lanes_static.refreshModels(dev);
        try lanes_static.putX(dev, xs);
        // One round per budget and stamp table, each led by its first lane.
        var rounds: usize = 0;
        while (std.mem.indexOfScalar(bool, pending, true)) |lead| : (rounds += 1) {
            assert(rounds < N);
            const ql = ladders[lead].next().?;
            for (dev.round, pending, ladders, stamps) |*r, *p, *lad, st| {
                const q = if (p.*) lad.next().? else ql;
                const same = p.* and q.max_iter == ql.max_iter and q.stamped == ql.stamped and
                    (!q.stamped or std.mem.eql(u8, std.mem.sliceAsBytes(st), std.mem.sliceAsBytes(stamps[lead])));
                r.* = @intFromBool(same);
                if (same) p.* = false;
            }
            var copts = converger.optionsFromTolerances(options.tol, ql.max_iter);
            copts.gmin_stamps = if (ql.stamped) stamps[lead] else &.{};
            copts.force = holds;
            try lanes_static.solveStaticEach(dev, xs, copts, .{ .fix = fix, .homotopy = plane }, res);
            for (ckts, xs, dev.round, res, on, ladders, 0..) |c, x, r, o, *lo, *lad, l| {
                if (r == 0) continue;
                if (o.reject) {
                    lo.* = false;
                    abandon(c, options, host, l);
                    continue;
                }
                if (lad.feed(if (o.singular) null else o.result)) @memcpy(x_good[l * n ..][0..n], x[0..n]);
            }
        }
    }
}

/// Lane l leaves the device ladder for the host's `op.solve`, at the
/// deck's homotopy.
fn abandon(c: *root.Circuit, options: Options, host: []bool, l: usize) void {
    c.setHomotopy(options.tol.gmin, 1.0);
    host[l] = true;
}

/// `c.setHomotopy(h[0], h[1])`; false when that also rewrote an Instance
/// row (a batch whose setup caches the knobs), which a Model upload cannot
/// carry to the device.
fn homotopyInModels(c: *root.Circuit, h: [2]f64, gpa: std.mem.Allocator) !bool {
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(gpa);
    for (c.batches) |b| if (b.hooks.set_homotopy != null) {
        try before.appendSlice(gpa, b.hooks.gpu_payload.?(b.ctx).instances);
    };
    c.setHomotopy(h[0], h[1]);
    var at: usize = 0;
    for (c.batches) |b| if (b.hooks.set_homotopy != null) {
        const now = b.hooks.gpu_payload.?(b.ctx).instances;
        if (!std.mem.eql(u8, before.items[at..][0..now.len], now)) return false;
        at += now.len;
    };
    return true;
}
