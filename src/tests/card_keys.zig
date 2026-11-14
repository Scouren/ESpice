//! A model card key or device node ESPice cannot honour fails with a coded
//! error instead of running with it dropped. Oracle: ngspice 44.2, which
//! takes every key and node named here (its model tables, generated into
//! src/frontend/Circuit/ngspice_model_keys.tsv, and inp2d.c / vdmos.c's thermal
//! nodes) and would answer differently with them. Each refusal ran with no
//! error before the fix. A polarity key or flag word binds where and as
//! ngspice 44.2 binds it, and fails where ngspice stops on it. A BJT's
//! subs places and orients its substrate junction as bjtload.c does,
//! checked against the junction's closed-form depletion capacitance.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

const head = ".options reltol=1e-6\nvb b 0 dc 0.7\nvc c 0 dc 2\n";

// The polarity decks, each probed at i(vd), the bias every number in their
// tests' comments was measured at.
const pol_mos = "polarity\nvd d 0 1\nvg g 0 1.5\nm1 d g 0 0 mm w=10u l=1u\n";
const pol_bjt = "polarity\nvd c 0 1\nvb b 0 0.7\nq1 c b 0 mm\n";
const pol_jfet = "polarity\nvd d 0 1\nvg g 0 0\nj1 d g 0 mm\n";
const pol_z = "polarity\nvd d 0 1\nvg g 0 0\nz1 d g 0 mm\n";
const pol_vdmos = "polarity\nvd d 0 1\nvg g 0 3\nm1 d g 0 mm\n";
const op_end = ".op\n.end\n";

// ---- private ----

/// Fails unless preparing `deck` fails with `err`.
fn expectRefused(err: anyerror, deck: []const u8) !void {
    const p = api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "card_keys.cir" } } }) catch |got| {
        if (got == err) return;
        std.debug.print("{s} instead of {s}:\n{s}", .{ @errorName(got), @errorName(err), deck });
        return error.TestUnexpectedError;
    };
    p.deinit();
    std.debug.print("ran instead of {s}:\n{s}", .{ @errorName(err), deck });
    return error.TestExpectedError;
}

/// i(vd) at `deck`'s operating point.
fn opCurrent(deck: []const u8) !f64 {
    const p = try decks.solve(deck);
    defer p.deinit();
    return decks.at(try decks.resultOf(p, .op), 0, "i(vd)");
}

/// Fails unless model cards `card` and `ref` under `body` draw the same
/// i(vd), bit for bit; returns it.
fn expectSameOp(comptime body: []const u8, comptime card: []const u8, comptime ref: []const u8) !f64 {
    const got = try opCurrent(body ++ ".model mm " ++ card ++ "\n" ++ op_end);
    const want = try opCurrent(body ++ ".model mm " ++ ref ++ "\n" ++ op_end);
    t.expectEqual(want, got) catch |err| {
        std.debug.print("`{s}` drew {e} A where `{s}` draws {e} A\n", .{ card, got, ref, want });
        return err;
    };
    return want;
}

test "a key ngspice models and ESPice does not is refused away from its inert value" {
    // bjt.c's quasi-saturation set (rco, quasimod) and ibe/ibc;
    // gummel_poon.va models none of them.
    inline for ([_][]const u8{
        "q1 c b 0 qn\n.model qn npn is=1e-16 bf=100 rco=10 quasimod=1\n",
        "q1 c b 0 qn\n.model qn npn ibe=1e-16 ibc=1e-16 bf=100\n",
    }) |body| try expectRefused(error.UnmodelledParameter, "card keys\n" ++ head ++ body ++ ".op\n.end\n");
}

test "a key ngspice models and ESPice does not runs at its inert value" {
    // ngspice 44.2 gives the same operating point with these keys at these
    // values as without them (2.010e-12 A through a diode at -2 V; ic =
    // 56.7035 uA at vbe = 0.7 V). gf180 np_3p3's tunnelling set binds:
    // diode.va models it (regression/diode_tunnelling.sp holds the numbers).
    inline for ([_][]const u8{
        "d1 0 b dm\n.model dm d level=3 is=1e-14 jtun=0 jtunsw=0 rth0=0\n",
        "d1 0 b dm\n.model dm d level=3 is=1e-14 jtun=1.1223e-5 jtunsw=6.4125e-12 ntun=10 xtitun=-25 keg=1\n",
        "q1 c b 0 qn\n.model qn npn is=1e-16 bf=100 quasimod=0\n",
    }) |body| {
        const deck = "card keys\n" ++ head ++ body ++ ".op\n.end\n";
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "card_keys.cir" } } });
        p.deinit();
    }
}

test "a VDMOS card's RQ without VQ, VQ without RQ, or both without RD changes nothing" {
    // ngspice applies quasi-saturation only with RQ and VQ both given
    // (vdmosset.c:217-218), and only through d', which RD = 0 never makes
    // (vdmosset.c:307-327). Oracle: the same card without them, at every
    // point; ngspice 44.2 gives each pair equal (to 1.7e-15). Red before:
    // vdmos.va ran RQ as a series RQ/(1 + |vds|/VQ) whenever RQ > 0, with
    // VQ defaulting to 1 and with or without RD.
    const p = try decks.solve(
        \\quasi-saturation keys
        \\.options reltol=1e-6 abstol=1e-15 vntol=1e-9
        \\vd d 0 0
        \\vg g 0 5
        \\va d d1 0
        \\vb d d2 0
        \\vc d d3 0
        \\ve d d4 0
        \\vf d d5 0
        \\m1 d1 g 0 base
        \\m2 d2 g 0 rqonly
        \\m3 d3 g 0 vqonly
        \\m4 d4 g 0 nord
        \\m5 d5 g 0 plain
        \\.model base vdmos vto=2 kp=1 lambda=0.01 rd=0.05
        \\.model rqonly vdmos vto=2 kp=1 lambda=0.01 rd=0.05 rq=0.5
        \\.model vqonly vdmos vto=2 kp=1 lambda=0.01 rd=0.05 vq=2
        \\.model nord vdmos vto=2 kp=1 lambda=0.01 rq=0.5 vq=2
        \\.model plain vdmos vto=2 kp=1 lambda=0.01
        \\.dc vd 0.5 20 0.5
        \\.end
        \\
    );
    defer p.deinit();
    const r = try decks.resultOf(p, .dc);
    const pairs = [_][2][]const u8{ .{ "i(vb)", "i(va)" }, .{ "i(vc)", "i(va)" }, .{ "i(ve)", "i(vf)" } };
    for (0..r.npoints) |k| for (pairs) |pair| {
        const want = try decks.at(r, k, pair[1]);
        const got = try decks.at(r, k, pair[0]);
        t.expectApproxEqRel(want, got, 1e-12) catch |err| {
            std.debug.print("{s} = {e} against {s} = {e} at vd = {d}\n", .{ pair[0], got, pair[1], want, r.data[k * r.varnames.len] });
            return err;
        };
    };
}

test "a key no ngspice table holds only warns, and the card runs" {
    // ngspice 44.2: "unrecognized parameter (bogus) - ignored", then it runs.
    const deck = "card keys\n" ++ head ++ "q1 c b 0 qn\n.model qn npn is=1e-16 bf=100 bogus=1\n.op\n.end\n";
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "card_keys.cir" } } });
    p.deinit();
}

test "a VDMOS's thermal node is refused, and a diode's builds" {
    // vdmos.c reads `M d g s tj tc`; vdmos.va has no thermal port, so the
    // node was dropped and the device ran isothermal.
    try expectRefused(error.UnsupportedSelfHeating, "card keys\n" ++ head ++
        "m1 c b 0 tj vm\nrtj tj 0 100\n.model vm vdmos vto=1 kp=1\n.op\n.end\n");
    // inp2d.c reads `D a k tj model`, dio.c:27 the `thermal` flag. The first
    // card is ngspice's self-heating condition (diodefs.h:31-33) and builds
    // diode_t; the others are off it, and ngspice runs them isothermal, as
    // `diode` does. src/tests/self_heating.zig holds their numbers. All four
    // were refused before diode_t.
    inline for ([_][]const u8{
        "d1 b 0 tj dm thermal\nrtj tj 0 100\n.model dm d is=1e-14 rth0=100\n",
        "d1 b 0 tj dm thermal\nrtj tj 0 100\n.model dm d is=1e-14\n",
        "d1 b 0 tj dm\nrtj tj 0 100\n.model dm d is=1e-14\n",
        "d1 b 0 dm thermal\n.model dm d is=1e-14\n",
    }) |body| {
        const deck = "card keys\n" ++ head ++ body ++ ".op\n.end\n";
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "card_keys.cir" } } });
        p.deinit();
    }
}

test "a VDMOS or B3SOI card is refused exactly where ngspice self-heats it" {
    // Oracle: ngspice 44.2. A VDMOS with thermal=1 and rthjc=10 on its card
    // fails its operating point under self-heating, where either key alone
    // gives i(vd) = -4.5 A as with neither (vdmosload.c:81). A B3SOI-FD at
    // vds = vgs = 2 V draws 2.10e-7 A with shmod=1 and rth0=1e4, on the
    // card or the instance, and 2.95e-4 A with either alone or with rth0=0
    // (b3soifdld.c:283). b3soifd.va and vdmos.va run isothermal, and ran
    // these cards with no error before the fix.
    inline for ([_][]const u8{
        "m1 c b 0 vm\n.model vm vdmos vto=1 kp=1 thermal=1 rthjc=10\n",
        "m1 c b 0 0 bs l=1u w=10u\n.model bs nmos level=55 shmod=1 rth0=1e4\n",
        "m1 c b 0 0 bs l=1u w=10u rth0=1e4\n.model bs nmos level=55 shmod=1\n",
        "m1 c b 0 0 bs l=1u w=10u\n.model bs nmos level=56 shmod=1 rth0=1e4\n",
    }) |body| try expectRefused(error.UnsupportedSelfHeating, "card keys\n" ++ head ++ body ++ ".op\n.end\n");
    inline for ([_][]const u8{
        // diode-soa-simple.sp's D2: rth0 with no thermal node heats nothing.
        "d1 b 0 dm\n.model dm d rs=200m bv=21 rth0=1e6 tnom=25\n",
        "d1 b 0 dm\n.model dm d is=1e-14 rth0=1e6 thermal=1\n",
        // ngspice-45's BJT reads rth0 only in its SOA check (bjtsoachk.c).
        "q1 c b 0 qn\n.model qn npn is=1e-15 bf=100 rth0=100\n",
        "m1 c b 0 vm\n.model vm vdmos vto=1 kp=1 thermal=1\n",
        "m1 c b 0 vm\n.model vm vdmos vto=1 kp=1 rthjc=10\n",
        "m1 c b 0 0 bs l=1u w=10u\n.model bs nmos level=55 shmod=1\n",
        "m1 c b 0 0 bs l=1u w=10u\n.model bs nmos level=55 rth0=1e4\n",
        "m1 c b 0 0 bs l=1u w=10u\n.model bs nmos level=55 shmod=1 rth0=0\n",
    }) |body| {
        const deck = "card keys\n" ++ head ++ body ++ ".op\n.end\n";
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "card_keys.cir" } } });
        p.deinit();
    }
}

test "a type key on an ngspice kind never sets polarity: dropped from MOS 1-9, BJT and JFET models, ignored elsewhere" {
    // ngspice-44.2: `nmos level=1 type=-1` and `npn type=1` drop the model
    // ("could not find a valid modelname", "Unable to find definition of
    // given model"); `nmos level=54 type=-1` warns and draws -1.1614e-4 A,
    // as without the key. Red before (prebuilt espice 2026-11-10): level 1
    // ran at -617.8 A and level 54 at -3.26e-8 A (SpiceRack P4-013).
    const mos = "type key\nvd d 0 1\nvg g 0 1\nm1 d g 0 0 mm w=1u l=1u\n";
    const end = ".op\n.end\n";
    try expectRefused(error.UnsupportedCard, mos ++ ".model mm nmos level=1 type=-1\n" ++ end);
    try expectRefused(error.UnsupportedCard, mos ++ ".model mm pmos level=1 type=1\n" ++ end);
    try expectRefused(error.UnsupportedCard, mos ++ ".model mm nmos level=3 type=-1\n" ++ end);
    try expectRefused(error.UnsupportedCard, "type key\nvc c 0 1\nvb b 0 0.7\nq1 c b 0 qq\n.model qq npn type=1\n" ++ end);
    var id: [2]f64 = undefined;
    for ([_][]const u8{ "", " type=-1" }, &id) |key, *out| {
        var buf: [256]u8 = undefined;
        const p = try decks.solve(try std.fmt.bufPrint(&buf, "{s}.model mm nmos level=54{s}\n{s}", .{ mos, key, end }));
        defer p.deinit();
        out.* = try decks.at(try decks.resultOf(p, .op), 0, "i(vd)");
    }
    try t.expectEqual(id[0], id[1]);
    try t.expectApproxEqRel(@as(f64, -1.16140e-4), id[0], 1e-4);
}

test "type as polarity on a BJT 4 or 8, JFET 2, MES, MESA, HFET or VDMOS card is refused: ngspice drops the model" {
    // ngspice-44.2 stops on each: "Unable to find definition of given
    // model" (BJT 4, 8), "no such parameter on this device or parameter is
    // missing" (JFET 2, MES 1, MESA 2, HFET 5 and 6), "could not find a
    // valid modelname" (VDMOS). Red before (prebuilt espice 2026-11-10):
    // each ran, at the i(vd) noted.
    inline for ([_][2][]const u8{
        .{ pol_bjt, "npn level=4 type=-1" }, // -5.6700e-5 A, as without the key
        .{ pol_bjt, "npn level=8 type=1" }, // -5.6675e-5 A
        .{ pol_jfet, "njf level=2 type=-1" }, // -2.8686e-4 A
        .{ pol_z, "nmf level=1 type=-1" }, // -6.0185e-3 A
        .{ pol_z, "nmf level=2 type=-1" }, // -2.1808e-3 A
        .{ pol_z, "nhfet level=5 type=-1" }, // -6.4688e-3 A; -9.1307e-7 A without, as ngspice
        .{ pol_z, "nhfet level=6 type=-1" }, // -9.1118e-7 A
        .{ pol_vdmos, "vdmos type=-1" }, // -2.5 A
    }) |row| try expectRefused(error.UnsupportedCard, row[0] ++ ".model mm " ++ row[1] ++ "\n" ++ op_end);
}

test "a polarity key ngspice's table lacks is dropped: the card draws what it draws without it" {
    // ngspice-44.2 warns "unrecognized parameter (<key>) - ignored" and
    // draws the last column with the key and without it. Red before
    // (prebuilt espice 2026-11-10): the key bound the polarity field, at the
    // i(vd) noted.
    inline for ([_]struct { []const u8, []const u8, []const u8, f64 }{
        .{ pol_jfet, "njf", " jtype=-1", -3.000000010e-4 }, // -617.83 A
        .{ pol_vdmos, "vdmos vto=1 kp=1", " ty=-1", -1.5 }, // -617.83 A
        .{ pol_z, "nmf level=1", " ztype=-1", -6.018518520e-3 }, // -617.84 A
        .{ pol_z, "nhfet level=6", " type_nfet=-1", -9.111774357e-7 }, // -9.6063e-8 A
    }) |row| {
        const id = try expectSameOp(row[0], row[1] ++ row[2], row[1]);
        try t.expectApproxEqRel(row[3], id, 1e-4);
    }
}

test "a polarity flag word on the card sets polarity in card order, where ngspice's table holds it" {
    // ngspice-44.2 reads the kind and each flag word after it as model
    // parameters, the last write winning, and draws the i(vd) noted for both
    // cards of each row. A flag its table lacks warns "unrecognized
    // parameter (<flag>) - ignored" and changes nothing. Red before
    // (prebuilt espice 2026-11-10): every flag was dropped, so the first four
    // rows ran at the kind's polarity, at the i(vd) noted.
    inline for ([_][3][]const u8{
        .{ pol_mos, "nmos level=1 pmos", "pmos level=1" }, // -617.83 A; before -2.0e-4 A
        .{ pol_mos, "nmos level=14 pmos", "pmos level=14" }, // -4.1007e-12 A; before -2.6385e-3 A
        .{ pol_bjt, "npn pnp", "pnp" }, // -2.2092e-11 A; before -5.6703e-5 A
        .{ pol_jfet, "njf pjf", "pjf" }, // -617.83 A; before -3.0e-4 A
        .{ pol_mos, "nmos level=1 nmos", "nmos level=1" }, // -2.0e-4 A
        .{ pol_mos, "pmos level=1 pmos", "pmos level=1" }, // -617.83 A
        .{ pol_mos, "nmos level=1 pmos nmos", "nmos level=1" }, // -2.0e-4 A
        .{ pol_mos, "pmos level=1 nmos pmos", "pmos level=1" }, // -617.83 A
        .{ pol_mos, "nmos level=1 npn", "nmos level=1" }, // warns; -2.0e-4 A
        .{ pol_vdmos, "vdmos vto=1 kp=1 pmos", "vdmos vto=1 kp=1" }, // warns; -1.5 A
    }) |row| _ = try expectSameOp(row[0], row[1], row[2]);
}

test "a polarity key on an instance of an ngspice kind is refused, as ngspice refuses it" {
    // ngspice-44.2 stops on each: "unknown parameter (type)". Red before
    // (prebuilt espice 2026-11-10): the key bound the model's polarity field
    // and ran at the i(vd) noted, the first as `pmos level=1` draws.
    const inst = "polarity\nvd d 0 1\nvg g 0 1.5\nm1 d g 0 0 mm w=10u l=1u ";
    inline for ([_][2][]const u8{
        .{ "type=-1", "nmos level=1" }, // -617.83 A
        .{ "type=-1", "nmos level=14" }, // -4.1162e-12 A
        .{ "TYPE=-1", "nmos level=1040" }, // -1.0e-12 A
    }) |row| try expectRefused(error.UnknownParameter, inst ++ row[0] ++ "\n.model mm " ++ row[1] ++ "\n" ++ op_end);
}

test "TYPE on a diode card binds juncap200's polarity: the diode kind sets none" {
    // Metamorphic: the P-type junction at +0.5 V draws minus the N-type one
    // at -0.5 V (prebuilt espice 2026-11-10: -7.9603e-10 A and +7.9603e-10
    // A). Dropping TYPE, as a rule for every ngspice kind did, draws the
    // N-type -3.2672e-10 A at +0.5 V. `d level=6` is HSPICE's JUNCAP2;
    // ngspice-44.2 has no such level, so it gives no number here.
    const p_type = try opCurrent("polarity\nvd a 0 0.5\nd1 a 0 mm\n.model mm d level=6 type=-1\n" ++ op_end);
    const n_type = try opCurrent("polarity\nvd a 0 -0.5\nd1 a 0 mm\n.model mm d level=6 type=1\n" ++ op_end);
    try t.expectApproxEqRel(-n_type, p_type, 1e-9);
}

test "subs puts a BJT's substrate junction on c' (vertical) or b' (lateral), in type*subs's sense" {
    // Analytic oracle. bjtsetup.c:40-46 makes an npn vertical and a pnp
    // lateral unless the card gives subs; bjtload.c:139, 185-187 runs the
    // junction from S to c' or b' in the frame of ttype = type*subs. Each
    // row holds S at -2*ttype V against c, b and e at 0, which reverses the
    // junction by 2 V, and drives S at AC. With no other capacitance on the
    // card, i(vs) = -j w cjs (1 + 2/vjs)^-mjs (bjtload.c:719-724): 0.5222
    // pF at vjs 0.75, mjs 0.5, tnom = temp. Red before: the lateral rows ran
    // in type's frame, forward by 2 V, at cjs (1 + 2 mjs/vjs) = 2.333 pF
    // (regression/bjt_instance_dtemp's lateral pnp, 2.85x ngspice's).
    const w: f64 = 2 * std.math.pi * 1e6;
    const want = -w * 1e-12 / @sqrt(@as(f64, 1.0 + 2.0 / 0.75));
    inline for ([_][2][]const u8{
        .{ "npn", "-2" }, // vertical, ttype +1
        .{ "npn subs=-1", "2" }, // lateral, ttype -1
        .{ "pnp", "-2" }, // lateral, ttype +1
        .{ "pnp subs=1", "2" }, // vertical, ttype -1
    }) |row| {
        const p = try decks.solve("substrate\n.options reltol=1e-6\nvc c 0 0\nvb b 0 0\nvs s 0 dc " ++ row[1] ++
            " ac 1\nq1 c b 0 s qx\n.model qx " ++ row[0] ++ " cjs=1p vjs=0.75 mjs=0.5\n.ac lin 1 1meg 1meg\n.end\n");
        defer p.deinit();
        const got = (try decks.atComplex(try decks.resultOf(p, .ac), 0, "i(vs)"))[1];
        t.expectApproxEqRel(want, got, 1e-9) catch |err| {
            std.debug.print("`{s}`: Im i(vs) = {e} A, want {e} A\n", .{ row[0], got, want });
            return err;
        };
    }
}
