//! A noise generator a card sets and ESPice does not model refuses `.noise`
//! and nothing else. Oracle: ngspice resnoise.c, whose resistor flicker
//! generator scales with the model's KF (zero at KF = 0) and moves no DC,
//! transient or AC number; resistor.va has no flicker generator, so a
//! `.noise` that ran would print a spectrum short by it.
const std = @import("std");
const deck = @import("deck.zig");
const t = std.testing;

/// A resistor divider whose top resistor's model sets `kf=$` (gf180's poly
/// resistors carry KF and AF), and one analysis `@`.
const bench = "noise gap\nv1 in 0 dc 1 ac 1\nr1 in out 1k rpoly\nr2 out 0 1k\n" ++
    ".model rpoly r(kf=$ af=1)\n@\n.end\n";
const noise = ".noise v(out) v1 dec 1 1k 10k";

// ---- private ----

/// `bench` with `kf` and `analysis` in place, in `arena`.
fn deckText(arena: std.mem.Allocator, kf: []const u8, analysis: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, try std.mem.replaceOwned(u8, arena, bench, "$", kf), "@", analysis);
}

test "a resistor's kf refuses .noise, runs .op, and kf=0 runs .noise" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.UnmodelledNoise, deck.solve(try deckText(a, "1e-24", noise)));
    const op = try deck.solve(try deckText(a, "1e-24", ".op"));
    op.deinit();
    const inert = try deck.solve(try deckText(a, "0", noise));
    inert.deinit();
}
