//! A split `.dc` over a bistable circuit, where a cold start inside the
//! hysteresis band lands on the middle branch. Oracles: the serial sweep,
//! the same `.dc` with a one-point outer sweep at r1's own value, which
//! never splits (the pre-segment espice gives both forms equal raw bytes);
//! ngspice-44.2 for where the output jumps (`ngspice -n -b -r`, this deck:
//! v(out) -4.916 at vin = 2.1, +5 at 2.15). The corpus twin,
//! tests/conformance/tests/netlist/dc/hysteresis_segments_schmitt.sp,
//! checks the whole sweep against ngspice and the rerun's note.
const std = @import("std");
const decks = @import("deck.zig");
const t = std.testing;

const schmitt = "schmitt\nvin in 0 0\nr1 in p 10k\nr2 p out 20k\nb1 out 0 v=5*tanh(10*v(p))\n";

test "a split .dc whose cold segment start lands on another branch reruns whole: the serial sweep, bit for bit" {
    const split = try decks.solve(schmitt ++ ".dc vin -5 5 0.05\n.end\n");
    defer split.deinit();
    const serial = try decks.solve(schmitt ++ ".dc vin -5 5 0.05 r1 10k 10k 1\n.end\n");
    defer serial.deinit();
    // The OP, 12 segment rows, the sweep.
    try t.expectEqual(@as(u32, 1 + 12 + 1), split.query_count());
    const got = try decks.resultOf(split, .dc);
    const want = try decks.resultOf(serial, .dc);
    // The seam check refused the stitch, so the sweep ran whole.
    try t.expect(split.session.rows.items(.executor)[split.query_count() - 1].?.built);
    try t.expectEqual(@as(usize, 201), got.npoints);
    try t.expectEqualSlices(u64, @ptrCast(want.data), @ptrCast(got.data));
    try t.expect(try decks.at(got, 142, "v(out)") < -4.9);
    try t.expect(try decks.at(got, 143, "v(out)") > 4.9);
}
