//! A topology fact refuses only the analyses whose solve cannot meet it
//! (`core.validate.validateDeck`, at admission). Oracles: the closed forms
//! of a `uic` transient that holds each fact (an inductor across a source
//! ramps as i = V t / L; a capacitor-only node keeps its charge; a current
//! source into a capacitor ramps as v = I t / C), and ngspice's verdicts:
//! a V/L loop that disagrees at DC is refused by every analysis that
//! solves an operating point and run by its UIC transient.
const std = @import("std");
const deck = @import("deck.zig");
const t = std.testing;

test "topology: a V/L loop that disagrees at DC runs under uic: i(L1) ramps as V t / L" {
    const p = try deck.solve("v/l loop\nV1 a 0 1\nL1 a 0 1u\n.tran 1n 10n uic\n.end\n");
    defer p.deinit();
    const r = try deck.resultOf(p, .tran);
    try t.expect(r.npoints > 10);
    for (0..r.npoints) |k| {
        // i is linear in t, which every integrator ESPice runs (trapezoidal,
        // BE, Gear) integrates exactly; what is left is the Newton
        // tolerance and rounding.
        const want = 1.0 * try deck.at(r, k, "time") / 1e-6;
        try t.expectApproxEqAbs(want, try deck.at(r, k, "i(l1)"), 1e-9 * 1e-2);
    }
    try t.expectApproxEqRel(@as(f64, 1e-2), try deck.at(r, r.npoints - 1, "i(l1)"), 1e-9);
}

test "topology: a V/L loop that disagrees at DC refuses every analysis that solves an operating point" {
    for ([_][]const u8{ ".op", ".tran 1n 10n", ".ac dec 1 1k 1meg", ".dc v1 0 1 1" }) |analysis| {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "v/l loop\nV1 a 0 1 ac 1\nL1 a 0 1u\n{s}\n.end\n", .{analysis});
        try t.expectError(error.VoltageSourceLoop, deck.solve(text));
    }
}

test "topology: a loop of voltage sources alone is refused under uic too" {
    // No current satisfies KVL when they disagree; none is fixed when they agree.
    try t.expectError(error.VoltageSourceLoop, deck.solve("v loop\nV1 a 0 1\nV2 a 0 2\n.tran 1n 10n uic\n.end\n"));
    try t.expectError(error.NonuniqueOperatingPoint, deck.solve("v loop\nV1 a 0 1\nV2 a 0 1\nR1 a 0 1k\n.tran 1n 10n uic\n.end\n"));
}

test "topology: a node with no DC path runs under uic and keeps its charge; a static operating point refuses it" {
    // docs/learn/first-circuit.md, exercise 3: x reaches the rest only
    // through C1, which starts uncharged, so v(x) = v(out) = 10 V throughout.
    const circuit = "floating x\nV1 in 0 10\nR1 in out 1k\nC1 out x 1n\n";
    const p = try deck.solve(circuit ++ ".tran 1u 10u uic\n.end\n");
    defer p.deinit();
    const r = try deck.resultOf(p, .tran);
    try t.expect(r.npoints > 1);
    for (0..r.npoints) |k| {
        try t.expectApproxEqAbs(@as(f64, 10), try deck.at(r, k, "v(x)"), 1e-9);
        try t.expectApproxEqAbs(@as(f64, 10), try deck.at(r, k, "v(out)"), 1e-9);
    }
    try t.expectError(error.FloatingNode, deck.solve(circuit ++ ".op\n.end\n"));
    // A transient's own operating point settles the node (OPtran).
    const settled = try deck.solve(circuit ++ ".tran 1u 10u\n.end\n");
    settled.deinit();
}

test "topology: a current-source cutset runs under uic, v = I t / C; any operating point refuses it" {
    const circuit = "cutset\nI1 0 out 1m\nC1 out 0 1u\n";
    const p = try deck.solve(circuit ++ ".tran 10u 1m uic\n.end\n");
    defer p.deinit();
    const r = try deck.resultOf(p, .tran);
    for (0..r.npoints) |k| {
        const want = 1e-3 * try deck.at(r, k, "time") / 1e-6;
        try t.expectApproxEqAbs(want, try deck.at(r, k, "v(out)"), 1e-9);
    }
    try t.expectError(error.CurrentSourceCutset, deck.solve(circuit ++ ".tran 10u 1m\n.end\n"));
    try t.expectError(error.CurrentSourceCutset, deck.solve(circuit ++ ".op\n.end\n"));
}
