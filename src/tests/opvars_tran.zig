//! ngspice's device operating-point variables at `.tran` points (#236): a
//! terminal current carries its charging current and a conductance its
//! integrator companion, as `post/opvars.zig` replays the integrator over
//! the recorded rows under the steps that reached them (`Result.steps`).
//! Oracles: KCL against a 0 V ammeter on every terminal at every accepted
//! point, and ngspice 44.2 goldens of a diode with RS and CJO, a
//! Gummel-Poon BJT, a VBIC and a capacitor at ngspice's own accuracy
//! (provenance on each). Each refusal is a run whose first row is not the
//! operating point the replay starts from, or a charge that no terminal
//! current shows alone.
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;
const at = deck.at;
const resultOf = deck.resultOf;
const expectRefused = deck.expectRefused;

/// KCL's tolerance, × an ammeter's peak, where the device is nonlinear:
/// the ammeter reads the last Newton linearization and the variable the
/// device at the accepted solution, as ngspice's do. The KCL decks run at
/// reltol = 1e-6, because 1e-3 parts them past any fixed share of the
/// peak. ngspice 44.2 on these decks at 1e-3: the diode's cathode 1.24e-2
/// of the peak from its id with RS = 10 (the internal node's last update
/// through gd + ag0·cd), a VDMOS's ig 8.5e-4, the Gummel-Poon's ib 2.1e-4
/// (88% of the branch row's own Newton gate, reltol·|i| + abstol). At
/// 1e-6: 2.3e-5, 4e-12 and 7.8e-8, the VBIC's ib 4.9e-7, the RS = 0
/// diode 1.7e-9.
const newton_tol = 1e-4;

/// KCL's tolerance, × an ammeter's peak, in a linear circuit: the ammeter
/// and the replay meet to rounding.
const linear_tol = 1e-9;

/// The diode KCL deck: an ammeter on each terminal, the cathode held at
/// 0.2 V so that `@d1[p]` reads its current too. Placeholders: the source
/// and RS.
const diode_kcl = "diode tran\nv1 a 0 {s}\nvma a k 0\nd1 k m dm\nvmk m n 0\nvn n 0 dc 0.2\n" ++
    ".model dm d is=1e-14 rs={s} cjo=10p tt=10n\n.save i(vma) i(vmk) v(k) v(m) @d1[id] @d1[c] @d1[p]\n.options reltol=1e-6\n.tran 0.5n 200n 0 0.5n\n.end\n";

/// A deck whose device has a 0 V ammeter on every terminal, the variables
/// that read their currents, and the signs that make each ammeter's
/// current the one into its terminal.
const Kcl = struct { text: []const u8, names: []const []const u8, ammeters: []const []const u8, signs: []const f64 };

/// A terminal: its ammeter, the sign that makes the ammeter's current the
/// one into the terminal, and the terminal's node voltage.
const Terminal = struct { amm: []const u8, sign: f64 = 1, v: []const u8 };

/// No series resistance: each junction charge sits on the terminals, so
/// every charging current comes from the replay (bjtload.c:808-818,
/// vbicload.c:869-899, vdmosask.c:131-146).
const terminal_decks = [_]Kcl{
    .{
        .text = "gummel-poon tran\nvcc vc 0 dc 3\nvmc vc c 0\nvb bb 0 sin(0.7 0.1 10meg)\nvmb bb b 0\nq1 c b e qn\nvme e 0 0\n" ++
            ".model qn npn is=1e-15 bf=100 br=2 vaf=50 cje=1p cjc=0.5p tf=0.1n tr=5n\n.save i(vmc) i(vmb) i(vme) @q1[ic] @q1[ib] @q1[ie]\n.options reltol=1e-6\n.tran 0.5n 200n 0 0.5n\n.end\n",
        .names = &.{ "@q1[ic]", "@q1[ib]", "@q1[ie]" },
        .ammeters = &.{ "i(vmc)", "i(vmb)", "i(vme)" },
        .signs = &.{ 1, 1, -1 },
    },
    .{
        .text = "vbic tran\nvcc vc 0 dc 3\nvmc vc c 0\nvb bb 0 sin(0.75 0.05 10meg)\nvmb bb b 0\nq1 c b e 0 qv\nvme e 0 0\n" ++
            ".model qv npn level=4 is=1e-16 cje=1p cjc=0.5p tf=0.1n tr=5n\n.save i(vmc) i(vmb) i(vme) @q1[ic] @q1[ib] @q1[ie]\n.options reltol=1e-6\n.tran 0.5n 200n 0 0.5n\n.end\n",
        .names = &.{ "@q1[ic]", "@q1[ib]", "@q1[ie]" },
        .ammeters = &.{ "i(vmc)", "i(vmb)", "i(vme)" },
        .signs = &.{ 1, 1, -1 },
    },
    .{
        .text = "vdmos tran\nvd dd 0 dc 2\nvmd dd d 0\nvg gg 0 sin(3 1 10meg)\nvmg gg g 0\nm1 d g s vm1\nvms s 0 0\n" ++
            ".model vm1 vdmos(kp=0.5 vto=2 lambda=0.01 is=1e-14 cjo=1n cgdmax=1n cgdmin=0.1n cgs=2n)\n.save i(vmg) @m1[ig]\n.options reltol=1e-6\n.tran 0.5n 200n 0 0.5n\n.end\n",
        .names = &.{"@m1[ig]"},
        .ammeters = &.{"i(vmg)"},
        .signs = &.{1},
    },
    // P-channel: ngspice's frame is type × the gate's current, so ig is
    // minus its ammeter (ngspice 44.2 on this deck: |i(vmg) + @m1[ig]| <=
    // 1.55e-4 A at every point, peak 0.183 A). Red before the bound
    // polarity labelled it: the card's kind, `vdmos`, read as N.
    .{
        .text = "vdmos pchan tran\nvd dd 0 dc -2\nvmd dd d 0\nvg gg 0 sin(-3 1 10meg)\nvmg gg g 0\nm1 d g s vm1\nvms s 0 0\n" ++
            ".model vm1 vdmos pchan kp=0.5 vto=-2 lambda=0.01 is=1e-14 cjo=1n cgdmax=1n cgdmin=0.1n cgs=2n\n.save i(vmg) @m1[ig]\n.options reltol=1e-6\n.tran 0.5n 200n 0 0.5n\n.end\n",
        .names = &.{"@m1[ig]"},
        .ammeters = &.{"i(vmg)"},
        .signs = &.{-1},
    },
};

/// ngspice 44.2's runs of the golden decks below: `ngspice -b` of each
/// with `.control`, `set numdgt=12`, `set width=400`, `run`, `print <its
/// .save vectors> > <name>.txt`, `.endc` inserted before `.end`; the deck
/// hashes are sha256 of those files. Each row is ngspice's printed row
/// index and values. Rows 0-4 are the two backward-Euler starting steps and
/// the trapezoid's first two; at each row ngspice's last Newton update
/// (its operating-point current against its own ammeter, over the
/// conductance) is under 1e-4 vt, which bounds how far its conductances,
/// evaluated before that update, sit from the solution's.
const dio_deck =
    \\diode tran probes
    \\v1 a 0 sin(0 0.8 10meg)
    \\vm a k 0
    \\d1 k 0 dm
    \\.model dm d is=1e-14 rs=10 cjo=10p tt=10n
    \\.save i(vm) @d1[id] @d1[c] @d1[gd] @d1[cd] @d1[p] v(a) v(k)
    \\.tran 0.5n 200n 0 0.5n
    \\.end
    \\
;

/// dio.txt, deck sha256 7737c43c18769f16b7165704dbee286aa19c58fd4cf8624215e0cd4f824d3710:
/// time, i(vm), v(k), @d1[id], @d1[gd], @d1[p]. Rows 50-84 are forward
/// conduction and the reverse recovery.
const dio_golden = [_]struct { u16, [6]f64 }{
    .{ 0, .{ 0.000000000000e+00, -2.29469524326e-31, 0.000000000000e+00, 2.294695243261e-42, 1.386624089968e-12, 5.265626259499e-72 } },
    .{ 1, .{ 5.000000000000e-12, 2.393594363520e-05, 2.513274081530e-04, 2.393601525198e-05, 2.000011970854e+00, 6.015793816995e-09 } },
    .{ 2, .{ 1.000000000000e-11, 4.673210129235e-05, 5.026547915010e-04, 4.673216625053e-05, 2.000035337491e+00, 2.349017763942e-08 } },
    .{ 3, .{ 2.000000000000e-11, 9.015350337263e-05, 1.005309384562e-03, 9.015373904346e-05, 2.000103785206e+00, 9.063261237980e-08 } },
    .{ 4, .{ 4.000000000000e-11, 1.651559208951e-04, 2.010617181603e-03, 1.651594271548e-04, 1.000179578740e+00, 3.320781728595e-07 } },
    .{ 25, .{ 8.695433687628e-09, 5.603706804764e-04, 4.156577764831e-01, 5.603743396938e-04, 5.219963597654e-02, 2.329239725406e-04 } },
    .{ 50, .{ 2.119543368763e-08, 9.291848439407e-03, 7.772510712228e-01, 9.298259024088e-03, 4.971700783660e+00, 7.227677859748e-03 } },
    .{ 60, .{ 2.619543368763e-08, 9.713990700406e-03, 7.977443769780e-01, 9.717288529858e-03, 9.268851471065e+00, 7.752232743769e-03 } },
    .{ 75, .{ 3.369543368763e-08, -1.40007742919e-03, 6.835412298092e-01, -1.38913465123e-03, 8.241288898510e+00, -9.49682817790e-04 } },
    .{ 84, .{ 3.819543368763e-08, -1.09882328121e-02, 5.404355040908e-01, -1.09848177277e-02, 1.381737503002e+00, -5.93696064680e-03 } },
    .{ 100, .{ 4.619543368763e-08, -5.45194329674e-04, 1.894222064146e-01, -5.45193691937e-04, 4.457880221559e-02, -1.03271795527e-04 } },
    .{ 150, .{ 7.119543368763e-08, -9.10542067051e-05, -7.77251071223e-01, -9.10517649994e-05, 3.001213418415e-02, 7.077007965933e-05 } },
    .{ 200, .{ 9.619543368763e-08, 4.455042261991e-04, -1.89422206415e-01, 4.455045733531e-04, 3.660834990226e-02, -8.43884577057e-05 } },
};

const gp_deck =
    \\gummel-poon tran probes
    \\vcc vc 0 dc 3
    \\vmc vc c 0
    \\vb bb 0 sin(0.7 0.1 10meg)
    \\vmb bb b 0
    \\q1 c b e qn
    \\vme e 0 0
    \\.model qn npn is=1e-15 bf=100 br=2 vaf=50 rb=50 rc=5 re=1 cje=1p cjc=0.5p tf=0.1n tr=5n xcjc=1
    \\.save i(vmc) i(vmb) i(vme) @q1[ic] @q1[ib] @q1[ie] @q1[gpi] @q1[gmu] @q1[cpi] @q1[cmu]
    \\.tran 0.5n 200n 0 0.5n
    \\.end
    \\
;

/// bjt_1.txt, deck sha256 aaf1c18f07589471856b8573f7dc3db26894495d62f321651ede6af9fc47d265:
/// time, i(vmc), i(vmb), i(vme), @q1[ic], @q1[ib], @q1[ie], @q1[gpi], @q1[gmu].
const gp_golden = [_]struct { u16, [9]f64 }{
    .{ 0, .{ 0.000000000000e+00, 5.738343082734e-04, 5.486258201567e-06, 5.793205634777e-04, 5.738343052761e-04, 5.486258201570e-06, -5.79320566475e-04, 2.121120212636e-04, 1.000000001252e-12 } },
    .{ 1, .{ 5.000000000000e-12, 5.737859247680e-04, 6.089416639030e-06, 5.798753384100e-04, 5.737859219792e-04, 6.089420935047e-06, -5.79875345911e-04, 7.670556461470e-01, 6.296124396374e-02 } },
    .{ 2, .{ 1.000000000000e-11, 5.737639422925e-04, 6.678358642785e-06, 5.804422979382e-04, 5.737639395022e-04, 6.678362882976e-06, -5.80442305382e-04, 7.670800024789e-01, 6.296125663780e-02 } },
    .{ 3, .{ 2.000000000000e-11, 5.737577131855e-04, 7.828635328989e-06, 5.815863455176e-04, 5.737577109845e-04, 7.828651642368e-06, -5.81586365624e-04, 7.671525314416e-01, 6.296129268359e-02 } },
    .{ 4, .{ 4.000000000000e-11, 5.739373758226e-04, 9.971493484523e-06, 5.839088663099e-04, 5.739373991098e-04, 9.971761457100e-06, -5.83909163564e-04, 3.838232068517e-01, 3.148071254177e-02 } },
    .{ 25, .{ 9.140000000000e-09, 3.477781696034e-03, 9.893781358641e-05, 3.576719506638e-03, 3.477793697789e-03, 9.894274058448e-05, -3.57673644136e-03, 6.177778190709e-02, 1.268099597931e-03 } },
    .{ 50, .{ 2.164000000000e-08, 1.185343522200e-02, 1.644112334622e-04, 1.201784645252e-02, 1.185346155513e-02, 1.644220306152e-04, -1.20178835887e-02, 1.945361113110e-01, 1.279825875357e-03 } },
    .{ 75, .{ 3.414000000000e-08, 1.000697192322e-02, 1.579274508508e-05, 1.002276466536e-02, 1.000701412846e-02, 1.581004974834e-05, -1.00228241812e-02, 1.652235500564e-01, 1.277559647416e-03 } },
    .{ 100, .{ 4.664000000000e-08, 1.346502268252e-03, -3.06676208738e-05, 1.315834644385e-03, 1.346503789691e-03, -3.06669927651e-05, -1.31583679992e-03, 2.784197942346e-02, 1.262876711580e-03 } },
    .{ 125, .{ 5.914000000000e-08, 7.570796627676e-05, -1.07330456416e-05, 6.497491763542e-05, 7.570810296797e-05, -1.07329825205e-05, -6.49751234471e-05, 7.399901546772e-03, 1.251680189894e-03 } },
    .{ 150, .{ 7.164000000000e-08, 1.403612720108e-05, -2.40438001276e-06, 1.163174418843e-05, 1.403621633767e-05, -2.40432119443e-06, -1.16318981432e-05, 6.249465382088e-03, 1.245854855335e-03 } },
    .{ 200, .{ 9.664000000000e-08, 2.494289805485e-04, 1.970993699068e-05, 2.691389145403e-04, 2.494290262086e-04, 1.970995761106e-05, -2.69138986818e-04, 1.034884242709e-02, 1.256065200116e-03 } },
};

const cap_deck =
    \\capacitor tran probes
    \\v1 a 0 sin(0 1 10meg)
    \\r1 a b 100
    \\vm b c 0
    \\c1 c 0 1n
    \\.save i(vm) v(c) @c1[i] @c1[p]
    \\.tran 0.5n 200n 0 0.5n
    \\.end
    \\
;

/// cap.txt, deck sha256 26eceb2f8656343d66168ee8c338c3d89a88fbf466827e8c2e39a075fe61c31f:
/// time, i(vm), v(c), @c1[i], @c1[p].
const cap_golden = [_]struct { u16, [5]f64 }{
    .{ 0, .{ 0.000000000000e+00, 0.000000000000e+00, 0.000000000000e+00, 0.000000000000e+00, 0.000000000000e+00 } },
    .{ 1, .{ 5.000000000000e-12, 3.141435530136e-06, 1.570717765066e-08, 3.141435530132e-06, 4.934308594987e-14 } },
    .{ 2, .{ 1.000000000000e-11, 6.282713686302e-06, 4.712074608206e-08, 6.282713686280e-06, 2.960461563175e-13 } },
    .{ 3, .{ 2.000000000000e-11, 1.256495371619e-05, 1.413590830944e-07, 1.256495371618e-05, 1.776170336443e-12 } },
    .{ 4, .{ 4.000000000000e-11, 2.512753193064e-05, 5.182839395621e-07, 2.512753193059e-05, 1.302319624046e-11 } },
    .{ 25, .{ 9.140000000000e-09, 5.184734885030e-03, 2.475957664831e-02, 5.184734885030e-03, 1.283718407871e-04 } },
    .{ 50, .{ 2.164000000000e-08, 8.611612672037e-03, 1.166366013085e-01, 8.611612672036e-03, 1.004429233851e-03 } },
    .{ 75, .{ 3.414000000000e-08, 6.242080898983e-03, 2.153738518598e-01, 6.242080898983e-03, 1.344381006834e-03 } },
    .{ 100, .{ 4.664000000000e-08, -4.47476727436e-04, 2.542979729892e-01, -4.47476727435e-04, -1.13792424747e-04 } },
    .{ 125, .{ 5.914000000000e-08, -7.46044467470e-03, 2.028114023188e-01, -7.46044467470e-03, -1.51306324640e-03 } },
    .{ 150, .{ 7.164000000000e-08, -1.06199189896e-02, 8.419403044832e-02, -1.06199189896e-02, -8.94133782769e-04 } },
    .{ 200, .{ 9.664000000000e-08, -1.11659299071e-03, -9.78910011746e-02, -1.11659299071e-03, 1.093044057652e-04 } },
};

const vbic_deck =
    \\vbic tran probes
    \\vcc vc 0 dc 3
    \\vmc vc c 0
    \\vb bb 0 sin(0.75 0.05 10meg)
    \\vmb bb b 0
    \\q1 c b e 0 qv
    \\vme e 0 0
    \\.model qv npn level=4 is=1e-16 cje=1p cjc=0.5p tf=0.1n tr=5n rbi=20 rcx=5 re=1
    \\.save i(vmc) i(vmb) i(vme) @q1[ic] @q1[ib] @q1[ie] @q1[gpi] @q1[gmu] @q1[cbe] @q1[cbc]
    \\.tran 0.5n 200n 0 0.5n
    \\.end
    \\
;

/// vbic.txt, deck sha256 475116fbc88aa7740c65f96ac5b30c93adbb4765bf32340670fbac9165108218:
/// time, @q1[gpi], @q1[gmu].
const vbic_golden = [_]struct { u16, [3]f64 }{
    .{ 0, .{ 0.000000000000e+00, 1.487977194200e-04, 1.000000000000e-12 } },
    .{ 1, .{ 5.000000000000e-12, 8.655759915810e-01, 6.330097143844e-02 } },
    .{ 2, .{ 1.000000000000e-11, 8.655956603346e-01, 6.330098504666e-02 } },
    .{ 3, .{ 2.000000000000e-11, 8.656535026478e-01, 6.330102279847e-02 } },
    .{ 4, .{ 4.000000000000e-11, 4.330094332231e-01, 3.165057714215e-02 } },
    .{ 25, .{ 9.140000000000e-09, 2.897802574924e-02, 1.270233096206e-03 } },
    .{ 50, .{ 2.164000000000e-08, 4.976880208931e-02, 1.274232284182e-03 } },
    .{ 75, .{ 3.414000000000e-08, 4.215445890573e-02, 1.272991065034e-03 } },
    .{ 100, .{ 4.664000000000e-08, 2.094244436265e-02, 1.267663712882e-03 } },
    .{ 150, .{ 7.164000000000e-08, 1.047026587462e-02, 1.259067311818e-03 } },
    .{ 200, .{ 9.664000000000e-08, 1.501128104008e-02, 1.264440046899e-03 } },
};

// ---- private ----

/// The largest |column `name`| over `r`'s rows.
fn peak(r: api.Result, name: []const u8) !f64 {
    var m: f64 = 0;
    for (0..r.npoints) |k| m = @max(m, @abs(try at(r, k, name)));
    return m;
}

/// Expects column `name` of `r` at every row within `tol` of `sign` ×
/// column `amm`.
fn expectColumn(r: api.Result, name: []const u8, amm: []const u8, sign: f64, tol: f64) !void {
    for (0..r.npoints) |k| {
        const got = try at(r, k, name);
        const want = sign * try at(r, k, amm);
        if (@abs(got - want) <= tol) continue;
        std.debug.print("{s} at row {d}: {e} against {d} x {s} = {e}, tolerance {e}\n", .{ name, k, got, sign, amm, want, tol });
        return error.TestExpectedApproxEqAbs;
    }
}

/// Expects column `name` of `r` at every row to be the power into `terms`,
/// the sum of each one's current × its voltage, within `tol` × the sum of
/// their |voltages|.
fn expectPower(r: api.Result, name: []const u8, terms: []const Terminal, tol: f64) !void {
    for (0..r.npoints) |k| {
        var want: f64 = 0;
        var volts: f64 = 0;
        for (terms) |term| {
            const v = try at(r, k, term.v);
            const i = term.sign * try at(r, k, term.amm);
            want += i * v;
            volts += @abs(v);
        }
        const got = try at(r, k, name);
        if (@abs(got - want) <= tol * volts) continue;
        std.debug.print("{s} at row {d}: {e} against the terminals' {e}, tolerance {e}\n", .{ name, k, got, want, tol * volts });
        return error.TestExpectedApproxEqAbs;
    }
}

/// Expects the diode KCL deck's `@d1[id]` and `@d1[c]` to be the anode
/// ammeter's current and `@d1[p]` both terminals' power at every row, and
/// the reverse recovery to pull id below -0.1 mA, which no static current
/// below -IS can.
fn expectDiodeKcl(r: api.Result) !void {
    const pk = try peak(r, "i(vma)");
    try expectColumn(r, "@d1[id]", "i(vma)", 1, newton_tol * pk);
    try expectPower(r, "@d1[p]", &.{ .{ .amm = "i(vma)", .v = "v(k)" }, .{ .amm = "i(vmk)", .sign = -1, .v = "v(m)" } }, newton_tol * pk);
    var lowest: f64 = 0;
    for (0..r.npoints) |k| {
        try t.expectEqual(try at(r, k, "@d1[id]"), try at(r, k, "@d1[c]"));
        lowest = @min(lowest, try at(r, k, "@d1[id]"));
    }
    try t.expect(lowest < -1e-4);
}

/// Expects row `k` of `r` at ngspice's time `t_ng` for its row `k`, so the
/// two runs' rows pair by index.
fn expectTime(r: api.Result, k: usize, t_ng: f64) !void {
    try t.expect(k < r.npoints);
    try t.expect(@abs(r.data[k * r.varnames.len] - t_ng) <= 1e-9 * t_ng);
}

/// Expects column `name` of `r` at row `k` within ngspice's own accuracy
/// of its value `ng` there: twice the gap between `ng` and `self_ng`, the
/// same quantity as ngspice's ammeters read it, plus `floor`.
fn expectNear(r: api.Result, k: usize, name: []const u8, ng: f64, self_ng: f64, floor: f64) !void {
    const got = try at(r, k, name);
    const tol = 2 * @abs(ng - self_ng) + floor;
    if (@abs(got - ng) <= tol) return;
    std.debug.print("{s} at row {d}: {e} against ngspice's {e}, tolerance {e}\n", .{ name, k, got, ng, tol });
    return error.TestExpectedApproxEqAbs;
}

/// The highest-order method a step of `r` took.
fn topMethod(r: api.Result) api.requests.Method {
    var top: api.requests.Method = .backward_euler;
    for (r.steps) |s| if (@backingInt(s.method) > @backingInt(top)) {
        top = s.method;
    };
    return top;
}

test "in a .tran a diode's id, c and p are its ammeters' at every point, with RS or without, across breakpoints (#236)" {
    // Oracle: KCL at both terminals at every accepted point. ngspice's id
    // adds the junction's charging current (dioload.c:703-707), which the
    // anode carries through RS or, without it, as the junction's own node.
    // The pulse's edges are breakpoints, where the integrator drops to
    // backward Euler mid-run and climbs back. Red before the replay:
    // `@d1[id]` at RS = 0 in a .tran, UnsupportedCard.
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "sin(0.2 0.8 10meg)", "pulse(0.2 0.9 0 1n 1n 5n 20n)" }, 0..) |source, pulse| {
        for ([_][]const u8{ "0", "10" }) |rs| {
            const p = try deck.solve(try std.fmt.bufPrint(&buf, diode_kcl, .{ source, rs }));
            defer p.deinit();
            const r = try resultOf(p, .tran);
            try expectDiodeKcl(r);
            try t.expectEqual(r.npoints, r.steps.len);
            if (pulse == 1) try t.expect(for (r.steps[3..]) |s| {
                if (s.method == .backward_euler) break true;
            } else false);
        }
    }
}

test "on CUDA lanes a diode's id and p are its ammeters' at every point, as on the CPU (#236)" {
    // Oracle: the KCL above under the device's own step control: each
    // lane's drain records the step that reached each row (gpu_step.zig,
    // `StepReport.method`), and the host replays over the rows it read
    // back. Two .step points make two lanes.
    const gpu_lanes = @import("analysis").gpu_lanes;
    if (comptime !gpu_lanes.available) return error.SkipZigTest;
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, diode_kcl, .{ "sin(0.2 {amp} 10meg)", "0" });
    const stepped = try std.mem.replaceOwned(u8, t.allocator, body, "diode tran\n", "diode lanes\n.param amp=0.8\n.step param amp list 0.8 0.7\n");
    defer t.allocator.free(stepped);
    const before = gpu_lanes.test_access.admitted.load(.monotonic);
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = stepped, .origin = "opvars_tran.cir" } }, .backend = .{ .backend = .cuda, .lanes = true } });
    defer p.deinit();
    try p.run_all();
    try t.expect(gpu_lanes.test_access.admitted.load(.monotonic) - before >= 2);
    var runs: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const info = try p.query_info(id);
        if (!info.requested or info.kind != .tran) continue;
        try expectDiodeKcl(try p.result(id));
        runs += 1;
    }
    try t.expectEqual(@as(usize, 2), runs);
}

test "in a .tran a capacitor's i and p are its ammeters' at every point under trapezoid, gear-2 and gear-4 (#236)" {
    // Oracle: KCL at both plates at every accepted point, the lower one
    // held at 0.5 V so p reads both. Gear-3..6 take no deck spelling; the
    // API appends them, and gear-4's run must climb past order 2 for the
    // replay's history term (integrator.gearHistory) to be in play. Red
    // before the replay: `@c1[i]` in a .tran, UnsupportedCard.
    const text = "capacitor tran\nv1 a 0 sin(0 1 10meg)\nr1 a b 100\nvma b c 0\nc1 c d 1n\nvmd d e 0\nve e 0 dc 0.5\n" ++
        ".save i(vma) i(vmd) v(c) v(d) @c1[i] @c1[p]\n.tran 0.5n 200n 0 0.5n\n.end\n";
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = text, .origin = "opvars_tran.cir" } } });
    defer p.deinit();
    var ids: [2]api.QueryId = undefined;
    _ = try p.append_queries(&.{
        .{ .tran = .{ .t_stop = 200e-9, .dt_init = 0.5e-9, .dt_max = 0.5e-9, .method = .gear_2 } },
        .{ .tran = .{ .t_stop = 200e-9, .dt_init = 0.5e-9, .dt_max = 0.5e-9, .method = .gear_4 } },
    }, &ids);
    try p.run_all();
    const runs = [_]struct { api.Result, api.requests.Method }{
        .{ try resultOf(p, .tran), .trapezoidal },
        .{ try p.result(ids[0]), .gear_2 },
        .{ try p.result(ids[1]), .gear_4 },
    };
    for (runs) |run| {
        const r, const method = run;
        try t.expectEqual(r.npoints, r.steps.len);
        try t.expectEqual(method, topMethod(r));
        const pk = try peak(r, "i(vma)");
        try expectColumn(r, "@c1[i]", "i(vma)", 1, linear_tol * pk);
        try expectPower(r, "@c1[p]", &.{ .{ .amm = "i(vma)", .v = "v(c)" }, .{ .amm = "i(vmd)", .sign = -1, .v = "v(d)" } }, linear_tol * pk);
    }
}

test "in a .tran a BJT's and a VBIC's ic, ib and ie, and an N or P VDMOS's ig, are their ammeters' at every point (#236)" {
    // Oracle: KCL at each terminal at every accepted point, each against
    // its own ammeter's peak. Red before the replay: `@q1[ic]` in a .tran,
    // UnsupportedCard.
    for (terminal_decks) |d| {
        const p = try deck.solve(d.text);
        defer p.deinit();
        const r = try resultOf(p, .tran);
        for (d.names, d.ammeters, d.signs) |name, amm, sign| try expectColumn(r, name, amm, sign, newton_tol * try peak(r, amm));
    }
}

test "a diode with RS and CJO reads ngspice 44.2's id, gd and p at .tran points (#236)" {
    // Oracle: dio_golden at ngspice's own accuracy. Its id and p come from
    // the last Newton iterate, up to 0.8% off its own ammeter, while
    // ESPice's ammeter meets ngspice's to 5e-12 of the peak on this grid:
    // a current's tolerance is twice ngspice's own gap plus 1e-6 of the
    // peak. gd adds ag0 × cd (dioload.c:707), to 1e-3. Red before the
    // replay: `@d1[gd]` in a .tran, UnsupportedCard.
    const p = try deck.solve(dio_deck);
    defer p.deinit();
    const r = try resultOf(p, .tran);
    const pk = try peak(r, "i(vm)");
    const pk_v = try peak(r, "v(k)");
    for (dio_golden) |row| {
        const k, const ng = row;
        try expectTime(r, k, ng[0]);
        try expectNear(r, k, "i(vm)", ng[1], ng[1], 1e-6 * pk);
        try expectNear(r, k, "@d1[id]", ng[3], ng[1], 1e-6 * pk);
        try expectNear(r, k, "@d1[c]", ng[3], ng[1], 1e-6 * pk);
        try expectNear(r, k, "@d1[gd]", ng[4], ng[4], 1e-3 * ng[4]);
        try expectNear(r, k, "@d1[p]", ng[5], ng[1] * ng[2], 1e-6 * pk * pk_v);
    }
}

test "a Gummel-Poon BJT reads ngspice 44.2's ic, ib, ie, gpi and gmu at .tran points (#236)" {
    // Oracle: gp_golden at ngspice's own accuracy, as the diode's above.
    // gpi and gmu add ag0 × cpi and cmu (bjtload.c:808-818), to 1e-3. Red
    // before the replay: `@q1[ic]` in a .tran, UnsupportedCard.
    const p = try deck.solve(gp_deck);
    defer p.deinit();
    const r = try resultOf(p, .tran);
    const ammeters = [_][]const u8{ "i(vmc)", "i(vmb)", "i(vme)" };
    var pks: [3]f64 = undefined;
    for (&pks, ammeters) |*pk, amm| pk.* = try peak(r, amm);
    for (gp_golden) |row| {
        const k, const ng = row;
        try expectTime(r, k, ng[0]);
        const into = [_]f64{ ng[1], ng[2], -ng[3] };
        for (ammeters, ng[1..4], pks) |amm, v, pk| try expectNear(r, k, amm, v, v, 1e-6 * pk);
        for ([_][]const u8{ "@q1[ic]", "@q1[ib]", "@q1[ie]" }, ng[4..7], into, pks) |name, v, self, pk| try expectNear(r, k, name, v, self, 1e-6 * pk);
        try expectNear(r, k, "@q1[gpi]", ng[7], ng[7], 1e-3 * ng[7]);
        try expectNear(r, k, "@q1[gmu]", ng[8], ng[8], 1e-3 * ng[8]);
    }
}

test "a capacitor reads ngspice 44.2's i and p at .tran points (#236)" {
    // Oracle: cap_golden; the circuit is linear, so ngspice's i meets its
    // own ammeter to 1e-12 of the peak, and the tolerance is 1e-6 of it.
    // Red before the replay: `@c1[i]` in a .tran, UnsupportedCard.
    const p = try deck.solve(cap_deck);
    defer p.deinit();
    const r = try resultOf(p, .tran);
    const pk = try peak(r, "i(vm)");
    const pk_v = try peak(r, "v(c)");
    for (cap_golden) |row| {
        const k, const ng = row;
        try expectTime(r, k, ng[0]);
        try expectNear(r, k, "i(vm)", ng[1], ng[1], 1e-6 * pk);
        try expectNear(r, k, "@c1[i]", ng[3], ng[1], 1e-6 * pk);
        try expectNear(r, k, "@c1[p]", ng[4], ng[1] * ng[2], 1e-6 * pk * pk_v);
    }
}

test "a VBIC reads ngspice 44.2's gpi and gmu at .tran points (#236)" {
    // Oracle: vbic_golden, to 1e-3: gpi and gmu add ag0 × cbe and cbc
    // (vbicload.c:871, :882). Its currents are KCL's (above): ESPice's VBIC
    // ammeters sit 1e-4 of ib's peak from ngspice's, a model difference no
    // golden of them could see past. Red before the replay: `@q1[gpi]` in
    // a .tran, UnsupportedCard.
    const p = try deck.solve(vbic_deck);
    defer p.deinit();
    const r = try resultOf(p, .tran);
    for (vbic_golden) |row| {
        const k, const ng = row;
        try expectTime(r, k, ng[0]);
        try expectNear(r, k, "@q1[gpi]", ng[1], ng[1], 1e-3 * ng[1]);
        try expectNear(r, k, "@q1[gmu]", ng[2], ng[2], 1e-3 * ng[2]);
    }
}

test "a .tran whose first row is not its operating point refuses charging currents and companions; the rest read on (#236)" {
    // The replay starts from the run's first row, the operating point
    // `Sim.init` seeds its history with: a TSTART > 0 run records no such
    // row, and a uic run starts from the initial conditions instead, which
    // no oracle here checks (prepared_opvars.zig `Trans`). Legal
    // neighbours first: the same cards from t = 0, and qd, which no step
    // changes, past TSTART and under uic. Red before the replay: the first
    // neighbour, UnsupportedCard.
    const cards = "start\nv1 a 0 sin(0 0.8 10meg)\nd1 a 0 dm\n.model dm d is=1e-14 cjo=10p tt=10n\n.save {s}\n.tran 0.5n 20n {s}\n.end\n";
    var buf: [256]u8 = undefined;
    for ([_][2][]const u8{ .{ "@d1[id] @d1[gd] @d1[p]", "" }, .{ "@d1[qd]", "1n" }, .{ "@d1[qd]", "uic" } }) |legal| {
        const p = try deck.solve(try std.fmt.bufPrint(&buf, cards, .{ legal[0], legal[1] }));
        p.deinit();
    }
    for ([_][]const u8{ "@d1[id]", "@d1[gd]", "@d1[p]" }) |name| for ([_][]const u8{ "1n", "uic" }) |tail| {
        try expectRefused(try std.fmt.bufPrint(&buf, cards, .{ name, tail }));
    };
}

test "a charge no terminal current shows alone refuses the names that would carry it in a .tran (#236)" {
    // ngspice 44.2 prints a Gummel-Poon's ib 12% off its ammeter at xcjc =
    // 0.5, the B-C charge split onto the outer base; cjs and iss charge the
    // substrate, a VBIC's cjep the extrinsic base, and a VDMOS's idio adds
    // the body diode's charging current, which the drain shares with the
    // channel and the gate (opvar_ngspice.zig). Legal neighbours first: the
    // same cards with those charges at 0, the companions gpi and gmu at
    // xcjc = 0.5, and idio at an operating point. Red before the replay:
    // the first neighbour, UnsupportedCard.
    const cards = "charges\nvc c 0 dc 3\nvb b 0 sin(0.7 0.1 10meg)\nq1 c b 0 qn\n.model qn npn is=1e-15 cje=1p cjc=0.5p {s}\n" ++
        "q2 c b 0 0 qv\n.model qv npn level=4 is=1e-16 cje=1p cjc=0.5p {s}\nm1 c b 0 vm1\n.model vm1 vdmos cgs=1n\n.save {s}\n{s}\n.end\n";
    const tran = ".tran 0.5n 20n";
    var buf: [512]u8 = undefined;
    for ([_][4][]const u8{
        .{ "xcjc=1", "cjep=0", "@q1[ic] @q1[ib] @q1[ie] @q2[ic] @q2[ib] @q2[ie] @m1[ig]", tran },
        .{ "xcjc=0.5", "cjep=0.1p", "@q1[gpi] @q1[gmu] @q2[gpi] @q2[gmu]", tran },
        .{ "", "", "@m1[idio]", ".op" },
    }) |c| {
        const p = try deck.solve(try std.fmt.bufPrint(&buf, cards, .{ c[0], c[1], c[2], c[3] }));
        p.deinit();
    }
    for ([_][3][]const u8{
        .{ "xcjc=0.5", "", "@q1[ib]" },
        .{ "cjs=1p", "", "@q1[ie]" },
        .{ "iss=1e-16", "", "@q1[ic]" },
        .{ "", "cjep=0.1p", "@q2[ib]" },
        .{ "", "", "@m1[idio]" },
    }) |c| try expectRefused(try std.fmt.bufPrint(&buf, cards, .{ c[0], c[1], c[2], tran }));
}

test "a .tran the API appends is refused where no replay serves a saved variable; static names append fine (#236)" {
    // A deck without a .tran resolves its names for static points, and a
    // uic or TSTART > 0 run's first row is no operating point
    // (core.OpVar.dynamic): id and gd there would read a wrong number with
    // no error, or, past TSTART, trip the replay's order assertion. Legal
    // neighbours: the deck's own run, and the same appends on the deck
    // saving only qd, which no step changes. Red before the refusal: every
    // append is accepted.
    const body = "appended\nv1 a 0 sin(0 0.8 10meg)\nd1 a 0 dm\n.model dm d is=1e-14 cjo=10p tt=10n\n.save {s}\n{s}\n.end\n";
    const cases = [_]struct { []const u8, api.requests.Tran }{
        .{ ".op", .{ .t_stop = 20e-9, .dt_init = 0.5e-9 } },
        .{ ".tran 0.5n 20n", .{ .t_stop = 20e-9, .dt_init = 0.5e-9, .uic = true } },
        .{ ".tran 0.5n 20n", .{ .t_stop = 20e-9, .dt_init = 0.5e-9, .t_start = 5e-9 } },
    };
    var buf: [256]u8 = undefined;
    for (cases) |c| for ([_]bool{ false, true }) |dynamic| {
        const own, const tran = c;
        const names: []const []const u8 = if (dynamic) &.{ "@d1[id]", "@d1[gd]", "@d1[qd]" } else &.{"@d1[qd]"};
        const saves: []const u8 = if (dynamic) "@d1[id] @d1[gd] @d1[qd]" else "@d1[qd]";
        const text = try std.fmt.bufPrint(&buf, body, .{ saves, own });
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = text, .origin = "opvars_tran.cir" } } });
        defer p.deinit();
        var ids: [1]api.QueryId = undefined;
        if (dynamic) {
            try t.expectError(error.UnreplayedOpVar, p.append_queries(&.{.{ .tran = tran }}, &ids));
        } else _ = try p.append_queries(&.{.{ .tran = tran }}, &ids);
        try p.run_all();
        const mine = try resultOf(p, if (std.mem.eql(u8, own, ".op")) .op else .tran);
        for (0..mine.npoints) |k| for (names) |name| {
            try t.expect(std.math.isFinite(try at(mine, k, name)));
        };
        if (dynamic) continue;
        const appended = try p.result(ids[0]);
        try t.expect(appended.npoints > 1);
        for (0..appended.npoints) |k| try t.expect(std.math.isFinite(try at(appended, k, "@d1[qd]")));
    };
}
