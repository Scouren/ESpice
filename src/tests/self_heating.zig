//! Diode self-heating (`diode_t`, models/diode.va under SELFHEATING)
//! through the public API, docs/perf_research/17-self-heating.md's T1-T7.
//! Oracles, cheapest first and none the model's own arithmetic: the
//! fixed-temperature twin (a plain diode at `temp = ambient + v(tj)` draws
//! the heated one's current), the thermal network's steady state v(tj) =
//! rth0 V I, the transient energy balance and the time-constant bracket of
//! its RC, and ngspice 44.2's numbers for each deck (`ngspice -b`, `set
//! numdgt=12`, the deck plus a `print` of the names read here). Every
//! heated deck was refused (`UnsupportedSelfHeating`) before diode_t.
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;

/// The doc's sh_op.sp card: 0.2 s thermal time constant, RS tempered.
const model = ".model dmod d (is=1e-14 n=1 rs=0.5 rth0=200 cth0=1e-3 tnom=27 xti=3 eg=1.11 trs=2e-3)\n";
/// Tolerances an ngspice reference at 12 digits is worth.
const tight = ".options reltol=1e-9 abstol=1e-16 vntol=1e-12 gmin=1e-15\n";

// ---- private ----

/// Columns `names` of the operating point of `text`.
fn opValues(comptime n: usize, text: []const u8, names: [n][]const u8) ![n]f64 {
    const p = try deck.solve(text);
    defer p.deinit();
    const r = try deck.resultOf(p, .op);
    var out: [n]f64 = undefined;
    for (&out, names) |*o, name| o.* = try deck.at(r, 0, name);
    return out;
}

/// Column `name` of `r` at scale value `x`, linear between the rows
/// around it.
fn interp(r: api.Result, x: f64, name: []const u8) !f64 {
    const w = r.varnames.len;
    const c = try deck.column(r, name);
    for (1..r.npoints) |k| {
        const x0 = r.data[(k - 1) * w];
        const x1 = r.data[k * w];
        if (x1 < x) continue;
        const y0 = r.data[(k - 1) * w + c];
        return y0 + (r.data[k * w + c] - y0) * (x - x0) / (x1 - x0);
    }
    return error.OutOfRange;
}

/// The deck's `i1 0 1 pwl(0 0 1m 0 1.001m 20m)` at `time`.
fn stepCurrent(time: f64) f64 {
    return 20e-3 * std.math.clamp((time - 1e-3) / 1e-6, 0, 1);
}

test "a self-heated diode's v(tj) is rth0 times its power, and a plain diode at that temperature draws its current" {
    // Oracles: the thermal network's steady state with nothing else on tj,
    // v(tj) = rth0 V I (dioload.c:874), and the fixed-temperature twin.
    // ngspice 44.2 (sh_op.sp, sh_twin_run.sp): v(tj) = 4.302815034336, both
    // currents 2.868543356224e-02. `thermal=1` on the model card heats as
    // the word does (an instance key's default there, measured on 44.2).
    // Red: UnsupportedSelfHeating before diode_t; dropping Temp(br_th) from
    // tk leaves the isothermal 2.4435e-2 (17 % off the twin); halving the
    // RS term of pwr lowers v(tj) by 0.041 K (1 %).
    const bias = "self-heating\n.temp 27\n" ++ tight ++ "v1 1 0 0.75\n";
    const names = [_][]const u8{ "v(tj)", "i(v1)", "@dsh[id]" };
    const vtj, const i, const id = try opValues(3, bias ++ "dsh 1 0 tj dmod thermal\n.save v(tj) i(v1) @dsh[id]\n" ++ model ++ ".op\n.end\n", names);
    try t.expectApproxEqRel(200 * 0.75 * -i, vtj, 1e-8);
    try t.expectApproxEqRel(@as(f64, 4.302815034336), vtj, 1e-6);
    try t.expectApproxEqRel(@as(f64, -2.868543356224e-02), i, 1e-6);
    try t.expectApproxEqRel(-i, id, 1e-12);
    const flagged = try opValues(1, bias ++ "dsh 1 0 tj dmod\n" ++ model[0 .. model.len - 2] ++ " thermal=1)\n.op\n.end\n", .{"v(tj)"});
    try t.expectApproxEqRel(vtj, flagged[0], 1e-12);
    const twin = try t.allocator.print(bias ++ "d2 1 0 dmod temp={d}\n" ++ model ++ ".op\n.end\n", .{27 + vtj});
    defer t.allocator.free(twin);
    try t.expectApproxEqRel(i, (try opValues(1, twin, .{"i(v1)"}))[0], 1e-8);
}

test "a self-heated diode's @d[p] is its electrical power, with a network on tj" {
    // Oracle: v(a, c) × the current, both from the output vectors
    // (dioask.c's p, id × vd + id²/gspr, reads no thermal port), and ngspice
    // 44.2 (sh_p.sp): @dsh[p] = 1.924879453148e-02 = -v(1) i(v1), v(tj) =
    // 1.283252968765 = (200 || 100) × p. Red: OpVar.ports = 3 adds tj's T ×
    // (T/rth0 - p), -1.65e-2 once rtj draws heat from tj: 2.78e-3. With
    // nothing else on tj that flow is 0, so the deck needs rtj.
    const vtj, const v, const i, const p = try opValues(4, "self-heated p\n.temp 27\n" ++ tight ++ "v1 1 0 0.75\ndsh 1 0 tj dmod thermal\nrtj tj 0 100\n" ++
        ".save v(tj) v(1) i(v1) @dsh[p]\n" ++ model ++ ".op\n.end\n", .{ "v(tj)", "v(1)", "i(v1)", "@dsh[p]" });
    try t.expectApproxEqRel(v * -i, p, 1e-12);
    try t.expectApproxEqRel(@as(f64, 1.924879453148e-02), p, 1e-6);
    try t.expectApproxEqRel(@as(f64, 1.283252968765), vtj, 1e-6);
}

test "m and area scale a self-heated diode's power, and rth0 stays the instance's" {
    // Oracle: rth0 V I over the whole instance (dioload.c:874 scales
    // neither rth0 nor cth0; diotemp.c:121 the currents), and ngspice 44.2
    // (t3.sp): v(tj) = 570.47068015863, i(v1) = -3.803137867724. Red:
    // dropping $mfactor from the network's rth0 halves v(tj).
    const vtj, const i = try opValues(2, "m and area\n.temp 27\n" ++ tight ++ "v1 1 0 0.75\ndsh 1 0 tj dmod area=3 m=2 thermal\n" ++ model ++ ".op\n.end\n", .{ "v(tj)", "i(v1)" });
    try t.expectApproxEqRel(200 * 0.75 * -i, vtj, 1e-8);
    try t.expectApproxEqRel(@as(f64, 570.47068015863), vtj, 1e-6);
    try t.expectApproxEqRel(@as(f64, -3.803137867724), i, 1e-6);
}

test "a self-heated diode heats from its own ambient: .temp plus dtemp, or temp" {
    // Oracle: the twins at ambient + v(tj) (diotemp.c:308-311, dioload.c:331)
    // and ngspice 44.2 (sh_temp.sp, sh_temp_twin.sp): v(tj) = 3.936421421763
    // from 50 + 10 degC, v(tj3) = 8.021213335491 from temp=80, the twins'
    // currents equal to 12 digits. Red: an ambient of $temperature alone
    // heats both from 50 degC.
    const head = "ambient\n.temp 50\n" ++ tight ++ "v1 1 0 0.7\nva 1 a 0\nvb 1 b 0\n";
    const card = ".model dmod d (is=1e-14 rs=0.5 rth0=200 tnom=27)\n.op\n.end\n";
    const vtj, const ia, const vtj3, const ib = try opValues(4, head ++ "dsh a 0 tj dmod thermal dtemp=10\nd3 b 0 tj3 dmod thermal temp=80\n" ++ card, .{ "v(tj)", "i(va)", "v(tj3)", "i(vb)" });
    try t.expectApproxEqRel(@as(f64, 3.936421421763), vtj, 1e-6);
    try t.expectApproxEqRel(@as(f64, 8.021213335491), vtj3, 1e-6);
    const twins = try t.allocator.print(head ++ "d2 a 0 dmod temp={d}\nd4 b 0 dmod temp={d}\n" ++ card, .{ 60 + vtj, 80 + vtj3 });
    defer t.allocator.free(twins);
    const ta, const tb = try opValues(2, twins, .{ "i(va)", "i(vb)" });
    try t.expectApproxEqRel(ia, ta, 1e-8);
    try t.expectApproxEqRel(ib, tb, 1e-8);
}

test "a diode off ngspice's self-heating condition runs isothermal" {
    // ngspice heats only with a third node, the `thermal` flag and a given,
    // non-zero rth0 (diodefs.h:31-33). Oracle: the plain two-node card at
    // the same bias, and ngspice 44.2 (t5.sp): 2.4434937135935e-02 through
    // each. Red: UnsupportedSelfHeating before diode_t on the three-node
    // and flagged cards; a heatsDiode that ignored rth0 heats dc through
    // diode_t's default rth0, off the plain card's current.
    const ammeters = [_][]const u8{ "i(va)", "i(vb)", "i(vc)", "i(vd)", "i(ve)", "i(vf)" };
    const got = try opValues(6, "off conditions\n.temp 27\n" ++ tight ++ "v1 1 0 0.75\n" ++
        "va 1 a 0\nvb 1 b 0\nvc 1 c 0\nvd 1 d 0\nve 1 e 0\nvf 1 f 0\n" ++
        "da a 0 tj1 dmod\ndb b 0 dmod thermal\ndc c 0 tj3 dnor thermal\ndd d 0 tj4 dzero thermal\nde e 0 dmod\ndf f 0 dnor\nrx tj1 0 1\n" ++
        model ++
        ".model dnor d (is=1e-14 n=1 rs=0.5 tnom=27 xti=3 eg=1.11 trs=2e-3)\n" ++
        ".model dzero d (is=1e-14 n=1 rs=0.5 rth0=0 tnom=27 xti=3 eg=1.11 trs=2e-3)\n.op\n.end\n", ammeters);
    for (got, ammeters) |i, name| {
        t.expectApproxEqRel(got[5], i, 1e-12) catch |err| {
            std.debug.print("{s}: {e} against the plain card's {e}\n", .{ name, i, got[5] });
            return err;
        };
    }
    try t.expectApproxEqRel(@as(f64, 2.4434937135935e-02), got[5], 1e-6);
}

test "a self-heated diode's thermal RC stores its power less the leak, over rth0 cth0" {
    // Oracles, both from the output waveforms: the energy balance cth0
    // v(tj)(T) = integral of (v(1) i1 - v(tj)/rth0) dt, by trapezoid
    // quadrature over the accepted points; and the bracket a first-order
    // network puts v(tj) in one rth0 cth0 = 0.2 s after the step, (1 - 1/e)
    // rth0 P with P between the run's last and first powers, since P falls
    // as the junction heats. ngspice 44.2 (sh_tran.sp) closes the balance
    // to 4.4e-6 (2.950924e-3 against 2.950911e-3) and reads v(tj) =
    // 1.872908 at 0.201 s, inside [1.8663, 1.8776]. Red: cth0 off by 2x
    // breaks the balance; without the ddt term v(tj) jumps to 2.97 K at once.
    const p = try deck.solve(
        \\thermal step
        \\.temp 27
        \\.options reltol=1e-6 abstol=1e-14 vntol=1e-9 method=gear
        \\i1 0 1 pwl(0 0 1m 0 1.001m 20m)
        \\dsh 1 0 tj dmod thermal
        \\.model dmod d (is=1e-14 n=1 rs=0.5 rth0=200 cth0=1e-3 tnom=27)
        \\.save v(1) v(tj)
        \\.tran 1m 1.5 0 1m
        \\.end
        \\
    );
    defer p.deinit();
    const r = try deck.resultOf(p, .tran);
    const w = r.varnames.len;
    const v1 = try deck.column(r, "v(1)");
    const tj = try deck.column(r, "v(tj)");
    var energy: f64 = 0;
    for (1..r.npoints) |k| {
        const a = r.data[(k - 1) * w ..][0..w];
        const b = r.data[k * w ..][0..w];
        const fa = a[v1] * stepCurrent(a[0]) - a[tj] / 200;
        const fb = b[v1] * stepCurrent(b[0]) - b[tj] / 200;
        energy += 0.5 * (fa + fb) * (b[0] - a[0]);
    }
    const last = r.data[(r.npoints - 1) * w ..][0..w];
    try t.expectApproxEqRel(@as(f64, 1.5), last[0], 1e-12);
    try t.expectApproxEqRel(1e-3 * last[tj], energy, 1e-4);
    try t.expectApproxEqRel(@as(f64, 2.950924), last[tj], 1e-4);
    const rise = (1 - @exp(@as(f64, -1))) * 200 * 20e-3;
    const at_tau = try interp(r, 0.201, "v(tj)");
    try t.expect(at_tau >= rise * last[v1]);
    try t.expect(at_tau <= rise * try interp(r, 1.1e-3, "v(1)"));
    try t.expectApproxEqRel(@as(f64, 1.872908), at_tau, 1e-4);
}
