//! A portnum V's output names: its z0 is a resistor in the circuit, in
//! series with the ideal source through an internal node, and ESPice
//! publishes that node and that resistor as ngspice publishes its vsrc's.
//! Oracles: ngspice-44.2's vector lists for these decks (`ngspice -b -r`,
//! measured 2026-11-11), and the closed form of 1 V behind z0 = 50 into
//! R1 = 50: v(a) = R1 / (R1 + z0) = 0.5, dv(a)/dR1 = z0 / (R1 + z0)^2 =
//! 5e-3. ngspice 44.2 aborts `.sens` on a portnum deck ("Internal Error:
//! node allocation in DEVsetup() during sensitivity analysis"), so the
//! sens rows rest on the closed form alone. `.dcmatch`, `.dcsens` and
//! `.acmatch` rest on a metamorphic relation: the same deck with the port's
//! z0 written as its own R card publishes the same rows plus that card's,
//! and each run's total is the root sum of squares of its own rows.
//! Red before (the tree of 2026-11-11 without the hunks in net_card.zig,
//! noise_columns.zig and sens.zig): the `.op` had no `v(v1#res)`, `.noise
//! ... 1` added `onoise_resistor#0_thermal` and `onoise_resistor#0`, and
//! `.sens` added `v(resistor#0)` and the z0 resistor's other parameters.
//! Without the hunk in dcmatch.zig `.dcmatch`, `.dcsens` and `.acmatch`
//! added every `resistor#0.<param>` row, as the explicit deck does.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;
const expectSameNames = decks.expectSameNames;

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

test "a portnum V's z0 adds no .dcmatch, .dcsens or .acmatch row: an explicit z0's deck's rows less its own" {
    const cards = "r1 a b 1k\nr2 b 0 2k\n.ac lin 1 1k 1k\n.dcmatch v(b)\n.dcsens v(b)\n.acmatch v(b)\n.end\n";
    const port = try decks.solve("ports\nv1 a 0 dc 1 ac 1 portnum 1 z0 50\n" ++ cards);
    defer port.deinit();
    // The z0 as an R card ahead of r1: resistor 0 in both decks.
    const explicit = try decks.solve("explicit\nv1 x 0 dc 1 ac 1\nrz x a 50\n" ++ cards);
    defer explicit.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_]api.requests.Kind{ .dcmatch, .dcsens, .acmatch }) |kind| {
        const got = try decks.resultOf(port, kind);
        const want = try decks.resultOf(explicit, kind);
        var kept: std.ArrayList([]const u8) = .empty;
        for (want.varnames) |name| if (!std.mem.startsWith(u8, name, "resistor#0.")) try kept.append(arena.allocator(), name);
        try expectSameNames(kept.items, got.varnames);
        // Squares of the rows that carry a sigma (`dcmatch.pelgromSigma`:
        // 1 without Pelgrom data, 0 for `mfactor`), for the certificate.
        var re: f64 = 0;
        var im: f64 = 0;
        for (got.varnames) |name| {
            if (std.mem.indexOfScalar(u8, name, '#') == null) continue;
            // Two factorizations of one circuit, numbered apart: rounding
            // in a forward difference at a relative step of 1e-6.
            const g: [2]f64 = if (got.is_complex) try decks.atComplex(got, 0, name) else .{ try decks.at(got, 0, name), 0 };
            const w: [2]f64 = if (want.is_complex) try decks.atComplex(want, 0, name) else .{ try decks.at(want, 0, name), 0 };
            for (g, w) |x, y| try t.expectApproxEqAbs(y, x, 1e-9 * @max(@abs(x), @abs(y)) + 1e-18);
            if (std.mem.endsWith(u8, name, ".mfactor")) continue;
            re += g[0] * g[0];
            im += g[1] * g[1];
        }
        switch (kind) {
            .dcmatch => try t.expectApproxEqRel(try decks.at(got, 0, "total_3sigma"), 3 * @sqrt(re), 1e-12),
            .acmatch => {
                try t.expectApproxEqRel((try decks.atComplex(got, 0, "acm_re"))[0], @sqrt(re), 1e-12);
                try t.expectApproxEqRel((try decks.atComplex(got, 0, "acm_im"))[0], @sqrt(im), 1e-12);
            },
            else => {}, // else: `.dcsens` publishes no total
        }
    }
}
