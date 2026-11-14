//! A quiet resistor (`noisy=0`, or its alias `noise=0`) publishes no
//! `.noise` contribution column and still loads the circuit. Oracle:
//! ngspice-44.2's vector lists and values for this deck (`ngspice -b -r`,
//! measured 2026-11-11), whose resnoise.c:57 skips the instance; its
//! `_1overf` columns are left out, as resistor.va has no flicker generator.
//! The values are also the closed form sqrt(4kT R) R2||R3 / (R + R2||R3)
//! for R1, with R2 still in the divider.
//! Red before (the tree of 2026-11-11 without the `quiet` table): both
//! plots added `r2` columns, `onoise_r2_thermal` and `onoise_r2` at zero.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;
const expectSameNames = decks.expectSameNames;

const bench = "quiet resistor\nv1 in 0 dc 0 ac 1\nr1 in out 1k\nr2 out 0 2k $\nr3 out 0 4k\n" ++
    ".noise v(out) v1 dec 1 1k 10k 1\n.end\n";

test "a noisy=0 resistor publishes no .noise column, as ngspice skips it, and still loads the circuit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "noisy=0", "noise=0" }) |key| {
        const p = try decks.solve(try std.mem.replaceOwned(u8, arena.allocator(), bench, "$", key));
        defer p.deinit();
        var spectrum = [_][]const u8{ "frequency", "onoise_r1_thermal", "onoise_r1", "onoise_r3_thermal", "onoise_r3", "onoise_spectrum", "inoise_spectrum" };
        var totals = [_][]const u8{
            "v(onoise_total_r1_thermal)", "v(inoise_total_r1_thermal)", "v(onoise_total_r1)", "v(inoise_total_r1)",
            "v(onoise_total_r3_thermal)", "v(inoise_total_r3_thermal)", "v(onoise_total_r3)", "v(inoise_total_r3)",
            "v(onoise_total)",            "v(inoise_total)",
        };
        var seen: usize = 0;
        for (0..p.query_count()) |i| {
            const id: api.QueryId = @fromBackingInt(@intCast(i));
            if ((try p.query_info(id)).kind != .noise) continue;
            const r = try p.result(id);
            seen += 1;
            if (r.npoints == 1) {
                try expectSameNames(&totals, r.varnames);
                try t.expectApproxEqRel(@as(f64, 2.4676237861974316e-07), try decks.at(r, 0, "v(onoise_total)"), 1e-9);
                continue;
            }
            try expectSameNames(&spectrum, r.varnames);
            // A linear circuit: ngspice's numbers are its arithmetic, not
            // a Newton tolerance, so they hold to rounding.
            for (0..r.npoints) |k| {
                try t.expectApproxEqRel(@as(f64, 2.3264980168499027e-09), try decks.at(r, k, "onoise_r1"), 1e-9);
                try t.expectApproxEqRel(@as(f64, 1.1632490084249514e-09), try decks.at(r, k, "onoise_r3"), 1e-9);
                try t.expectApproxEqRel(@as(f64, 2.6011038575974166e-09), try decks.at(r, k, "onoise_spectrum"), 1e-9);
            }
        }
        try t.expectEqual(@as(usize, 2), seen);
    }
}
