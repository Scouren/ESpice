//! A portnum V's output names: its z0 is a resistor in the circuit, in
//! series with the ideal source through an internal node, and ESPice
//! publishes that node and that resistor as ngspice publishes its vsrc's.
//! Oracles: ngspice-44.2's vector lists for these decks (`ngspice -b -r`,
//! measured 2026-11-11), and the closed form of 1 V behind z0 = 50 into
//! R1 = 50: v(a) = R1 / (R1 + z0) = 0.5, dv(a)/dR1 = z0 / (R1 + z0)^2 =
//! 5e-3. ngspice 44.2 aborts `.sens` on a portnum deck ("Internal Error:
//! node allocation in DEVsetup() during sensitivity analysis"), so the
//! sens rows rest on the closed form alone.
//! Red before (the tree of 2026-11-11 without the hunks in net_card.zig,
//! noise_columns.zig and sens.zig): the `.op` had no `v(v1#res)`, `.noise
//! ... 1` added `onoise_resistor#0_thermal` and `onoise_resistor#0`, and
//! `.sens` added `v(resistor#0)` and the z0 resistor's other parameters.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

// ---- private ----

/// Expects `got` to hold exactly the names in `want`, in any order; sorts
/// `want` in place.
fn expectSameNames(want: [][]const u8, got: []const []const u8) !void {
    const sorted = try t.allocator.dupe([]const u8, got);
    defer t.allocator.free(sorted);
    const lt = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f;
    std.mem.sort([]const u8, sorted, {}, lt);
    std.mem.sort([]const u8, want, {}, lt);
    errdefer for (sorted) |n| std.debug.print("got {s}\n", .{n});
    try t.expectEqual(want.len, sorted.len);
    for (want, sorted) |w, g| try t.expectEqualStrings(w, g);
}

test "a portnum V's internal node publishes as ngspice's v(<source>#res), and nothing else is added" {
    const p = try decks.solve("ports\nv1 a 0 dc 1 portnum 1 z0 50\nr1 a 0 50\n" ++
        "v2 b 0 pulse(0 1 0 1p 1p 1 2) portnum 2 z0 1k\nc2 b 0 1n\n.op\n.end\n");
    defer p.deinit();
    const r = try decks.resultOf(p, .op);
    // ngspice-44.2's `.op` vectors for this deck; ESPice lists branch
    // currents first, so the lists are compared sorted.
    var want = [_][]const u8{ "v(a)", "v(b)", "i(v2)", "v(v2#res)", "i(v1)", "v(v1#res)" };
    try expectSameNames(&want, r.varnames);
    try t.expectEqual(@as(f64, 1), try decks.at(r, 0, "v(v1#res)"));
    try t.expectApproxEqRel(@as(f64, 0.5), try decks.at(r, 0, "v(a)"), 1e-12);
}

test "a portnum V's z0 adds no .noise contribution row, as ngspice's vsrc has none" {
    const p = try decks.solve("ports\nv1 a 0 dc 0 ac 1 portnum 1 z0 50\nr1 a 0 50\n.noise v(a) v1 dec 1 1k 100k 1\n.end\n");
    defer p.deinit();
    // ngspice-44.2's lists without its `r1_1overf` columns: ESPice's
    // resistor has no flicker generator (models/resistor.va).
    var spectrum = [_][]const u8{ "frequency", "onoise_r1_thermal", "onoise_r1", "onoise_spectrum", "inoise_spectrum" };
    var totals = [_][]const u8{ "v(onoise_total_r1_thermal)", "v(inoise_total_r1_thermal)", "v(onoise_total_r1)", "v(inoise_total_r1)", "v(onoise_total)", "v(inoise_total)" };
    var seen: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if ((try p.query_info(id)).kind != .noise) continue;
        const r = try p.result(id);
        seen += 1;
        if (r.npoints == 1) {
            try expectSameNames(&totals, r.varnames);
            continue;
        }
        try expectSameNames(&spectrum, r.varnames);
        // R1 is the only noisy element: its column is the whole spectrum,
        // ngspice-44.2's 4.5519317507954793e-10 V/sqrt(Hz) at every point
        // (noise/source_portnum_z0), sqrt(4 k T R1) * z0 / (R1 + z0).
        for (0..r.npoints) |k| {
            try t.expectApproxEqRel(try decks.at(r, k, "onoise_spectrum"), try decks.at(r, k, "onoise_r1"), 1e-12);
            try t.expectApproxEqRel(@as(f64, 4.5519317507954793e-10), try decks.at(r, k, "onoise_r1"), 1e-6);
        }
    }
    try t.expectEqual(@as(usize, 2), seen);
}

test "a portnum V's z0 adds no .sens row, and the rows left keep their closed forms" {
    const p = try decks.solve("ports\nv1 a 0 dc 1 ac 1 portnum 1 z0 50\nr1 a 0 50\n.sens v(a)\n.sens v(a) ac lin 1 1k 1k\n.end\n");
    defer p.deinit();
    var seen: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if ((try p.query_info(id)).kind != .sens) continue;
        const r = try p.result(id);
        seen += 1;
        for (r.varnames) |name| if (std.mem.indexOfScalar(u8, name, '#') != null) {
            std.debug.print("an internal add's row: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        if (r.is_complex) continue;
        // Forward differences at ngspice's relative step 1e-6.
        try t.expectApproxEqRel(@as(f64, 5e-3), try decks.at(r, 0, "v(r1)"), 1e-5);
        try t.expectApproxEqRel(@as(f64, 0.5), try decks.at(r, 0, "v(v1)"), 1e-5);
    }
    try t.expectEqual(@as(usize, 2), seen);
}
