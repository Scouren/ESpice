//! A split `.dc` against the serial sweep: the same `.dc` with a one-point
//! outer sweep at an element's own value, which never splits (the
//! pre-segment espice gives both forms equal raw bytes). Over a bistable
//! circuit, where a cold start inside the hysteresis band lands on the
//! middle branch, with ngspice-44.2 for where the output jumps (`ngspice -n
//! -b -r`, this deck: v(out) -4.916 at vin = 2.1, +5 at 2.15); its corpus
//! twin, tests/conformance/tests/netlist/dc/hysteresis_segments_schmitt.sp,
//! checks the whole sweep against ngspice and the rerun's note. And over a
//! diode, where a segment's first own point must start from the serial
//! sweep's two-point predictor.
const std = @import("std");
const decks = @import("deck.zig");
const t = std.testing;

const schmitt = "schmitt\nvin in 0 0\nr1 in p 10k\nr2 p out 20k\nb1 out 0 v=5*tanh(10*v(p))\n";
const diode = "diode predictor\nv1 a 0 dc 0.6\nvm a k 0\nd1 k 0 dm\n.model dm d is=1e-14 n=1 cjo=1p tt=1n\n.save i(vm)\n";

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

test "a split .dc's first own points start from two points, as the serial sweep's: an ammeter on the exponential within 1e-12 of it" {
    // Oracle: the serial sweep (outer sweep at vm's own 0 V). Every node
    // voltage is a source's, so a two-point predictor is the swept value to
    // rounding, and at reltol 1e-3 the ammeter reads the diode current
    // linearized at the predictor (opvars.zig's header): predicted from one
    // point, (0.2 mV / vt)^2 / 2 = 3e-5 low. Bound: a voltage a few ulps of
    // 0.6 V off, each 4.3e-15 of the current. Measured on the prebuilt
    // espice of 2026-11-11, which never splits, with a segment emulated as a
    // .dc started at its cold point: 2.97e-5 at the first own point with
    // one overlap point, at most 1.44e-14 with two (that axis typed, 4e-16 V
    // off the accumulated one). Red before (`Dc.overlap = 1`): i(vm) 2.97e-5
    // low at points 16, 33, 50, 67 and 84.
    const split = try decks.solve(diode ++ ".dc v1 0.59 0.61 0.0002\n.end\n");
    defer split.deinit();
    const serial = try decks.solve(diode ++ ".dc v1 0.59 0.61 0.0002 vm 0 0 1\n.end\n");
    defer serial.deinit();
    // The OP, 6 segment rows, the sweep, stitched.
    try t.expectEqual(@as(u32, 1 + 6 + 1), split.query_count());
    try t.expect(!split.session.rows.items(.executor)[split.query_count() - 1].?.built);
    const got = try decks.resultOf(split, .dc);
    const want = try decks.resultOf(serial, .dc);
    try t.expectEqual(@as(usize, 101), got.npoints);
    for (0..got.npoints) |k| try t.expectApproxEqRel(try decks.at(want, k, "i(vm)"), try decks.at(got, k, "i(vm)"), 1e-12);
}
