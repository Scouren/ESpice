//! A single-axis `.dc` the session ran as segments (`Dc.segments`), each
//! its own row from its own cold operating point, stitched back into the
//! sweep's table. ngspice's dctrcurv.c continues every point from the last,
//! so where a circuit has two solutions the path picks the branch: each
//! segment past the first also solves the previous one's last point cold
//! (its overlap), and the stitch takes the segments only where that point's
//! two solutions are one by the Newton acceptance test, at twice its
//! tolerance for two independent convergences. A seam that is not sends
//! the sweep back to run whole (`Session.assemble`): a curve is never
//! stitched across two branches.
//! In: the segments' tables and seam solutions. Out: the sweep's table, or
//! the seam that disagrees.
//! Cites ngspice dctrcurv.c (continuation; steps accumulated at :469) and
//! niconv.c (the acceptance test).
//!
//! Contents:
//! - `pub fn agree(a: []const f64, b: []const f64, current_row: []const bool, tol: Tolerances, scratch: []f64) bool`
//! - `pub fn stitch(out: []f64, parts: []const []const f64, seams: []const []const f64, ncols: usize, opts: Options, current_row: []const bool, scratch: []f64) ?u32`
//! - `pub fn note(names: CardNames, opts: Options, seam: u32, at: f64) void`

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const converger = @import("solver").converger;
const Options = core.query.Dc;
const CardNames = core.query.CardNames;
const Tolerances = @FieldType(Options, "tol");

/// Whether `a` and `b`, two converged solutions of one point, are one
/// solution: the Newton acceptance test (`converger.updateAndNorm`:
/// |b - a| against reltol·max(|a|, |b|) plus abstol on a current row,
/// vntol on any other) at twice its tolerance, one share for each
/// convergence. A NaN or infinity anywhere disagrees. `scratch` holds 3n
/// values. Asserts that the slices match.
pub fn agree(a: []const f64, b: []const f64, current_row: []const bool, tol: Tolerances, scratch: []f64) bool {
    const n = a.len;
    assert(b.len == n);
    assert(current_row.len >= n);
    assert(scratch.len >= 3 * n);
    const x = scratch[0..n];
    const dx = scratch[n..][0..n];
    const old = scratch[2 * n ..][0..n];
    @memcpy(x, a);
    for (dx, a, b) |*d, p, q| d.* = q - p;
    // The solver accepts a score below 1 (`converger.finalizeStep`).
    return converger.updateAndNorm(1, x, dx, old, current_row, tol.reltol, tol.abstol, tol.vntol, true) < 2;
}

/// Writes the sweep's table to `out`: segment s's rows (`parts[s]`,
/// `ncols` values each, as `opts.segment(s)` solved them) in order, each
/// overlap row dropped, once every seam agrees (`agree` on segment s-1's
/// last solution and segment s's first: `seams[s]` holds a segment's
/// first then last full solution, `2n` values). Returns null then, else
/// the first seam s that disagrees, with `out` unwritten. Asserts the
/// shapes, and that each segment's first own row holds the sweep value the
/// whole sweep's accumulated steps reach there.
pub fn stitch(out: []f64, parts: []const []const f64, seams: []const []const f64, ncols: usize, opts: Options, current_row: []const bool, scratch: []f64) ?u32 {
    const k = opts.segments();
    assert(opts.lane == null);
    assert(k >= 2 and parts.len == k and seams.len == k);
    const n = seams[0].len / 2;
    for (seams) |s| assert(s.len == 2 * n);
    for (1..k) |s| if (!agree(seams[s - 1][n..], seams[s][0..n], current_row, opts.tol, scratch)) return @intCast(s);
    var v = opts.start;
    var point: usize = 0;
    var at: usize = 0;
    for (parts, 0..) |part, s| {
        const seg = opts.segment(@intCast(s));
        assert(part.len == seg.len * ncols);
        const skip: usize = @intFromBool(s != 0);
        const own = seg.first + skip;
        // `+=` from `start`, as dctrcurv.c:469 and `Sweep.beginPoint` step.
        while (point < own) : (point += 1) v += opts.step;
        const want = if (opts.points.len > 0) opts.points[own] else v;
        assert(part[skip * ncols] == want);
        const rows = part[skip * ncols ..];
        @memcpy(out[at..][0..rows.len], rows);
        at += rows.len;
    }
    assert(at == out.len);
    return null;
}

/// Prints why the session reruns `opts` whole: at seam `seam` of its
/// segments, sweep value `at`, the cold start and the continued sweep
/// reached two solutions.
pub fn note(names: CardNames, opts: Options, seam: u32, at: f64) void {
    const name = switch (opts.target) {
        .temp => "temp",
        .device => |d| names.get(d.type, d.index) orelse d.param_name,
    };
    var buf: [160]u8 = undefined;
    const sweep = (if (opts.points.len > 0)
        std.fmt.bufPrint(&buf, "{s} ({d} listed points)", .{ name, opts.points.len })
    else
        std.fmt.bufPrint(&buf, "{s} {d} {d} {d}", .{ name, opts.start, opts.stop, opts.step })) catch name;
    std.debug.print("note: .dc {s} reruns whole: at seam {d} of {d} ({d:.6}) a cold start lands on another solution than the continued sweep\n", .{ sweep, seam, opts.segments() - 1, at });
}

test "a sweep splits by its points alone: every point owned once, each overlap the previous segment's last" {
    const t = std.testing;
    // Oracle: the rule written out: n / 16 segments, at most 64, one row
    // below 2; segment s owns floor(s n / k) up to floor((s + 1) n / k).
    const Case = struct { opts: Options, k: u32 };
    const list: [40]f64 = @splat(0);
    const cases = [_]Case{
        .{ .opts = .{ .start = 0, .stop = 30, .step = 1 }, .k = 0 }, // 31 points
        .{ .opts = .{ .start = 0, .stop = 31, .step = 1 }, .k = 2 },
        .{ .opts = .{ .start = -5, .stop = 5, .step = 0.05 }, .k = 12 }, // 201 points
        .{ .opts = .{ .start = 5, .stop = -5, .step = -0.05 }, .k = 12 },
        .{ .opts = .{ .start = 0, .stop = 1e6, .step = 1 }, .k = 64 },
        .{ .opts = .{ .points = &list }, .k = 2 },
        // An outer sweep, tangent rows and `emir` stay one row; so does a
        // span validation refuses.
        .{ .opts = .{ .start = 0, .stop = 99, .step = 1, .target2 = .temp }, .k = 0 },
        .{ .opts = .{ .start = 0, .stop = 99, .step = 1, .tangents = &.{0} }, .k = 0 },
        .{ .opts = .{ .start = 0, .stop = 99, .step = 1, .emir = true }, .k = 0 },
        .{ .opts = .{ .start = 0, .stop = 99, .step = 0 }, .k = 0 },
        .{ .opts = .{ .start = 0, .stop = 99, .step = -1 }, .k = 0 },
        .{ .opts = .{ .start = 0, .stop = std.math.nan(f64), .step = 1 }, .k = 0 },
        .{ .opts = .{ .start = 0, .stop = 1e300, .step = 1 }, .k = 0 },
    };
    for (cases) |c| {
        try t.expectEqual(c.k, c.opts.segments());
        if (c.k == 0) continue;
        const n: usize = if (c.opts.points.len > 0) c.opts.points.len else @intFromFloat(@round((c.opts.stop - c.opts.start) / c.opts.step) + 1);
        var next: usize = 0;
        for (0..c.k) |s| {
            const seg = c.opts.segment(@intCast(s));
            // Segment s > 0 starts at segment s-1's last point.
            try t.expectEqual(if (s == 0) next else next - 1, seg.first);
            try t.expectEqual(s * n / c.k, next);
            try t.expect(seg.first + seg.len - next >= Options.split.points);
            next = seg.first + seg.len;
        }
        try t.expectEqual(n, next);
    }
}

test "agree is the Newton acceptance test at twice its tolerance" {
    const t = std.testing;
    // Oracle: niconv.c's test by hand, at reltol 1e-3, vntol 1e-6 V and
    // abstol 1e-12 A: |b - a| < 2 (reltol max(|a|, |b|) + vntol), abstol
    // on the current row.
    const tol: Tolerances = .{};
    const rows = [_]bool{ false, true };
    var scratch: [6]f64 = undefined;
    // Node at 1 V: 2 (1e-3 · 1.0019 + 1e-6) = 2.0058e-3 V.
    try t.expect(agree(&.{ 1, 1e-3 }, &.{ 1.0019, 1e-3 }, &rows, tol, &scratch));
    try t.expect(!agree(&.{ 1, 1e-3 }, &.{ 1.0021, 1e-3 }, &rows, tol, &scratch));
    // Current row at 1 mA: 2 (1e-3 · 1.0019e-3 + 1e-12) = 2.0038e-6 A.
    try t.expect(agree(&.{ 1, 1e-3 }, &.{ 1, 1e-3 + 1.9e-6 }, &rows, tol, &scratch));
    try t.expect(!agree(&.{ 1, 1e-3 }, &.{ 1, 1e-3 + 2.1e-6 }, &rows, tol, &scratch));
    // Near zero, vntol on a node row and abstol on a current row.
    try t.expect(agree(&.{ 0, 0 }, &.{ 1.9e-6, 0 }, &rows, tol, &scratch));
    try t.expect(!agree(&.{ 0, 0 }, &.{ 0, 1.9e-6 }, &rows, tol, &scratch));
    // A point that did not converge (NaN) never agrees.
    const nan = std.math.nan(f64);
    try t.expect(!agree(&.{ nan, 0 }, &.{ nan, 0 }, &rows, tol, &scratch));
}

test "stitch joins the segments into the whole sweep without their overlap rows, or names the first seam that disagrees" {
    const t = std.testing;
    // Oracle: the whole sweep's table, one row per point with the axis
    // stepped `+=` from start (the serial sweep's), and each segment's
    // rows and seam solutions cut from it as `segment` lays them out.
    const opts: Options = .{ .start = -1, .stop = 1, .step = 0.05 };
    const k = opts.segments();
    try t.expectEqual(@as(u32, 2), k);
    const n_points = 41;
    const ncols = 2;
    var whole: [n_points * ncols]f64 = undefined;
    var x: [n_points * 2]f64 = undefined;
    var v = opts.start;
    for (0..n_points) |p| {
        if (p != 0) v += opts.step;
        const f: f64 = @floatFromInt(p);
        whole[p * ncols ..][0..ncols].* = .{ v, f * f };
        x[p * 2 ..][0..2].* = .{ f, 2 * f };
    }
    var parts: [2][]const f64 = undefined;
    var seam_bufs: [2][4]f64 = undefined;
    var seams: [2][]const f64 = undefined;
    for (0..k) |s| {
        const seg = opts.segment(@intCast(s));
        parts[s] = whole[seg.first * ncols ..][0 .. seg.len * ncols];
        const last = seg.first + seg.len - 1;
        seam_bufs[s] = .{ x[seg.first * 2], x[seg.first * 2 + 1], x[last * 2], x[last * 2 + 1] };
        seams[s] = &seam_bufs[s];
    }
    const current_row = [_]bool{ false, true };
    var scratch: [6]f64 = undefined;
    var out: [n_points * ncols]f64 = undefined;
    try t.expectEqual(null, stitch(&out, &parts, &seams, ncols, opts, &current_row, &scratch));
    try t.expectEqualSlices(u64, @ptrCast(&whole), @ptrCast(&out));
    // Segment 1's cold start on another solution: seam 1 disagrees.
    seam_bufs[1][0] += 1;
    try t.expectEqual(@as(?u32, 1), stitch(&out, &parts, &seams, ncols, opts, &current_row, &scratch));
}
