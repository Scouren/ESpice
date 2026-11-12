//! `op_ladder_steps.Ladder` against `op_ladder.afterPlain`. Oracle: the
//! host ladder's own loops (`gminStepping`, `sourceStepping`, the final
//! Newton) on a twin circuit, bitwise on the result, the iteration total
//! (the sum over every rung's Newton) and the published x. The driver below
//! only applies each request with `converger.run`, as the GPU lanes'
//! driver applies it with a device Newton.
const std = @import("std");
const analysis = @import("../types.zig");
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const eval = @import("device_eval");
const converger = @import("solver").converger;
const Crawl = @import("crawl_device");
const models = @import("models");
const op = @import("../dc/op.zig");
const op_ladder = @import("../dc/op_ladder.zig");
const steps_mod = @import("../dc/op_ladder_steps.zig");
const gmin_stamps = @import("../dc/gmin_stamps.zig");
const t = std.testing;
const GROUND = analysis.GROUND;
const Rung = steps_mod.Rung;

// ---- private ----

/// Two instances of `prepared`: one through `op_ladder`, one through the
/// machine, from the same plain rung (run, or `plain` as given). Returns
/// the rungs the machine visited.
fn expectTwins(prepared: anytype, plain: ?converger.Result) !std.EnumSet(Rung) {
    var host = try analysis.Circuit.instantiate(prepared, t.allocator);
    defer host.deinit();
    var mach = try analysis.Circuit.instantiate(prepared, t.allocator);
    defer mach.deinit();
    const xh = try t.allocator.alloc(f64, host.n);
    defer t.allocator.free(xh);
    const xm = try t.allocator.alloc(f64, mach.n);
    defer t.allocator.free(xm);
    const options: op.Options = .{};
    try op.beginSolve(&host, xh, options);
    try op.beginSolve(&mach, xm, options);
    const wh = try host.workspace();
    const wm = try mach.workspace();
    // A skipped plain rung leaves no assembly for the gmin stamps; both
    // read one at the start, as `op_lanes` evaluates before `afterPlain`.
    if (plain != null) {
        host.evalNewton(xh, 0);
        mach.evalNewton(xm, 0);
    }
    const want = if (plain) |p|
        try op_ladder.afterPlain(&host, wh, xh, options, &.{}, p)
    else
        try op_ladder.solve(&host, wh, xh, options, &.{});
    const start = plain orelse plainRung(&mach, wm, xm, options);
    var seen: std.EnumSet(Rung) = .empty;
    const got = try drive(&mach, wm, xm, options, &.{}, start, &seen);
    try t.expectEqual(want.converged, got.converged);
    try t.expectEqual(want.iterations, got.iterations);
    try t.expectEqualSlices(f64, xh, xm);
    try t.expect(want.converged);
    return seen;
}

/// `op_ladder.solve`'s rung 1.
fn plainRung(ckt: *analysis.Circuit, ws: *converger.Workspace, x: []f64, options: op.Options) ?converger.Result {
    var copts = converger.optionsFromTolerances(options.tol, null);
    copts.gmin = 0;
    copts.init_fix = !options.warm_start;
    return converger.run(ckt, ws, x, 0, copts, analysis.EvalHook{}) catch null;
}

/// Every request of a `Ladder` from `plain`, applied with `converger.run`
/// on `ckt`; the rungs met land in `seen`.
fn drive(ckt: *analysis.Circuit, ws: *converger.Workspace, x: []f64, options: op.Options, hold: []const converger.Force, plain: ?converger.Result, seen: *std.EnumSet(Rung)) !converger.Result {
    const gpa = t.allocator;
    const steps = try gpa.alloc(op_ladder.GminStep, op_ladder.ladder_solves_max);
    defer gpa.free(steps);
    const x_good = try gpa.alloc(f64, x.len);
    defer gpa.free(x_good);
    const scaled = try gpa.dupe(converger.Force, hold);
    defer gpa.free(scaled);
    var stamps: []converger.GminStamp = &.{};
    defer gpa.free(stamps);
    var lad = steps_mod.Ladder.init(options.tol, steps, plain);
    while (lad.next()) |q| {
        seen.insert(q.rung);
        if (q.build_stamps) {
            gpa.free(stamps);
            stamps = &.{};
            stamps = try gmin_stamps.build(ckt, gpa);
        }
        switch (q.x_start) {
            .keep => {},
            .cold => op.coldStart(ckt, x),
            .good => @memcpy(x, x_good),
        }
        if (q.rung != .source_off) {
            ckt.setHomotopy(q.homotopy[0], q.homotopy[1]);
            if (q.rebuild) try ckt.rebuildBaseline() else try ckt.computeBaseline();
        }
        for (scaled, hold) |*s, h| s.value = h.value * q.hold_scale;
        var copts = converger.optionsFromTolerances(options.tol, q.max_iter);
        copts.gmin = q.gmin;
        copts.gmin_stamps = if (q.stamped) stamps else &.{};
        copts.init_fix = q.init_fix;
        copts.force = scaled;
        const r: ?converger.Result = converger.run(ckt, ws, x, 0, copts, analysis.EvalHook{}) catch |e| switch (e) {
            error.SingularMatrix => null,
            error.QueryCancelled, error.OutOfMemory => return e,
            else => if (q.lenient) null else return e,
        };
        if (lad.feed(r)) @memcpy(x_good, x);
    }
    return .{ .converged = lad.converged, .iterations = lad.total };
}

test "op ladder steps: a gmin descent that stalls into source stepping is op_ladder's, bitwise" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const out = try b.addNode();
    const vt = eval.deviceVtable(Crawl, "va_gmin_crawl");
    const proto = try b.protoOf(try lib.register("va_gmin_crawl", vt, false));
    const model: Crawl.Model = .{};
    const instance: Crawl.Instance = .{};
    const nodes = [_]u32{ out, GROUND };
    try vt.proto_add(proto.ctx, t.allocator, @ptrCast(&model), @ptrCast(&instance), &nodes).unwrap();
    var prepared = try b.compile();
    defer prepared.deinit();
    // #218's descent: the plain rung fails, gmin stalls, sources finish.
    const seen = try expectTwins(&prepared, null);
    try t.expect(seen.contains(.gmin) and seen.contains(.source) and seen.contains(.final));
}

test "op ladder steps: a gmin descent to the deck's gmin and its clean solve is op_ladder's, bitwise" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 5 }, &.{}, .{ vin, GROUND });
    var prev: u32 = vin;
    for (0..20) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 100 }, &.{}, .{ prev, mid });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    // The plain rung is skipped as if it had failed, so the descent runs
    // on a circuit it converges on all the way.
    const seen = try expectTwins(&prepared, .{ .converged = false, .iterations = 0 });
    try t.expect(seen.contains(.gmin) and seen.contains(.clean) and !seen.contains(.source));
}
