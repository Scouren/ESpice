//! Tests for N6's census (`batch_census.zig`). Oracle: hand-built passes
//! whose same/changed verdicts are derived by hand.
//!
//! Contents:
//! - test "Census counts an instance as same only when every gathered unknown keeps its bits"
//! - test "Census: a limit pass counts against the last accepted point, on the unknowns limit reads"

const std = @import("std");
const Census = @import("device_eval").test_access.Census;

test "Census counts an instance as same only when every gathered unknown keeps its bits" {
    // Oracle: hand-built passes. Instance 0 reads x[0], x[1]; instance 1
    // reads x[1], x[2]. A first pass is never same; -0.0 against +0.0 is a
    // change.
    const c = Census.create(2, 2, true, false) orelse return error.OutOfMemory;
    defer c.destroy();
    const gath = [_]u32{ 0, 1, 1, 2 };
    var x = [_]f64{ 1, 2, 3 };
    c.observe(&x, &gath, 0, 2);
    c.observe(&x, &gath, 0, 2);
    x[2] = 4;
    c.observe(&x, &gath, 0, 2);
    x[0] = -0.0;
    c.observe(&x, &gath, 0, 2);
    x[0] = 0.0;
    c.observe(&x, &gath, 0, 2);
    const n = c.counts();
    // Pass 2 both same, pass 3 instance 0, pass 4 instance 1, pass 5
    // instance 1 (+0.0 after -0.0 moved x[0]).
    try std.testing.expectEqual(@as(u64, 10), n.charge_pairs);
    try std.testing.expectEqual(@as(u64, 5), n.charge_same);
    try std.testing.expectEqual(@as(u64, 0), n.limit_pairs);
}

test "Census: a limit pass counts against the last accepted point, on the unknowns limit reads" {
    // Oracle: hand-built passes. Instance 0 gathers x[0], x[1]; instance
    // 1 gathers x[1], x[2]; `limit` reads only unknown 0 of each, so
    // x[2] is no input. Before any accept nothing is same.
    const c = Census.create(2, 2, false, true) orelse return error.OutOfMemory;
    defer c.destroy();
    const gath = [_]u32{ 0, 1, 1, 2 };
    const reads = [_]bool{ true, false };
    var x = [_]f64{ 1, 2, 3 };
    c.observeLimit(&x, &gath, &reads, 0, 2); // no accept yet: 0 same
    c.accept(&x, &gath);
    x[2] = 9; // read by no limit pass
    c.observeLimit(&x, &gath, &reads, 0, 2); // both same
    x[1] = -0.0;
    c.observeLimit(&x, &gath, &reads, 0, 2); // instance 0 same
    c.observeLimit(&x, &gath, &reads, 1, 2); // range [1, 2): changed
    c.accept(&x, &gath);
    c.observeLimit(&x, &gath, &reads, 0, 2); // both same again
    const n = c.counts();
    try std.testing.expectEqual(@as(u64, 9), n.limit_pairs);
    try std.testing.expectEqual(@as(u64, 5), n.limit_same);
    try std.testing.expectEqual(@as(u64, 0), n.charge_pairs);
}
