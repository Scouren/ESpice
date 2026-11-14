//! The `.sp` plot in ngspice's column order: frequency, the probes of the
//! last port's drive, S, Y and Z, then donoise's Cy, NF, SOpt, NFmin, Rn.
//! Oracles:
//! - ngspice-44.2's `SP Analysis` plot of the same two-port deck (`ngspice
//!   -b -r`, measured 2026-11-11): its column names and values. The deck is
//!   linear with an all-zero operating point, so each of ngspice's numbers
//!   is one complex LU solve, exact to rounding with no reltol in it. ESPice
//!   sat within 1.4e-13 relative (5.4e-16 absolute) of it on every S entry
//!   and 1e-15 on the noise figures, so 1e-11 relative holds with an
//!   absolute floor under each column's scale.
//! - A matched 150/37.5/150 ohm pi attenuator between 50 ohm ports, by hand:
//!   S11 = S22 = 0, S21 = S12 = 1/2, so Z = z0 (E + S)(E - S)^-1 =
//!   50 [[5/3, 4/3], [4/3, 5/3]], and Y = Z^-1 is the nodal admittance read
//!   off the circuit, [[1/150 + 1/37.5, -1/37.5], [-1/37.5, 1/150 + 1/37.5]].
//! Red before: without sp.zig's probe hunks the plot held frequency and S
//! alone (`v(p1)` was a MissingColumn); without its Y and Z hunk Cy
//! followed S and `v(Y_1_1)` was a MissingColumn.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

/// Two ports with unequal z0 around a resistive tee with a series C.
const two_port = "two-port\nV1 p1 0 dc 0 portnum 1 z0 50\nV2 p2 0 dc 0 portnum 2 z0 75\n" ++
    "R1 p1 x 20\nR2 x 0 100\nC3 x p2 2e-09\nR4 p2 0 200\n";

/// One measured complex column value: name, re, im.
const Value = struct { []const u8, f64, f64 };

// ---- private ----

/// Expects each of `want`'s columns of complex `r` at point `k` within
/// `rtol` relative plus `atol` absolute, both parts.
fn expectValues(r: api.Result, k: usize, want: []const Value, rtol: f64, atol: f64) !void {
    for (want) |w| {
        const got = try decks.atComplex(r, k, w[0]);
        for (got, [2]f64{ w[1], w[2] }) |g, e| {
            if (@abs(g - e) <= rtol * @abs(e) + atol) continue;
            std.debug.print("{s} at point {d}: got {e}, want {e}\n", .{ w[0], k, g, e });
            return error.TestUnexpectedResult;
        }
    }
}

/// Expects `got` to equal `want`, name by name, in order.
fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test ".sp leads with the probes of its last port's drive, as ngspice's plot does" {
    const p = try decks.solve(two_port ++ ".sp dec 2 1e+06 1e+08\n.end\n");
    defer p.deinit();
    const r = try decks.resultOf(p, .sp);
    try t.expect(r.is_complex);
    try t.expectEqual(@as(usize, 5), r.npoints);
    try t.expectEqualStrings("frequency", r.varnames[0]);
    // ngspice lists the external nodes, then each source's branch and
    // `#res` node; ESPice lists branch currents first, so the block is
    // compared as a set. S follows it in both.
    var probes = [_][]const u8{ "v(p1)", "v(p2)", "v(x)", "i(v2)", "v(v2#res)", "i(v1)", "v(v1#res)" };
    try decks.expectSameNames(&probes, r.varnames[1..8]);
    try expectNames(&.{ "v(S_1_1)", "v(S_1_2)", "v(S_2_1)", "v(S_2_2)" }, r.varnames[8..12]);
    // ngspice's values at 1 MHz and 100 MHz: port 2, the last, is driven
    // (v(v2#res) = 1) and port 1 rests (v(v1#res) = 0).
    const at_1meg = [_]Value{
        .{ "v(p1)", 0.13213896943945191, 0.10985241955792974 },
        .{ "v(p2)", 0.482215002130471, -0.20372630536197872 },
        .{ "v(x)", 0.18499455721523267, 0.15379338738110163 },
        .{ "i(v2)", -0.00690379997159372, -0.0027163507381597163 },
        .{ "v(v2#res)", 1.0, 0.0 },
        .{ "i(v1)", 0.0026427793887890383, 0.0021970483911585947 },
        .{ "v(v1#res)", 0.0, 0.0 },
    };
    const at_100meg = [_]Value{
        .{ "v(p1)", 0.223448244054908, 0.0018576147793140192 },
        .{ "v(p2)", 0.3128778019345343, -0.0034450310452726523 },
        .{ "v(x)", 0.3128275416768712, 0.002600660691039627 },
        .{ "i(v2)", -0.009161629307539543, -4.5933747270302036e-05 },
        .{ "v(v2#res)", 1.0, 0.0 },
        .{ "i(v1)", 0.00446896488109816, 3.7152295586280386e-05 },
        .{ "v(v1#res)", 0.0, 0.0 },
    };
    try expectValues(r, 0, &at_1meg, 1e-12, 1e-15);
    try expectValues(r, 4, &at_100meg, 1e-12, 1e-15);
}

test ".sp publishes Y and Z after S, and donoise's columns after Z, at ngspice's values" {
    const p = try decks.solve(two_port ++ ".sp dec 2 1e+06 1e+08 1\n.end\n");
    defer p.deinit();
    const r = try decks.resultOf(p, .sp);
    try expectNames(&.{
        "v(S_1_1)",  "v(S_1_2)",  "v(S_2_1)",  "v(S_2_2)",
        "v(Y_1_1)",  "v(Y_1_2)",  "v(Y_2_1)",  "v(Y_2_2)",
        "v(Z_1_1)",  "v(Z_1_2)",  "v(Z_2_1)",  "v(Z_2_2)",
        "v(Cy_1_1)", "v(Cy_1_2)", "v(Cy_2_1)", "v(Cy_2_2)",
        "v(NF)",     "v(SOpt)",   "v(NFmin)",  "v(Rn)",
    }, r.varnames[8..]);
    const yz_1meg = [_]Value{
        .{ "v(Y_1_1)", 0.010084234722896665, 0.00835993833046416 },
        .{ "v(Y_1_2)", -0.0021010816674759945, -0.010031925996556994 },
        .{ "v(Y_2_1)", -0.0021010816674759945, -0.010031925996556992 },
        .{ "v(Y_2_2)", 0.0075212980009711945, 0.012038311195868389 },
        .{ "v(Z_1_1)", 88.85788600752898, -8.260702300388377 },
        .{ "v(Z_1_2)", 62.284227984941964, 16.52140460077681 },
        .{ "v(Z_2_1)", 62.28422798494196, 16.521404600776798 },
        .{ "v(Z_2_2)", 75.431544030116, -33.04280920155356 },
    };
    const yz_100meg = [_]Value{
        .{ "v(Y_1_1)", 0.04990522744585099, 0.001984911732510013 },
        .{ "v(Y_1_2)", -0.04988627293502116, -0.002381894079012015 },
        .{ "v(Y_2_1)", -0.04988627293502117, -0.0023818940790120147 },
        .{ "v(Y_2_2)", 0.06486352752202539, 0.002858272894814381 },
        .{ "v(Z_1_1)", 86.66690120479332, -0.08841879069696555 },
        .{ "v(Z_1_2)", 66.66619759041325, 0.17683758139441608 },
        .{ "v(Z_2_1)", 66.66619759041325, 0.17683758139441602 },
        .{ "v(Z_2_2)", 66.66760481917343, -0.3536751627883477 },
    };
    try expectValues(r, 0, &yz_1meg, 1e-11, 1e-15);
    try expectValues(r, 4, &yz_100meg, 1e-11, 1e-15);
    // Cy is ~1e-22 A^2/Hz: its floor sits far under that scale.
    const cy_1meg = [_]Value{
        .{ "v(Cy_1_1)", 1.671569416484716e-22, 0.0 },
        .{ "v(Cy_1_2)", -3.482766866696594e-23, -3.5264830524668625e-38 },
        .{ "v(Cy_2_1)", -3.482766866696594e-23, 3.5264830524668625e-38 },
        .{ "v(Cy_2_2)", 1.2467353305595917e-22, 0.0 },
    };
    const cy_100meg = [_]Value{
        .{ "v(Cy_1_1)", 8.272323504310108e-22, 0.0 },
        .{ "v(Cy_1_2)", -8.269181592060123e-22, -3.6734198463196485e-39 },
        .{ "v(Cy_2_1)", -8.269181592060123e-22, 3.6734198463196485e-39 },
        .{ "v(Cy_2_2)", 1.0751821217028146e-21, 0.0 },
    };
    try expectValues(r, 0, &cy_1meg, 1e-11, 1e-34);
    try expectValues(r, 4, &cy_100meg, 1e-11, 1e-34);
    const figures_1meg = [_]Value{
        .{ "v(NF)", 6.721083806286002, 0.0 },
        .{ "v(SOpt)", 0.11692800032326621, 0.17771687830969146 },
        .{ "v(NFmin)", 6.529683283189187, 0.0 },
        .{ "v(Rn)", 71.59453263905202, 0.0 },
    };
    const figures_100meg = [_]Value{
        .{ "v(NF)", 4.5790958952210845, 0.0 },
        .{ "v(SOpt)", -0.09126876805900196, 0.003158834006827229 },
        .{ "v(NFmin)", 4.547188102715063, 0.0 },
        .{ "v(Rn)", 26.004559453263898, 0.0 },
    };
    try expectValues(r, 0, &figures_1meg, 1e-11, 1e-15);
    try expectValues(r, 4, &figures_100meg, 1e-11, 1e-15);
}

test ".sp's Y and Z on a matched resistive pi equal Z = z0 (E + S)(E - S)^-1 and its nodal Y" {
    const p = try decks.solve("pi\nVp1 a 0 dc 0 portnum 1 z0 50\nR1 a 0 150\nR2 a b 37.5\nR3 b 0 150\n" ++
        "Vp2 b 0 dc 0 portnum 2 z0 50\n.sp lin 3 1k 1meg\n.end\n");
    defer p.deinit();
    const r = try decks.resultOf(p, .sp);
    try t.expectEqual(@as(usize, 3), r.npoints);
    const want = [_]Value{
        .{ "v(S_1_1)", 0, 0 },           .{ "v(S_1_2)", 0.5, 0 },         .{ "v(S_2_1)", 0.5, 0 },         .{ "v(S_2_2)", 0, 0 },
        .{ "v(Y_1_1)", 1.0 / 30.0, 0 },  .{ "v(Y_1_2)", -2.0 / 75.0, 0 }, .{ "v(Y_2_1)", -2.0 / 75.0, 0 }, .{ "v(Y_2_2)", 1.0 / 30.0, 0 },
        .{ "v(Z_1_1)", 250.0 / 3.0, 0 }, .{ "v(Z_1_2)", 200.0 / 3.0, 0 }, .{ "v(Z_2_1)", 200.0 / 3.0, 0 }, .{ "v(Z_2_2)", 250.0 / 3.0, 0 },
    };
    for (0..r.npoints) |k| try expectValues(r, k, &want, 1e-12, 1e-13);
}
