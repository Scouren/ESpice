//! `uic` and OPtran under device step control: the lane step machine's
//! breakpoint answer (`lane_kernels.stepEndB`) adds `Sim.uic_bp` as
//! `Sim.nextBp` adds its `extra`, and its attempt (`stepBegin`) evaluates
//! at t = 0 under `sources_at_zero` as `Sim.begin` does.
//! Oracles: `Sim`'s first accepted step under uic, on the host (`Sim.begin`,
//! `converger.run`, `Sim.end`), whose next breakpoint is `uic_bp`; and the
//! host OPtran start (`Sim.begin` of `op_ladder.transientOp`'s options):
//! the `SimState` it publishes and its `t_dev`.
//!
//! Contents: none (two tests).

const std = @import("std");
const converger = @import("solver").converger;
const lk = @import("solver").lane_kernels;
const root = @import("../types.zig");
const Sim = @import("Sim.zig");
const gpu_step = @import("gpu_step.zig");
const HostOps = @import("host_ops.zig").HostOps;
const Waveform = @import("types.zig").Waveform;

test "uic on device step control: the first step's next breakpoint is Sim's, uic_bp included" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const inf = std.math.inf(f64);
    var lib = try @import("device").Library.init(gpa);
    defer lib.deinit();
    var b = try @import("builder").Builder.init(gpa, &lib);
    const node = try b.addNode();
    try b.addDevice(@import("models").vsource, "", &.{ .dc = 1 }, &.{}, .{ node, root.GROUND });
    try b.addDevice(@import("models").capacitor, "", &.{ .c = 1e-12 }, &.{}, .{ node, root.GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try root.Circuit.instantiate(&prepared, gpa);
    defer ckt.deinit();
    const x = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x);
    @memset(x, 0);
    var wf = try Waveform.init(gpa, 1, 32);
    defer wf.deinit();
    var s: Sim = undefined;
    try s.init(&ckt, x, &.{node}, &wf, .{ .t_stop = 2e-12, .dt_init = 2e-14, .dt_max = 2e-14, .dt_min = 1e-18, .uic = true }, gpa, null, null);
    defer s.deinit();
    // The lane step as the device takes it over, before the first step.
    var st = gpu_step.laneStep(&s, s.options, 100);
    try testing.expectEqual(s.uic_bp.?, st.uic_bp);

    const first = (try s.begin(HostOps{})).?;
    const nr = try converger.run(&ckt, s.ws, s.trial, first.t_dev, first.nr_opts, first.hook);
    try testing.expect(nr.converged);
    try testing.expectEqual(Sim.Verdict.go, try s.end(&first, nr, HostOps{}));
    // The first step (dt_init / 100) ends short of uic_bp, and a DC source
    // has no breakpoint: the host's next breakpoint is uic_bp itself.
    try testing.expect(s.t < s.uic_bp.?);
    try testing.expectEqual(s.uic_bp, s.bp_next);

    // The device's answer at the same accepted point: the sources' part
    // (the breakpoint kernels' `best`) is `nextBp` without the extra.
    const src = Sim.nextBp(&ckt, &.{}, null, s.t + s.min_break) orelse inf;
    st.t_new = s.t;
    st.dt_next = s.dt;
    st.event = lk.step_accept;
    var plain = st;
    lk.stepEndB(&st, src);
    try testing.expectEqual(@as(u64, @bitCast(s.bp_next.?)), @as(u64, @bitCast(st.bp_next)));
    // uic_bp absent (inf): the answer is the sources' alone.
    plain.uic_bp = inf;
    lk.stepEndB(&plain, src);
    try testing.expectEqual(@as(u64, @bitCast(src)), @as(u64, @bitCast(plain.bp_next)));
}

test "OPtran on device step control: every attempt evaluates at t = 0 as Sim.begin's, bitwise" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var lib = try @import("device").Library.init(gpa);
    defer lib.deinit();
    var b = try @import("builder").Builder.init(gpa, &lib);
    const node = try b.addNode();
    try b.addDevice(@import("models").vsource, "", &.{ .dc = 1 }, &.{}, .{ node, root.GROUND });
    try b.addDevice(@import("models").capacitor, "", &.{ .c = 1e-12 }, &.{}, .{ node, root.GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try root.Circuit.instantiate(&prepared, gpa);
    defer ckt.deinit();
    const x = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x);
    @memset(x, 0);
    var wf = try Waveform.init(gpa, 1, 32);
    defer wf.deinit();
    for ([_]bool{ true, false }) |at_zero| {
        var s: Sim = undefined;
        // `op_ladder.transientOp`'s run; the plain run is the control.
        try s.init(&ckt, x, &.{node}, &wf, .{ .t_stop = 1e-6, .dt_init = 1e-8, .dt_max = 1e-8, .uic = true, .sources_at_zero = at_zero }, gpa, null, null);
        defer s.deinit();
        var st = gpu_step.laneStep(&s, s.options, 100);
        try testing.expectEqual(@as(u8, @intFromBool(at_zero)), st.sources_at_zero);
        var sc: lk.LaneScalars = undefined;
        var sim: lk.SimState = undefined;
        var lin: lk.LteIn = undefined;
        try testing.expect(lk.stepBegin(&st, &sc, &sim, &lin));
        const first = (try s.begin(HostOps{})).?;
        try testing.expectEqual(@as(u64, @bitCast(first.t_dev)), @as(u64, @bitCast(sc.t_dev)));
        try testing.expectEqual(@as(u64, @bitCast(ckt.sim.t)), @as(u64, @bitCast(sim.t)));
        try testing.expectEqual(@as(u64, @bitCast(ckt.sim.dt)), @as(u64, @bitCast(sim.dt)));
        // The step itself still advances: only the evaluation time is held.
        try testing.expect(s.t + s.dt > 0);
        try testing.expectEqual(at_zero, sim.t == 0);
    }
}
