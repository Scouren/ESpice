//! A long single-axis `.dc` runs as segment rows (`Dc.segments`) the
//! session stitches back. Oracles: the serial sweep, the same `.dc` with a
//! one-point outer sweep at a resistor's own value, which never splits and
//! publishes the sweep run whole bit for bit (the pre-segment espice gives
//! the two forms equal raw bytes); twice the Newton acceptance tolerance
//! between the two, the seam test's own bound, since each segment starts
//! cold; and the segmented run itself, bitwise at lanes off and on and at
//! --jobs 1 and 3.

const std = @import("std");
const t = std.testing;
const requests = @import("core").query;
const builtin = @import("device").Library.builtin;
const Library = @import("device").Library;
const Builder = @import("builder").Builder;
const models = @import("models");
const Session = @import("../session.zig").Session;
const GROUND = @import("../types.zig").GROUND;
const helpers = @import("session.zig");

test "a long .dc runs as segment rows that stitch alike at lanes off and on and any --jobs, within twice the Newton tolerance of the serial sweep" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 3 }, &.{}, .{ vin, GROUND });
    var prev = vin;
    for (0..4) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    var deck = helpers.bareDeck(&.{ vin, prev }, &.{ "v(in)", "v(out)" });
    deck.cards = &.{ .{ .type = builtin("vsource"), .index = 0, .name = "v1" }, .{ .type = builtin("resistor"), .index = 0, .name = "r1" } };
    // 201 points: 12 segments of 16 or 17.
    const split: requests.Dc = .{ .target = .{ .device = .{ .type = builtin("vsource") } }, .start = -1, .stop = 3, .step = 0.02 };
    try t.expectEqual(@as(u32, 12), split.segments());
    var serial = split;
    serial.target2 = .{ .device = .{ .type = builtin("resistor"), .index = 0, .param_name = "r" } };
    serial.start2 = 1e3;
    serial.stop2 = 1e3;
    const jobs = [_]requests.Query{ .{ .dc = split }, .{ .dc = serial } };

    const Run = struct { lanes: bool, jobs: u16 };
    const runs = [_]Run{ .{ .lanes = false, .jobs = 1 }, .{ .lanes = true, .jobs = 1 }, .{ .lanes = true, .jobs = 3 }, .{ .lanes = false, .jobs = 3 } };
    var out: [runs.len][jobs.len][]f64 = undefined;
    var batched: usize = 0;
    for (runs, &out) |r, *o| {
        var s = Session.init(t.allocator, t.io, &prepared, &deck, helpers.laneConfig(r.lanes));
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        // One shared OP, 12 segment rows, the split sweep, the serial one.
        try t.expectEqual(@as(u32, 1 + 12 + 1 + 1), s.count());
        try s.runAll(.{ .max_parallel = r.jobs, .quantum = .completion });
        try t.expectEqual(null, s.failure());
        // Every seam agreed: the split sweep never ran whole.
        try t.expect(!s.rows.items(.executor)[@backingInt(ids[0])].?.built);
        for (s.rows.items(.executor), s.rows.items(.job)) |e, j| {
            if (r.lanes and s.jobs.items[j] == .dc) batched += e.?.peers.len;
        }
        for (ids, o) |id, *d| d.* = try t.allocator.dupe(f64, (try s.result(id)).data);
    }
    defer for (out) |o| for (o) |d| t.allocator.free(d);
    try t.expect(batched > 0);
    for (out[1..]) |o| for (out[0], o) |want, got| try t.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));

    const got = out[0][0];
    const want = out[0][1];
    try t.expectEqual(want.len, got.len);
    try t.expectEqual(@as(usize, 201 * 3), got.len);
    const tol = split.tol;
    for (0..201) |p| {
        // The sweep values are the serial sweep's accumulated steps, bit for bit.
        try t.expectEqual(want[3 * p], got[3 * p]);
        for (want[3 * p + 1 ..][0..2], got[3 * p + 1 ..][0..2]) |a, c| {
            const bound = 2 * (tol.reltol * @max(@abs(a), @abs(c)) + tol.vntol);
            if (!(@abs(a - c) < bound)) {
                std.debug.print("point {d}: segmented {e}, serial {e}\n", .{ p, c, a });
                return error.TestExpectedApproxEqAbs;
            }
        }
    }
}
