//! A junction's breakdown knee xbv solves diotemp.c's equation
//! IS*(exp((BV - xbv)/(NBV*Vt)) - 1 + xbv/Vt) = IBV to the bound its loop
//! stops at. Oracle: a certificate read off the terminal current, not the
//! model's loop. At vd = -BV the junction carries IS*exp((BV - xbv)/(NBV*Vt))
//! plus a linear leakage the card fixes, so the current gives xbv back and
//! the equation's residual over IBV is checked against the bound:
//! - a diode, reltol: diotemp.c stops at reltol*IBV (ngspice-45 on this
//!   card: 6.2e-4 at reltol 1e-3, 2.7e-9 at 1e-7; one pass, the code before,
//!   left 6.2e-4 at 1e-7);
//! - a VDMOS body diode, 1e-9 at the default reltol: vdmos.va converges its
//!   knee (25 passes) where vdmostemp.c stops at reltol*IBV (ngspice 44.2 and
//!   45 on this card: 4.8e-4, one pass).
//! Both cards sit at TNOM with NBV = N = 1, so IS(T) is IS and NBV*Vt is Vt.
const std = @import("std");
const decks = @import("deck.zig");

/// Vt at 27 degC with diode.va's and vdmos.va's k/q.
const vt: f64 = 1.38064852e-23 / 1.6021766208e-19 * (27.0 + 273.15);

// ---- private ----

/// The knee equation's residual over `ibv` for a junction at vd = -`bv`
/// that draws `current` (a magnitude), `leak` of it linear leakage.
fn kneeResidual(current: f64, leak: f64, is: f64, ibv: f64, bv: f64) f64 {
    const e = (current - leak) / is; // exp((bv - xbv)/vt)
    const xbv = bv - vt * @log(e);
    return (is * (e - 1.0 + xbv / vt) - ibv) / ibv;
}

/// |i(vd)| at `deck`'s operating point.
fn opCurrent(deck: []const u8) !f64 {
    const p = try decks.solve(deck);
    defer p.deinit();
    return @abs(try decks.at(try decks.resultOf(p, .op), 0, "i(vd)"));
}

test "a diode's breakdown knee meets diotemp.c's reltol*IBV test at reltol 1e-3 and 1e-7" {
    // dc/diode_area_sidewall's D4 alone: LEVEL=3 takes AREA and PJ from W,
    // L and XW, JSW joins IS without NS, IBV scales by the area. Without RS
    // the junction sits at the source's -8 V; its leakage is gmin*8.
    const w = 20e-6;
    const l = 10e-6;
    const xw = 1e-6;
    const ae: f64 = (w + xw) * (l + xw);
    const pe: f64 = 2.0 * (w + xw) + 2.0 * (l + xw);
    const card = "knee\nvd a 0 dc -8\nd1 a 0 dk w=20u l=10u\n" ++
        ".model dk d level=3 is=1e-4 jsw=1e-10 xw=1u bv=8 ibv=1e-1\n.options reltol=";
    inline for (.{ .{ "1e-3", 1e-3 }, .{ "1e-7", 1e-7 } }) |c| {
        const current = try opCurrent(card ++ c[0] ++ "\n.op\n.end\n");
        const residual = kneeResidual(current, 1e-12 * 8.0, 1e-4 * ae + 1e-10 * pe, 1e-1 * ae, 8.0);
        if (!(@abs(residual) <= c[1])) {
            std.debug.print("reltol {s}: knee residual {e} of IBV ({e} A)\n", .{ c[0], residual, current });
            return error.TestExpectedApproxEqRel;
        }
    }
}

test "a VDMOS body diode's breakdown knee is converged to 1e-9 of IBV at the default reltol, past ngspice's reltol*IBV" {
    // vto=20 shuts the channel at vgs = 0 (2e-88 V of overdrive); the
    // leakage is gmin*20 on the body diode and the 1e-15 S d-s shunt a card
    // without RDS gets (vdmosset.c:292-299). Drain at 20 V: vd = -BV.
    const current = try opCurrent("knee\nvd d 0 dc 20\nvg g 0 dc 0\nm1 d g 0 vm\n" ++
        ".model vm vdmos(vto=20 is=1e-9 bv=20 ibv=1.5u)\n.op\n.end\n");
    const residual = kneeResidual(current, 1e-12 * 20.0 + 1e-15 * 20.0, 1e-9, 1.5e-6, 20.0);
    if (!(@abs(residual) <= 1e-9)) {
        std.debug.print("knee residual {e} of IBV ({e} A)\n", .{ residual, current });
        return error.TestExpectedApproxEqRel;
    }
}
