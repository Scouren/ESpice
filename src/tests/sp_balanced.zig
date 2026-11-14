//! Balanced `.sp` ports: two portnum V cards on one port number make one
//! port, published as its differential and common modes (sp_basis.zig).
//! Oracles:
//! - The mixed-mode transform of Bockelman and Eisenstadt (IEEE Trans. MTT
//!   43(7), 1995), written out per entry. The same deck with each leg its
//!   own single-ended port gives S, and with p, n the legs of ports i, j:
//!   Sdd = (S_pp - S_pn - S_np + S_nn)/2, Sdc = (S_pp + S_pn - S_np - S_nn)/2,
//!   Scd = (S_pp - S_pn + S_np - S_nn)/2, Scc = (S_pp + S_pn + S_np + S_nn)/2.
//!   Only the port numbers differ, so both runs solve one circuit and agree
//!   to rounding.
//! - The mode Z from the single-ended Z through v_d = v_p - v_n,
//!   i_d = (i_p - i_n)/2, v_c = (v_p + v_n)/2, i_c = i_p + i_n: Zdd =
//!   Z_pp - Z_pn - Z_np + Z_nn, Zdc = (Z_pp + Z_pn - Z_np - Z_nn)/2, Zcd =
//!   (Z_pp - Z_pn + Z_np - Z_nn)/2, Zcc = (Z_pp + Z_pn + Z_np + Z_nn)/4. Z
//!   holds no z0, so it pins the mode z0s (2 z0, z0/2) the published Y and Z
//!   are taken against.
//! - A deck symmetric under swapping each port's legs converts no mode:
//!   Sdc = Scd = 0 (a certificate).
//! - Twiss: a passive deck at one temperature has Cy = 2 k T (Y + Y^H), in
//!   the mode basis too, since the mode currents are a real transform of
//!   the leg currents (a certificate for donoise's mode-weighted adjoint).
//! ngspice 44.2 refuses the deck ("duplicate port Index", vsrctemp.c:163),
//! so it is no oracle here.
//! Red before: without net_publish.portList's pairing every deck here was
//! DuplicatePortNumber; without sp.zig's `toModes` the balanced S was the
//! legs' S; with the mode z0 left at z0, Z missed its closed form.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;
const C = std.math.Complex(f64);

/// Two ports' legs (a, b) and (c, d), symmetric under a <-> b, c <-> d, with
/// series, shunt and cross-coupled elements so every entry is complex.
const body = "R1 a c 30\nR2 b d 30\nR3 a b 200\nR4 c d 150\nC1 a 0 1p\nC2 b 0 1p\n" ++
    "C3 c 0 2p\nC4 d 0 2p\nL1 a d 10n\nL2 b c 10n\n";
/// Breaks the leg swap, so modes convert.
const asymmetric = "R5 a d 75\nC5 b 0 3p\n";
/// Each leg its own port: a, b, c, d are ports 1 to 4.
const single = "Va a 0 dc 0 portnum 1 z0 50\nVb b 0 dc 0 portnum 2 z0 50\n" ++
    "Vc c 0 dc 0 portnum 3 z0 50\nVd d 0 dc 0 portnum 4 z0 50\n";
/// The same cards on two balanced ports: (a, b) is port 1, (c, d) port 2.
const balanced = "Va a 0 dc 0 portnum 1 z0 50\nVb b 0 dc 0 portnum 1 z0 50\n" ++
    "Vc c 0 dc 0 portnum 2 z0 50\nVd d 0 dc 0 portnum 2 z0 50\n";
const sweep = ".sp dec 2 1e+08 1e+09\n.end\n";

/// Per-block scale of the closed form, dd, dc, cd, cc.
const s_scale = [4]f64{ 0.5, 0.5, 0.5, 0.5 };
const z_scale = [4]f64{ 1, 0.5, 0.5, 0.25 };

// ---- private ----

/// Reads `x`'s 4 x 4 matrix (S, Y, Z or Cy) at point `k` of `r`.
fn read(r: api.Result, k: usize, comptime x: []const u8) ![4][4]C {
    var m: [4][4]C = undefined;
    for (0..4) |i| for (0..4) |j| {
        var buf: [16]u8 = undefined;
        const v = try decks.atComplex(r, k, try std.fmt.bufPrint(&buf, "v(" ++ x ++ "_{d}_{d})", .{ i + 1, j + 1 }));
        m[i][j] = C.init(v[0], v[1]);
    };
    return m;
}

/// The mixed-mode matrix of the single-ended `x`, legs (2i, 2i + 1) of port
/// i, in ESPice's mode order d1, d2, c1, c2, each block scaled per `scale`.
fn modes(x: [4][4]C, scale: [4]f64) [4][4]C {
    var m: [4][4]C = undefined;
    for (0..2) |i| for (0..2) |j| {
        const pp = x[2 * i][2 * j];
        const pn = x[2 * i][2 * j + 1];
        const np = x[2 * i + 1][2 * j];
        const nn = x[2 * i + 1][2 * j + 1];
        m[i][j] = pp.sub(pn).sub(np).add(nn).mul(C.init(scale[0], 0));
        m[i][2 + j] = pp.add(pn).sub(np).sub(nn).mul(C.init(scale[1], 0));
        m[2 + i][j] = pp.sub(pn).add(np).sub(nn).mul(C.init(scale[2], 0));
        m[2 + i][2 + j] = pp.add(pn).add(np).add(nn).mul(C.init(scale[3], 0));
    };
    return m;
}

/// Expects every entry of `got` within `rtol` of `want`'s largest entry.
fn expectClose(what: []const u8, got: [4][4]C, want: [4][4]C, rtol: f64) !void {
    var big: f64 = 0;
    for (want) |row| for (row) |w| {
        big = @max(big, w.magnitude());
    };
    for (got, want, 0..) |grow, wrow, i| for (grow, wrow, 0..) |g, w, j| {
        if (g.sub(w).magnitude() <= rtol * big) continue;
        std.debug.print("{s}[{d}][{d}]: got {e}{e}j, want {e}{e}j\n", .{ what, i, j, g.re, g.im, w.re, w.im });
        return error.TestUnexpectedResult;
    };
}

test "balanced ports' S and Z equal the mixed-mode transform of the same deck's single-ended S and Z" {
    inline for (.{ "", asymmetric }) |extra| {
        const se = try decks.solve("legs\n" ++ single ++ body ++ extra ++ sweep);
        defer se.deinit();
        const mm = try decks.solve("modes\n" ++ balanced ++ body ++ extra ++ sweep);
        defer mm.deinit();
        const r_se = try decks.resultOf(se, .sp);
        const r_mm = try decks.resultOf(mm, .sp);
        try t.expectEqual(@as(usize, 3), r_mm.npoints);
        for (0..r_mm.npoints) |k| {
            try expectClose("S", try read(r_mm, k, "S"), modes(try read(r_se, k, "S"), s_scale), 1e-12);
            try expectClose("Z", try read(r_mm, k, "Z"), modes(try read(r_se, k, "Z"), z_scale), 1e-9);
        }
    }
}

test "a balanced port on a leg-symmetric deck converts no mode" {
    const p = try decks.solve("symmetric\n" ++ balanced ++ body ++ sweep);
    defer p.deinit();
    const r = try decks.resultOf(p, .sp);
    for (0..r.npoints) |k| {
        const s = try read(r, k, "S");
        // Rounding alone: the asymmetric deck converts 7e-3 to 0.16 here
        // (scratch nodal-Y model).
        for (0..2) |i| for (0..2) |j| {
            try t.expect(s[i][2 + j].magnitude() < 1e-12);
            try t.expect(s[2 + i][j].magnitude() < 1e-12);
        };
        // And modes do pass: |Sdd21| is 0.21 to 0.38 over the sweep.
        try t.expect(s[1][0].magnitude() > 0.1);
    }
    // The probes are the last port's + leg's drive (Vc's), as ngspice dumps
    // its last port's.
    for ([_]struct { []const u8, f64 }{ .{ "v(vc#res)", 1 }, .{ "v(vd#res)", 0 }, .{ "v(va#res)", 0 } }) |w| {
        const v = try decks.atComplex(r, 0, w[0]);
        try t.expectApproxEqAbs(w[1], v[0], 1e-12);
        try t.expectApproxEqAbs(@as(f64, 0), v[1], 1e-12);
    }
}

test "donoise over balanced ports meets Twiss: Cy = 2kT (Y + Y^H)" {
    const p = try decks.solve("twiss\n" ++ balanced ++ body ++ asymmetric ++ ".sp dec 2 1e+08 1e+09 1\n.end\n");
    defer p.deinit();
    const r = try decks.resultOf(p, .sp);
    // ngspice CONSTboltz at the default 27 C.
    const kt2 = 2 * 1.38064852e-23 * (27 + 273.15);
    for (0..r.npoints) |k| {
        const y = try read(r, k, "Y");
        var want: [4][4]C = undefined;
        for (0..4) |i| for (0..4) |j| {
            want[i][j] = y[i][j].add(y[j][i].conjugate()).mul(C.init(kt2, 0));
        };
        try expectClose("Cy", try read(r, k, "Cy"), want, 1e-9);
    }
}

test "a balanced port is refused by .hblin, and by a .lin mixedmode2port that names a mode it lacks" {
    const one = "refused\nVa a 0 dc 0 portnum 1 z0 50\nVb b 0 dc 0 portnum 1 z0 50\nVc c 0 dc 0 portnum 2 z0 50\n" ++
        "R1 a c 30\nR2 b c 30\nR3 a b 200\nR4 c 0 150\n";
    try t.expectError(error.UnsupportedAnalysisOutput, decks.solve(one ++ ".hb 1meg 4\n.hblin poi 2 10k 100k\n.end\n"));
    inline for (.{ "ss", "sd", "cc", "dx", "d" }) |mode| {
        try t.expectError(error.InvalidAnalysisArguments, decks.solve(one ++ ".ac lin 1 1meg 1meg\n.lin mixedmode2port=" ++ mode ++ "\n.end\n"));
    }
    inline for (.{ "ds", "cs", "DS" }) |mode| {
        const p = try decks.solve(one ++ ".ac lin 1 1meg 1meg\n.lin mixedmode2port=" ++ mode ++ "\n.end\n");
        defer p.deinit();
        const r = try decks.resultOf(p, .sp);
        try t.expectEqualStrings("LIN Analysis", r.plotname);
        _ = try decks.column(r, "S(3,3)");
    }
}
