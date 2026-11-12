//! ngspice's device operating-point variables (`@d1[gd]`, `@v1[dc]`, #236)
//! on devices other than MOSFETs, through the public API; `.tran` points
//! are opvars_tran.zig's. Oracles, never the device's own arithmetic: KCL
//! (a 0 V ammeter's branch current is the terminal current), central
//! differences of a sweep's currents and charges where every node voltage
//! is a source's (the partials), Ohm's law and the deck's own values (the
//! elements and parameters), the sweep's scale (`@v1[dc]` along `.dc v1`,
//! ngspice's regression/misc/bugs-2.sp), and ngspice-45 goldens for the
//! examples/various *_ac_par.sp decks. Each refusal is a name ngspice
//! answers with a number ESPice cannot produce, or no name at all.
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;
const at = deck.at;
const resultOf = deck.resultOf;
const expectRefused = deck.expectRefused;

/// ngspice-45's examples/various/bjt_ac_par.sp swept at three points
/// instead of 61, and its ngspice values: `ngspice -b` of this deck plus
/// `.save` of the vectors and `.control set numdgt=12 run print ...`
/// (deck sha256 c32661138e9092e6c4d5e44146438d0b60fae215ec0fdd611142d6cbe88efd45
/// with that control block).
const bjt_ac_par =
    \\bjt_ac_par subset
    \\v1 1 0 dc 10.0
    \\rc 1 c 2k
    \\vb b 0 dc 0.6
    \\q1 c b 0 bfs17
    \\.MODEL BFS17 NPN (level=1 IS=0.48F NF=1.008 BF=99.655 VAF=90.000 IKF=0.190
    \\+ ISE=7.490F NE=1.762 NR=1.010 BR=38.400 VAR=7.000 IKR=93.200M
    \\+ ISC=0.200F NC=1.042
    \\+ RB=1.500 IRB=0.100M RBM=1.200
    \\+ RE=0.500 RC=2.680
    \\+ CJE=1.325P VJE=0.700 MJE=0.220 FC=0.890
    \\+ CJC=1.050P VJC=0.610 MJC=0.240 XCJC=0.400
    \\+ TF=56.940P TR=1.000N PTF=21.000
    \\+ XTF=68.398 VTF=0.600 ITF=0.700
    \\+ XTB=1.600 EG=1.110 XTI=3.000
    \\+ KF=1.000F AF=1.000)
    \\.save @q1[gm] @q1[gpi] @q1[go] @q1[qbe] @q1[qbc] @q1[cmu] @q1[cpi] @q1[ic] @q1[ib] @q1[ie] @q1[gx] @q1[cbx]
    \\.dc vb 0.6 0.8 0.1
    \\.end
    \\
;

// ---- private ----

/// The central difference of column `name` over the scale at inner point
/// `k` of `r`.
fn slope(r: api.Result, k: usize, name: []const u8) !f64 {
    const w = r.varnames.len;
    return (try at(r, k + 1, name) - try at(r, k - 1, name)) / (r.data[(k + 1) * w] - r.data[(k - 1) * w]);
}

test "R, L, C, V and I element variables are Ohm's law's, the branch current and the card's values (#236)" {
    // Oracle: the DC solution by hand. L shorts and C opens, so 2 V drives
    // 1 mA through r1, l1 and r2; i1 pushes 1 mA into d through 2 kOhm, so
    // V(d) = 2 V. ngspice's source current is the branch current into its
    // + terminal (vsrcask.c), -1 mA, and its power (v+ - v-) i. Red before
    // #236: `r1 has no variable 'i'`, UnsupportedCard at Problem.init.
    const p = try deck.solve(
        \\elements
        \\v1 a 0 dc 2
        \\r1 a b 1k
        \\l1 b c 1u
        \\c1 c 0 1n
        \\r2 c 0 1k
        \\i1 0 d dc 1m
        \\r3 d 0 2k
        \\.save i(v1) @r1[i] @r1[p] @r1[resistance] @r1[r] @v1[i] @v1[p] @v1[dc] @l1[i] @l1[v] @l1[p] @l1[inductance]
        \\.save @c1[i] @c1[p] @c1[capacitance] @c1[cap] @i1[c] @i1[dc] @i1[v]
        \\.op
        \\.end
        \\
    );
    defer p.deinit();
    const r = try resultOf(p, .op);
    try t.expectApproxEqRel(@as(f64, 1e-3), try at(r, 0, "@r1[i]"), 1e-9);
    try t.expectApproxEqRel(@as(f64, 1e-3), try at(r, 0, "@r1[p]"), 1e-9);
    try t.expectEqual(@as(f64, 1000), try at(r, 0, "@r1[resistance]"));
    try t.expectEqual(@as(f64, 1000), try at(r, 0, "@r1[r]"));
    try t.expectApproxEqRel(try at(r, 0, "i(v1)"), try at(r, 0, "@v1[i]"), 1e-12);
    try t.expectApproxEqRel(@as(f64, -1e-3), try at(r, 0, "@v1[i]"), 1e-9);
    try t.expectApproxEqRel(@as(f64, -2e-3), try at(r, 0, "@v1[p]"), 1e-9);
    try t.expectEqual(@as(f64, 2), try at(r, 0, "@v1[dc]"));
    try t.expectApproxEqRel(@as(f64, 1e-3), try at(r, 0, "@l1[i]"), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0), try at(r, 0, "@l1[v]"), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0), try at(r, 0, "@l1[p]"), 1e-15);
    try t.expectEqual(@as(f64, 1e-6), try at(r, 0, "@l1[inductance]"));
    // capask.c: no current and no power at a DC point.
    try t.expectEqual(@as(f64, 0), try at(r, 0, "@c1[i]"));
    try t.expectEqual(@as(f64, 0), try at(r, 0, "@c1[p]"));
    try t.expectEqual(@as(f64, 1e-9), try at(r, 0, "@c1[capacitance]"));
    try t.expectEqual(@as(f64, 1e-9), try at(r, 0, "@c1[cap]"));
    try t.expectEqual(@as(f64, 1e-3), try at(r, 0, "@i1[c]"));
    try t.expectEqual(@as(f64, 1e-3), try at(r, 0, "@i1[dc]"));
    try t.expectApproxEqRel(@as(f64, -2), try at(r, 0, "@i1[v]"), 1e-9);
}

test "R, C and L values at a .temp are ngspice-44.2's: C and L tempered, C times m, R the card's own (#236)" {
    // Oracle: ngspice 44.2 (`ngspice -b`, the deck below plus `.control set
    // numdgt=12 run print ...`, sha256 789a71698e77eb95b3abef081de969e2
    // 29f39be55f2326dbec3357947c09406a with it). At 77 °C the factor is 1 +
    // 50e-3 + 2500e-5 = 1.075: captemp.c and indtemp.c temper C's and L's
    // value and capask.c multiplies C's by m; restemp.c leaves R's the
    // card's 1k, and its i the tempered m/(R factor). Red before:
    // `@r1[resistance]` read the folded 500 and `@c1[capacitance]` the
    // untempered 1e-9.
    const p = try deck.solve(
        \\tempered element values
        \\v1 a 0 dc 1
        \\r1 a 0 1k m=2 tc1=1e-3 tc2=1e-5
        \\c1 a 0 1n m=2 tc1=1e-3 tc2=1e-5
        \\l1 a b 1u m=2 tc1=1e-3 tc2=1e-5
        \\r2 b 0 1k
        \\.save @r1[resistance] @r1[r] @r1[i] @r1[p] @c1[capacitance] @c1[cap] @c1[c] @l1[inductance] @l1[i] i(v1)
        \\.temp 77
        \\.op
        \\.end
        \\
    );
    defer p.deinit();
    const r = try resultOf(p, .op);
    const golden = [_]struct { []const u8, f64 }{
        .{ "@r1[resistance]", 1.000000000000e+03 },
        .{ "@r1[r]", 1.000000000000e+03 },
        .{ "@r1[i]", 1.860465116279e-03 },
        .{ "@r1[p]", 1.860465116279e-03 },
        .{ "@c1[capacitance]", 2.150000000000e-09 },
        .{ "@c1[cap]", 2.150000000000e-09 },
        .{ "@c1[c]", 2.150000000000e-09 },
        .{ "@l1[inductance]", 1.075000000000e-06 },
        .{ "@l1[i]", 1.000000000000e-03 },
        .{ "i(v1)", -2.86046511628e-03 },
    };
    for (golden) |g| t.expectApproxEqRel(g[1], try at(r, 0, g[0]), 1e-9) catch |err| {
        std.debug.print("{s}: want {e}, got {e}\n", .{ g[0], g[1], try at(r, 0, g[0]) });
        return err;
    };
}

test "@v1[dc] along .dc v1 is each point's swept value; another source's is its own (#236)" {
    // Oracle: ngspice's regression/misc/bugs-2.sp, whose @v1[dc] ngspice-45
    // prints as 0, 0.25, 0.5, 0.75, 1: the sweep's scale. Red before #236:
    // `v1 has no variable 'dc'`, UnsupportedCard at Problem.init.
    const p = try deck.solve("parser test\nv1 1 0 dc=0\nv2 2 0 dc 3\nr1 1 2 1k\n.save @v1[dc] @v2[dc]\n.dc v1 0 1 250m\n.end\n");
    defer p.deinit();
    const r = try resultOf(p, .dc);
    try t.expectEqual(@as(usize, 5), r.npoints);
    for (0..r.npoints) |k| {
        try t.expectEqual(@as(f64, 0.25) * @as(f64, @floatFromInt(k)), try at(r, k, "@v1[dc]"));
        try t.expectEqual(@as(f64, 3), try at(r, k, "@v2[dc]"));
    }
    // The outer sweep's value is no column: refused, and its inner
    // neighbour is the scale again.
    try expectRefused("outer\nv1 1 0 dc=0\nv2 2 0 dc 3\nr1 1 2 1k\n.save @v1[dc]\n.dc v2 0 1 0.5 v1 0 1 0.5\n.end\n");
    const inner = try deck.solve("inner\nv1 1 0 dc=0\nv2 2 0 dc 3\nr1 1 2 1k\n.save @v2[dc]\n.dc v2 0 1 0.5 v1 0 1 0.5\n.end\n");
    defer inner.deinit();
    const ri = try resultOf(inner, .dc);
    for (0..ri.npoints) |k| try t.expectEqual(ri.data[k * ri.varnames.len], try at(ri, k, "@v2[dc]"));
}

test "a diode's @d1[id] is the ammeter's current, gd and cd the central differences of it and qd (#236)" {
    // Oracles: KCL at the anode, and the partials as central differences
    // over 0.2 mV, where every node voltage is a source's. Their
    // truncation, (h / n vt)^2 / 6 = 1e-5 on the exponential, sets the
    // 1e-4. dio.c's `c` is `id`, `qd` is `charge`. Red before #236:
    // `d1 has no variable 'id'`, UnsupportedCard at Problem.init.
    const p = try deck.solve(
        \\diode opvars
        \\v1 a 0 dc 0.6
        \\vm a k 0
        \\d1 k 0 dm
        \\.model dm d is=1e-14 n=1 cjo=1p tt=1n
        \\.save i(vm) @d1[id] @d1[c] @d1[gd] @d1[cd] @d1[qd] @d1[charge] @d1[vd]
        \\.dc v1 0.59 0.61 0.0002
        \\.end
        \\
    );
    defer p.deinit();
    const r = try resultOf(p, .dc);
    try t.expect(r.npoints >= 3);
    for (0..r.npoints) |k| {
        try t.expectApproxEqRel(try at(r, k, "i(vm)"), try at(r, k, "@d1[id]"), 1e-6);
        try t.expectEqual(try at(r, k, "@d1[id]"), try at(r, k, "@d1[c]"));
        try t.expectEqual(try at(r, k, "@d1[qd]"), try at(r, k, "@d1[charge]"));
        try t.expectApproxEqRel(r.data[k * r.varnames.len], try at(r, k, "@d1[vd]"), 1e-12);
        if (k == 0 or k + 1 == r.npoints) continue;
        try t.expectApproxEqRel(try slope(r, k, "i(vm)"), try at(r, k, "@d1[gd]"), 1e-4);
        try t.expectApproxEqRel(try slope(r, k, "@d1[qd]"), try at(r, k, "@d1[cd]"), 1e-4);
    }
}

test "a Gummel-Poon BJT's ic, ib and ie are its ammeters' currents, gm, gpi and go their central differences (#236)" {
    // Oracles: KCL at each terminal, every node voltage a source's (no RB,
    // RC, RE), and the partials as central differences at fixed V_CE:
    // ngspice's gm and go split the transport current's slope as gm dvbe
    // + go dvce (bjtload.c:634-635, stamped at :908-910), and the B-C
    // diode's gmu (gmin-sized
    // in forward active) is all that separates the terminal slopes from
    // them. ie is -(ic + ib) less the gmin-sized substrate current.
    // Red before #236: `q1 has no variable 'ic'`, UnsupportedCard.
    const body = "bjt opvars\nvc c 0 dc 3\nvb b 0 dc 0.7\nq1 c b 0 qn\n.model qn npn is=1e-15 bf=100 br=2 vaf=50\n" ++
        ".save i(vc) i(vb) @q1[ic] @q1[ib] @q1[ie] @q1[gm] @q1[gpi] @q1[go] @q1[vbe] @q1[vbc]\n{s}\n.end\n";
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ ".dc vb 0.69 0.71 0.0002", ".dc vc 2.9 3.1 0.01" }, 0..) |sweep, by_vc| {
        const p = try deck.solve(try std.fmt.bufPrint(&buf, body, .{sweep}));
        defer p.deinit();
        const r = try resultOf(p, .dc);
        try t.expect(r.npoints >= 3);
        for (0..r.npoints) |k| {
            const ic = try at(r, k, "@q1[ic]");
            const ib = try at(r, k, "@q1[ib]");
            try t.expectApproxEqRel(-(try at(r, k, "i(vc)")), ic, 1e-6);
            try t.expectApproxEqRel(-(try at(r, k, "i(vb)")), ib, 1e-6);
            try t.expectApproxEqRel(-(ic + ib), try at(r, k, "@q1[ie]"), 1e-6);
            try t.expectApproxEqRel((try at(r, k, "@q1[vbe]")) - (try at(r, k, "@q1[vbc]")), if (by_vc == 1) r.data[k * r.varnames.len] else 3, 1e-12);
            if (k == 0 or k + 1 == r.npoints) continue;
            // The terminal currents' slopes: -i(vc) over vb is gm - gmu,
            // -i(vb) over vb is gpi + gmu, -i(vc) over vc is go + gmu.
            if (by_vc == 1) {
                try t.expectApproxEqRel(-(try slope(r, k, "i(vc)")), try at(r, k, "@q1[go]"), 1e-4);
            } else {
                try t.expectApproxEqRel(-(try slope(r, k, "i(vc)")), try at(r, k, "@q1[gm]"), 1e-4);
                try t.expectApproxEqRel(-(try slope(r, k, "i(vb)")), try at(r, k, "@q1[gpi]"), 1e-4);
            }
        }
    }
}

test "bjt_ac_par.sp's @q1[...] are ngspice-45's (#236)" {
    // Oracle: the golden above, at ngspice's own accuracy (reltol 1e-3).
    // 0.8 V saturates q1 through rc. Red before #236: `q1 has no variable
    // 'gm'`, UnsupportedCard. The deck's own `@q1[pi]` is no bjt.c name:
    // ngspice saves nothing for it, and ESPice refuses it.
    const names = [_][]const u8{ "@q1[gm]", "@q1[gpi]", "@q1[go]", "@q1[qbe]", "@q1[qbc]", "@q1[cmu]", "@q1[cpi]", "@q1[ic]", "@q1[ib]", "@q1[ie]", "@q1[gx]", "@q1[cbx]" };
    const golden = [3][names.len]f64{
        .{ 1.844465894424e-04, 1.910077584005e-06, 5.266377310365e-08, 9.287312872952e-13, -2.48729202731e-12, 2.146470874752e-13, 2.043494450857e-12, 4.828017547100e-06, 5.146336953380e-08, -4.87949090696e-06, 6.668308838508e-01, 3.219706318092e-13 },
        .{ 8.319659180128e-03, 8.490891674937e-05, 2.426259463271e-06, 1.172692389609e-12, -2.37344765546e-12, 2.174540463358e-13, 3.100217543610e-12, 2.180353724696e-04, 2.228698406780e-06, -2.20264080440e-04, 6.730482702143e-01, 3.261810968660e-13 },
        .{ 1.950386960610e-01, 3.435085320760e-03, 7.704894915193e-02, 1.870980409793e-12, 2.802671729847e-12, 8.969687596671e-11, 1.976069041463e-11, 4.974471249518e-03, 5.423971818446e-04, -5.51686843140e-03, 7.798109766372e-01, 1.914594612860e-12 },
    };
    const p = try deck.solve(bjt_ac_par);
    defer p.deinit();
    const r = try resultOf(p, .dc);
    try t.expectEqual(@as(usize, 3), r.npoints);
    for (golden, 0..) |row, k| for (names, row) |name, want| {
        t.expectApproxEqRel(want, try at(r, k, name), 1e-3) catch |err| {
            std.debug.print("{s} at point {d}: want {e}, got {e}\n", .{ name, k, want, try at(r, k, name) });
            return err;
        };
    };
    var buf: [2048]u8 = undefined;
    for ([_][]const u8{ "@q1[pi]", "@q1[is]" }) |name| {
        const at_save = std.mem.indexOf(u8, bjt_ac_par, ".save").?;
        try expectRefused(try std.fmt.bufPrint(&buf, "{s}.save {s}\n.dc vb 0.6 0.8 0.1\n.end\n", .{ bjt_ac_par[0..at_save], name }));
    }
}

test "diode_ac_par.sp's @d1[gd], cd and qd are ngspice-45's (#236)" {
    // Oracle: ngspice-45 on examples/various/diode_ac_par.sp swept at three
    // points instead of 511 (`ngspice -b` with `.save` of the vectors and
    // `.control set numdgt=12 run print ...`, deck sha256
    // 1720e6ac0ec827a7410aa786506dc4d9d6e074ccd0d37e1a90ef9e7f784be168),
    // at ngspice's own accuracy (reltol 1e-3). Red before #236: `d1 has no
    // variable 'gd'`, UnsupportedCard.
    const p = try deck.solve(
        \\diode_ac_par subset
        \\v1 1 0 dc 0
        \\d1 1 0 myd
        \\.model myd D(IS=1.50E-07 N=1.0 RS=9 TT=100n CJ0=1.01p VJ=0.44 M=0.5 EG=1.11 XTI=3 KF=0 AF=1 FC=0.5 BV=22 IBV=10u)
        \\.save @d1[gd] @d1[cd] @d1[qd] @d1[id] @d1[vd]
        \\.dc v1 -1 0.1 0.55
        \\.end
        \\
    );
    defer p.deinit();
    const r = try resultOf(p, .dc);
    const names = [_][]const u8{ "@d1[gd]", "@d1[cd]", "@d1[qd]", "@d1[id]", "@d1[vd]" };
    const golden = [3][names.len]f64{
        .{ 1.146714993162e-11, 5.582999147898e-13, -7.34098695769e-13, -1.49997510953e-07, -9.99998650022e-01 },
        .{ 2.562591131536e-10, 7.101804442843e-13, -3.90269875523e-13, -1.49962161247e-07, -4.49998650079e-01 },
        .{ 2.763184592548e-04, 2.878070838550e-11, 8.071242429877e-13, 6.996954090243e-06, 9.993702761242e-02 },
    };
    try t.expectEqual(@as(usize, 3), r.npoints);
    for (golden, 0..) |row, k| for (names, row) |name, want| {
        t.expectApproxEqRel(want, try at(r, k, name), 1e-3) catch |err| {
            std.debug.print("{s} at point {d}: want {e}, got {e}\n", .{ name, k, want, try at(r, k, name) });
            return err;
        };
    };
}

test "a VDMOS's @m1[id] is its channel's: the drain ammeter is id - idio; gm, gds and cds are central differences (#236)" {
    // Oracles: KCL at the drain, where the channel's current (vdmosask.c
    // VDMOScd), the body diode's (idio, flowing source to drain) and the
    // 1e-15 S d-s shunt meet: with the channel on, and with it off and the
    // body diode forward at V_DS = -0.7 V, where idio alone carries the
    // drain. Then central differences: level 1's square law is quadratic
    // in V_GS and linear in V_DS in saturation, and the 0.1 V subthreshold
    // smoothing adds e^-9 of curvature at V_GS - VTO = 0.9 V, under 1e-6 in
    // a 10 mV difference; cds = dqdio/dvd of the body diode, whose voltage
    // is -V_DS. Red before #236: `m1 has no variable 'idio'`, UnsupportedCard.
    const body = "vdmos opvars\nvd dd 0 dc 2\nvm dd d 0\nvg g 0 dc {d}\nm1 d g 0 vm1\n.model vm1 vdmos(kp=0.5 vto=2 lambda=0.01 is=1e-14 cjo=1n)\n" ++
        ".save i(vm) @m1[id] @m1[idio] @m1[gm] @m1[gds] @m1[vgs] @m1[vds] @m1[cds] @m1[qdio]\n{s}\n.end\n";
    const Case = struct { vg: f64, sweep: []const u8, by: enum { vg, vd, diode } };
    const cases = [_]Case{
        .{ .vg = 3, .sweep = ".dc vg 2.9 3.1 0.01", .by = .vg },
        .{ .vg = 3, .sweep = ".dc vd 1.9 2.1 0.01", .by = .vd },
        .{ .vg = 0, .sweep = ".dc vd -0.71 -0.69 0.0002", .by = .diode },
    };
    var buf: [512]u8 = undefined;
    for (cases) |c| {
        const p = try deck.solve(try std.fmt.bufPrint(&buf, body, .{ c.vg, c.sweep }));
        defer p.deinit();
        const r = try resultOf(p, .dc);
        try t.expect(r.npoints >= 3);
        for (0..r.npoints) |k| {
            const scale = r.data[k * r.varnames.len];
            const vds = if (c.by == .vg) 2 else scale;
            try t.expectApproxEqRel(try at(r, k, "i(vm)"), try at(r, k, "@m1[id]") - try at(r, k, "@m1[idio]") + 1e-15 * vds, 1e-6);
            try t.expectApproxEqAbs(if (c.by == .vg) scale else c.vg, try at(r, k, "@m1[vgs]"), 1e-12);
            try t.expectApproxEqAbs(vds, try at(r, k, "@m1[vds]"), 1e-12);
            if (k == 0 or k + 1 == r.npoints) continue;
            switch (c.by) {
                .vg => try t.expectApproxEqRel(try slope(r, k, "i(vm)"), try at(r, k, "@m1[gm]"), 1e-5),
                .vd => {
                    try t.expectApproxEqRel(try slope(r, k, "i(vm)"), try at(r, k, "@m1[gds]"), 1e-6);
                    try t.expectApproxEqRel(-(try slope(r, k, "@m1[qdio]")), try at(r, k, "@m1[cds]"), 1e-4);
                },
                .diode => try t.expect(try at(r, k, "@m1[idio]") > 1e-4),
            }
        }
    }
}

test "a VBIC's ic, ib and ie are its ammeters' currents, gm and gpi dIc and dIb over Vbe at fixed Vbc (#236)" {
    // Oracles: KCL at each terminal, every node voltage a source's (ngspice
    // 44.2 prints ic, ib and ie as the currents into c, b and e, which is
    // what each ammeter reads: opvar_ngspice.zig); then central
    // differences of the terminal currents with V_BC held by a source from
    // c to b and no series resistance, no avalanche and no parasitic
    // transistor, so every collector and base current but the transport
    // and B-E ones is fixed (vbicask.c:117-128). Red before #236: `q1 has
    // no variable 'ic'`, UnsupportedCard.
    const p = try deck.solve(
        \\vbic opvars
        \\vb b 0 dc 0.7
        \\vbc c b dc 2
        \\ve e 0 0
        \\q1 c b e 0 qv
        \\.model qv npn level=4 is=1e-16
        \\.save i(vb) i(vbc) i(ve) @q1[ic] @q1[ib] @q1[ie] @q1[gm] @q1[gpi] @q1[vbe] @q1[vbc]
        \\.dc vb 0.69 0.71 0.0002
        \\.end
        \\
    );
    defer p.deinit();
    const r = try resultOf(p, .dc);
    try t.expect(r.npoints >= 3);
    for (0..r.npoints) |k| {
        // KCL: Ic = -i(vbc), Ib = i(vbc) - i(vb), Ie = -i(ve).
        try t.expectApproxEqRel(-(try at(r, k, "i(vbc)")), try at(r, k, "@q1[ic]"), 1e-6);
        try t.expectApproxEqRel(try at(r, k, "i(vbc)") - try at(r, k, "i(vb)"), try at(r, k, "@q1[ib]"), 1e-6);
        try t.expectApproxEqRel(-(try at(r, k, "i(ve)")), try at(r, k, "@q1[ie]"), 1e-6);
        try t.expectApproxEqRel(r.data[k * r.varnames.len], try at(r, k, "@q1[vbe]"), 1e-12);
        try t.expectApproxEqRel(@as(f64, -2), try at(r, k, "@q1[vbc]"), 1e-12);
        if (k == 0 or k + 1 == r.npoints) continue;
        try t.expectApproxEqRel(-(try slope(r, k, "i(vbc)")), try at(r, k, "@q1[gm]"), 1e-4);
        try t.expectApproxEqRel(try slope(r, k, "i(vbc)") - try slope(r, k, "i(vb)"), try at(r, k, "@q1[gpi]"), 1e-4);
    }
}

test "a name no device of its kind has refuses the deck (#236)" {
    // Legal neighbour: the same cards saving a name each device answers.
    // ngspice's names that a model parameter would shadow refuse too: a
    // VDMOS's is (the channel's current alone, not the source terminal's,
    // vdmosask.c) and rs (the instance's, not the model's RS); and `temp`,
    // which ngspice answers with the instance's temperature and a model's
    // `temp` parameter with 27 unless the card gives one.
    const cards = "refused\nv1 d 0 0.5\nd1 d 0 dm\n.model dm d\nm1 d d 0 vm1\n.model vm1 vdmos\n.save {s}\n.op\n.end\n";
    var buf: [256]u8 = undefined;
    const legal = try deck.solve(try std.fmt.bufPrint(&buf, cards, .{"@d1[id] @m1[id] @v1[i]"}));
    legal.deinit();
    for ([_][]const u8{ "@d1[nonexistent]", "@m1[is]", "@m1[rs]", "@v1[nonexistent]", "@d1[temp]" }) |name| {
        try expectRefused(try std.fmt.bufPrint(&buf, cards, .{name}));
    }
}
