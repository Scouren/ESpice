//! ngspice's `.pss gfreq tstab oscnob psspoints harms sciter steadycoeff
//! [uic]`: the three keys ESPice once read and dropped. Oracles: ngspice-45's
//! source for each key's meaning (dcpss.c), its transient for the
//! spectrum's numbers, and bounds no double can meet for the caps.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

/// The ring of tests/conformance/tests/netlist/pss/ring_oscillator.sp.
const ring = "ring\nr1 x1 c1 1k\nc1 c1 0 1n\nr2 x2 c2 1k\nc2 c2 0 1n\nr3 x3 c3 1k\nc3 c3 0 1n\n" ++
    "b1 x1 0 v=-tanh(3*v(c3))\nb2 x2 0 v=-tanh(3*v(c1))\nb3 x3 0 v=-tanh(3*v(c2))\n";

/// The hartley of espice.zig's `.pss ... uic` orbit test.
const hartley = "hartley\n.model qnl npn(level=1 bf=80 rb=100 ccs=2pf tf=0.3ns tr=6ns cje=3pf cjc=2pf va=50)\n" ++
    "vcc 1 0 5 pwl 0 0 1e-5 5\nr1 1 2 0.2k\nq1 2 3 0 qnl\nc1 3 4 633n\nl1 3 0 1.5\nl2 0 4 500m\nr2 4 2 100\n";

// ---- private ----

/// The period and spectrum plots of solved problem `p`'s one ngspice `.pss`
/// card, in query order.
fn pssPlots(p: *api.Problem) ![2]api.Result {
    var out: [2]api.Result = undefined;
    var k: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if ((try p.query_info(id)).kind != .pss) continue;
        if (k == out.len) return error.ExtraQuery;
        out[k] = try p.result(id);
        k += 1;
    }
    if (k != out.len) return error.MissingQuery;
    return out;
}

/// Expects `text`'s `.pss` refused with NoPeriodicSteadyState, by the run
/// or by its result.
fn expectNoSteadyState(text: []const u8) !void {
    const p = decks.solve(text) catch |err| {
        if (err == error.NoPeriodicSteadyState) return;
        return err;
    };
    defer p.deinit();
    _ = decks.resultOf(p, .pss) catch |err| {
        if (err == error.NoPeriodicSteadyState) return;
        return err;
    };
    std.debug.print("published a periodic steady state: {s}", .{text});
    return error.TestExpectedError;
}

test "ngspice's .pss harms: the card also publishes the orbit's spectrum, harms rows, ngspice-45's to 5e-3" {
    // ngspice writes the period, then "Frequency Domain Periodic Steady
    // State Analysis" (ngspice-45 dcpss.c:993-1046): harms rows at j·f, each
    // vector's DFT magnitude over the period's psspoints samples (DFT
    // 1522-1590: the mean at j = 0, hypot(2/N Σ x sin, 2/N Σ x cos) past
    // it). No ngspice build here implements .pss. Golden: ngspice-45 -n -b
    // -r on this deck with `.options filetype=ascii` and `.tran 20u 2 1.8
    // 20u uic` for the `.pss` (sha256 bcfb517a78fa92d9...): T the mean
    // spacing of v(2)'s rising mid-swing crossings, the last T resampled
    // at 1024 points through that DFT. T 8.1747870625e-3 s,
    // |X_0| 1.3796521153, |X_1| 1.1378658778, |X_2|
    // 0.34992458769 V; reltol=1e-4 at tmax 5u moves each under 4e-5.
    // Tolerance: the orbit test's 5e-3 of |X_1|. Metamorphic: row 1 sits at
    // 1/T of the period plot, the same orbit. Red before: one `.pss` query.
    const p = try decks.solve(hartley ++ ".pss 50 200e-3 2 1024 11 10 5e-3 uic\n.end\n");
    defer p.deinit();
    const plots = try pssPlots(p);
    const period = plots[0];
    try t.expectEqualStrings("Periodic Steady State", period.plotname);
    const spectrum = plots[1];
    try t.expectEqualStrings("Frequency Domain Periodic Steady State Analysis", spectrum.plotname);
    try t.expectEqualStrings("frequency", spectrum.varnames[0]);
    try t.expectEqual(@as(usize, 11), spectrum.npoints);
    const t_period = try decks.at(period, period.npoints - 1, "time");
    try t.expectEqual(@as(f64, 0), try decks.at(spectrum, 0, "frequency"));
    try t.expectEqual(1 / t_period, try decks.at(spectrum, 1, "frequency"));
    try t.expectEqual(10 * (1 / t_period), try decks.at(spectrum, 10, "frequency"));
    const a1 = 1.1378658778;
    try t.expectApproxEqRel(@as(f64, 1.3796521153), try decks.at(spectrum, 0, "v(2)"), 5e-3);
    try t.expectApproxEqRel(@as(f64, a1), try decks.at(spectrum, 1, "v(2)"), 5e-3);
    try t.expectApproxEqAbs(@as(f64, 0.34992458769), try decks.at(spectrum, 2, "v(2)"), 5e-3 * a1);
}

test "ngspice's .pss sciter caps the shooting: sciter 0 is one residual test, too few for the ring" {
    // ngspice-45 dcpss.c:874, 908: the cycle counter is bumped before
    // `> sc_iter` is tested, so sciter 0 stops after one cycle. One test of
    // the started orbit, whose period is read off eight periods' crossings,
    // cannot meet the 1e-7 shooting tolerance, and an unconverged
    // oscillator is refused (`Shoot.end`) where ngspice publishes its best
    // cycle. Legal neighbour: sciter 50 publishes the ring's period,
    // ngspice-45's settled transient's 3.52176 us. Red before: sciter 0
    // refused as no count, and any sciter dropped for 50 steps.
    try expectNoSteadyState(ring ++ ".pss 300k 100u c1 256 10 0 5e-3\n.end\n");
    const p = try decks.solve(ring ++ ".pss 300k 100u c1 256 10 50 5e-3\n.end\n");
    defer p.deinit();
    const period = (try pssPlots(p))[0];
    try t.expectApproxEqRel(@as(f64, 3.52176e-6), try decks.at(period, period.npoints - 1, "time"), 1e-3);
}

test "ngspice's .pss steadycoeff bounds every unknown's period residual: 1e-15 is out of a double's reach" {
    // ngspice-45 dcpss.c:762-786: converged needs every unknown's |x(T) -
    // x(0)| within (swing·reltol + vntol, abstol on a '#' row)·trtol·
    // steadycoeff. At 1e-15 the ring's nets, swinging about 2 V, get 1.4e-17
    // V and its branch currents 1e-20 A, each under a tenth of an ulp of
    // its own values: no orbit in doubles meets that, so the shooting runs
    // out of sciter and the oscillator is refused. Legal neighbour: 5e-3
    // publishes (the sciter test). Red before: steadycoeff dropped, the
    // ring published.
    try expectNoSteadyState(ring ++ ".pss 300k 100u c1 256 10 50 1e-15\n.end\n");
}
