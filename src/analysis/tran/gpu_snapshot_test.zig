//! A `.op <time>` snapshot on the transient lanes: the lanes bring back
//! only each accepted row's probe positions, and `GpuLane.keepRow` puts
//! them where `Sim.finish` and `Run.take` read the snapshot (x at
//! `ctx.probes`, which a snapshot run records whole).
//! Oracle: the host run's snapshot, `Sim` stepped to t_stop on the host
//! (`begin`, `converger.run`, `end`, `finish`).
//!
//! Contents: none (one test).

const std = @import("std");
const converger = @import("solver").converger;
const root = @import("../types.zig");
const Sim = @import("Sim.zig");
const gpu_step = @import("gpu_step.zig");
const HostOps = @import("host_ops.zig").HostOps;
const Waveform = @import("types.zig").Waveform;

test "snapshot on lanes: the last accepted row's probes are the host run's snapshot, bitwise" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const models = @import("models");
    var lib = try @import("device").Library.init(gpa);
    defer lib.deinit();
    var b = try @import("builder").Builder.init(gpa, &lib);
    const vin = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ vin, root.GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ vin, out });
    try b.addDevice(models.capacitor, "", &.{ .c = 1e-12 }, &.{}, .{ out, root.GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try root.Circuit.instantiate(&prepared, gpa);
    defer ckt.deinit();
    const probes = [_]u32{ vin, out };
    const opts: @FieldType(Sim, "options") = .{ .t_stop = 1e-9, .dt_init = 1e-11, .dt_max = 5e-11, .dt_min = 1e-18, .snapshot = true };

    // The host run: its x after `finish` is what `Run.take` publishes.
    const x_host = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x_host);
    @memset(x_host, 0);
    {
        var wf = try Waveform.init(gpa, probes.len, 64);
        defer wf.deinit();
        var s: Sim = undefined;
        try s.init(&ckt, x_host, &probes, &wf, opts, gpa, null, null);
        defer s.deinit();
        var bound: usize = 0;
        while (try s.begin(HostOps{})) |att| : (bound += 1) {
            try testing.expect(bound < 10_000);
            const nr = try converger.run(&ckt, s.ws, s.trial, att.t_dev, att.nr_opts, att.hook);
            switch (try s.end(&att, nr, HostOps{})) {
                .go => {},
                .stop => break,
                .underflow => return error.TestUnexpectedResult,
            }
        }
        try testing.expect(try s.finish());
    }
    try testing.expect(x_host[out] > 0.5 and x_host[out] <= 1);

    // A lane: its host `cur` is stale (NaN here), and the drain hands it
    // the last accepted row as `slotRow` leaves it, n long with only the
    // probe positions filled.
    const x_lane = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x_lane);
    @memset(x_lane, 0);
    var wf = try Waveform.init(gpa, probes.len, 64);
    defer wf.deinit();
    var s: Sim = undefined;
    try s.init(&ckt, x_lane, &probes, &wf, opts, gpa, null, null);
    defer s.deinit();
    @memset(s.cur, std.math.nan(f64));
    const row = try gpa.alloc(f64, ckt.n);
    defer gpa.free(row);
    @memset(row, std.math.nan(f64));
    for (probes) |p| row[p] = x_host[p];
    gpu_step.GpuLane.keepRow(&s, row);
    _ = try s.finish();
    for (probes) |p| try testing.expectEqual(@as(u64, @bitCast(x_host[p])), @as(u64, @bitCast(x_lane[p])));
}
