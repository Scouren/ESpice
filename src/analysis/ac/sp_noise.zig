//! ngspice's `.sp ... donoise=1` columns after S, Y and Z: the short-circuit
//! noise current correlation Cy of every port pair and, for exactly two
//! ports, NF, SOpt, NFmin and Rn. One adjoint right-hand side per port
//! (per mode of a balanced port: its legs' voltages weighted as
//! `sp_basis.zig` defines the mode) gives the port voltage noise
//! correlation Cv with every leg terminated in its noiseless z0; the Norton
//! currents of those voltages are i = (Y + Y0) v, so
//! Cy = (Y + Y0) Cv (Y + Y0)^H, published unnormalized in A^2/Hz. The
//! two-port figures normalize Cy by 4 k T at the circuit temperature, not
//! 290 K. Also the correlation sum `sp_lin.zig`'s HSPICE noise columns use.
//! In: the `.sp` rows with S, Y and Z filled and the terminated
//! `FreqSolver`. Out: the same rows with the noise columns filled.
//! Cites ngspice span.c:111-165 (Maas's two-port formulas), :547-567 (names);
//! nevalsrc.c:68-90 (i = (Y + Y0) v, Cy_ds = i_d i_s*); cktspdum.c:204-237
//! (column order).
//!
//! Contents:
//! - `pub fn columns(n_ports: usize) usize`
//! - `pub fn names(a: Allocator, n_ports: usize, out: [][]const u8) Allocator.Error!void`
//! - `pub fn fill(ctx: *const RunCtx, fs: *FreqSolver, basis: *const Basis, omegas: []const f64, data: []f64, row_len: usize, s_col: usize) !void`
//! - `pub fn adjointDrive(basis: *const Basis, which: []const usize, nn: usize, e: []f64) void`
//! - `pub fn correlate(srcs: []const NoiseSource, x: []const f64, n: usize, f: f64, h: []Complex, c: []Complex) void`
//! - `pub fn twoPort(y: [4]Complex, c: [4]Complex, y0: f64) [4]Complex`

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Complex = @import("core").numerics.Complex;
const FreqSolver = @import("solver").freq_solve.FreqSolver;
const root = @import("../types.zig");
const NoiseSource = root.NoiseSource;
const freq = @import("freq.zig");
const noise = @import("noise.zig");
const net = @import("sp_network.zig");
const Basis = @import("sp_basis.zig").Basis;

/// ngspice's two-port columns, in `twoPort` order (span.c:564-567).
const two_port_names = [_][]const u8{ "v(NF)", "v(SOpt)", "v(NFmin)", "v(Rn)" };
/// ngspice CONSTCtoK (const.h): the circuit temperature in kelvin.
const c_to_k = 273.15;

/// Returns the noise columns after S for `n_ports` ports: n^2 Cy entries,
/// and the four two-port figures when there are exactly two.
pub fn columns(n_ports: usize) usize {
    return n_ports * n_ports + if (n_ports == 2) two_port_names.len else 0;
}

/// Writes the noise column names into `out` (`columns(n_ports)` slots):
/// `v(Cy_i_j)` row-major, then `v(NF)`, `v(SOpt)`, `v(NFmin)`, `v(Rn)`,
/// spelled as ngspice's raw writer types a UID_OTHER (span.c:547-567).
/// Allocates from the results arena `a`, which owns them.
pub fn names(a: Allocator, n_ports: usize, out: [][]const u8) Allocator.Error!void {
    assert(out.len == columns(n_ports));
    for (0..n_ports) |i| for (0..n_ports) |j| {
        out[i * n_ports + j] = try a.print("v(Cy_{d}_{d})", .{ i + 1, j + 1 });
    };
    if (n_ports == 2) @memcpy(out[4..], &two_port_names);
}

/// Fills the noise columns of every row of `data`, whose S, Y and Z blocks
/// over `basis`'s modes (from column `s_col`) are already written and which
/// they follow: Cy over every mode pair, then for two modes NF and NFmin
/// in dB, SOpt and Rn in ohms.
/// `fs` holds the port terminations; real figures have a zero imaginary
/// part. Asserts rows that end with the noise columns.
pub fn fill(ctx: *const root.RunCtx, fs: *FreqSolver, basis: *const Basis, omegas: []const f64, data: []f64, row_len: usize, s_col: usize) !void {
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const np = basis.legs.len;
    const z0 = basis.z0;
    const n2 = np * np;
    const col = s_col + 3 * n2;
    assert(z0.len == np);
    assert(data.len == omegas.len * row_len);
    assert(row_len == 2 * (col + columns(np)));
    const srcs = try ckt.collectNoiseSources(ctx.x_op, scratch);
    defer scratch.free(srcs);

    const all = try scratch.alloc(usize, np);
    defer scratch.free(all);

    for (all, 0..) |*q, i| q.* = i;
    const e = try scratch.alloc(f64, np * nn);
    defer scratch.free(e);

    adjointDrive(basis, all, nn, e);
    // S, Y, Z, H (`net.params`), then its scratch, the transfers, Cv and Y + Y0.
    const m = net.paramCount(np);
    const work = try scratch.alloc(Complex, m + 3 * n2 + np);
    defer scratch.free(work);

    const p = work[0..m];
    const tmp = work[m..][0..n2];
    const cv = work[m + n2 ..][0..n2];
    const g = work[m + 2 * n2 ..][0..n2];
    const h = work[m + 3 * n2 ..][0..np];
    var stream = try freq.Stream.init(scratch, fs, ckt, ctx.x_op, omegas, e, true);
    defer stream.deinit(scratch);

    const kt4 = 4 * net.k_boltzmann * (@as(f64, ckt.temp_c) + c_to_k);
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * row_len ..][0..row_len];
        correlate(srcs, pt.x, n, row[0], h, cv);
        net.readComplex(row[2 * s_col ..][0 .. 2 * n2], p[0..n2]);
        net.params(z0, .{ 0, 1 }, p, tmp);
        for (0..np) |i| for (0..np) |j| {
            g[i * np + j] = p[n2 + i * np + j];
            if (i == j) g[i * np + j].re += 1 / z0[i];
        };
        // Cy = G Cv G^H, over S's slot (Y stays). ponytail: O(np^4) dense,
        // np is a port count.
        const cy = p[0..n2];
        for (0..np) |i| for (0..np) |j| {
            var acc = Complex.zero;
            for (0..np) |k| for (0..np) |l| {
                const gjl: Complex = .{ .re = g[j * np + l].re, .im = -g[j * np + l].im };
                acc = acc.add(g[i * np + k].mul(cv[k * np + l]).mul(gjl));
            };
            cy[i * np + j] = acc;
        };
        net.writeComplex(cy, row[2 * col ..][0 .. 2 * n2]);
        if (np != 2) continue;
        var c: [4]Complex = undefined;
        for (&c, cy[0..4]) |*dst, src| dst.* = src.scale(1 / kt4);
        const figures = twoPort(p[n2..][0..4].*, c, 1 / z0[0]);
        net.writeComplex(&figures, row[2 * (col + n2) ..][0 .. 2 * two_port_names.len]);
    }
}

/// Writes the adjoint drive of each mode index in `which` into its block
/// of `e` (`which.len` blocks of `nn`): the mode voltage, each leg's
/// v(node) - v(neg) weighted by `Basis.voltageWeight` (a single-ended
/// port's own voltage, weight 1).
pub fn adjointDrive(basis: *const Basis, which: []const usize, nn: usize, e: []f64) void {
    assert(e.len == which.len * nn);
    @memset(e, 0);
    for (which, 0..) |q, i| for (basis.legs, 0..) |leg, l| {
        const w = basis.voltageWeight(q, l);
        if (w == 0) continue;
        if (leg.node != root.GROUND) e[i * nn + leg.node] += w;
        if (leg.neg != root.GROUND) e[i * nn + leg.neg] -= w;
    };
}

/// Writes into `c` (m x m row-major, m = `h.len`) the one-sided port voltage
/// noise correlation C_ij = <v_i v_j*> (V^2/Hz) at `f` Hz, from the m
/// stacked-real adjoint solutions `x` (blocks of 2n). The transpose solve is
/// A^H y = e, so the transfer is conj(y) and h_i conj(h_j) = conj(y_i) y_j;
/// a correlated group's rows add as phasors first. `h` is scratch.
pub fn correlate(srcs: []const NoiseSource, x: []const f64, n: usize, f: f64, h: []Complex, c: []Complex) void {
    const m = h.len;
    const nn = 2 * n;
    assert(c.len == m * m);
    assert(x.len >= m * nn);
    @memset(c, Complex.zero);
    var lead: usize = 0;
    while (lead < srcs.len) {
        const end = NoiseSource.groupEnd(srcs, lead);
        assert(end > lead);
        defer lead = end;
        const psd = noise.sourcePsd(srcs[lead], f);
        for (h, 0..) |*y, i| {
            const t = noise.transfer(srcs[lead..end], x[i * nn ..][0..nn], n);
            y.* = .{ .re = t[0], .im = t[1] };
        }
        for (0..m) |i| for (0..m) |j| {
            const conj_i: Complex = .{ .re = h[i].re, .im = -h[i].im };
            c[i * m + j] = c[i * m + j].add(conj_i.mul(h[j]).scale(psd));
        };
    }
}

/// Returns ngspice's two-port noise figures (NF dB, SOpt, NFmin dB, Rn ohm)
/// from Y and the normalized correlation c = Cy / 4kT (both row-major) and
/// port 1's reference admittance y0 (span.c:123-165, after Maas):
///   Rn = c22 / |Y21|^2,  Ycor = Y11 - (c12 / c22) Y21,
///   Gu = c11 - Rn |Y11 - Ycor|^2,  Ysopt = sqrt(Gcor^2 + Gu / Rn) - j Bcor,
///   Sopt = (y0 - Ysopt) / (y0 + Ysopt),  Fmin = 1 + 2 Rn (Gcor + Gsopt),
///   F = Fmin + (Rn / y0) |y0 - Ysopt|^2.
/// ngspice's floors stand: Rn and c22 at 1e-30, a negative root argument
/// (Gu rounded below 0 by a fully correlated source) at 0.
pub fn twoPort(y: [4]Complex, c: [4]Complex, y0: f64) [4]Complex {
    assert(y0 > 0);
    var rn = c[3].re / y[2].magSq();
    if (@abs(rn) < 1e-30) rn = 1e-30;
    var c22 = c[3];
    if (@abs(c22.re) < 1e-30 and @abs(c22.im) < 1e-30) c22.re = 1e-30;
    const ycor = y[0].sub(c[1].div(c22).mul(y[2]));
    const gu = c[0].re - rn * y[0].sub(ycor).magSq();
    const arg = ycor.re * ycor.re + gu / rn;
    const ysopt: Complex = .{ .re = @sqrt(if (arg < 0) 0 else arg), .im = -ycor.im };
    const ys: Complex = .{ .re = y0, .im = 0 };
    const f_min = 1 + 2 * rn * (ycor.re + ysopt.re);
    const f = f_min + rn / y0 * ys.sub(ysopt).magSq();
    return .{
        .{ .re = 10 * @log10(f), .im = 0 },
        ys.sub(ysopt).div(ys.add(ysopt)),
        .{ .re = 10 * @log10(f_min), .im = 0 },
        .{ .re = rn, .im = 0 },
    };
}

test twoPort {
    // Oracle: the matched 150/37.5/150 ohm pi attenuator in 50 ohm, worked by
    // hand. Y11 = Y22 = 1/30, Y21 = Y12 = -2/75 S; a passive network at one
    // temperature has Cy = 4kT Re Y (Twiss), so c = Y. Then Rn = 46.875 ohm,
    // Ycor = Gu = 0.012 S, Ysopt = 1/50 S, Sopt = 0 and F = Fmin = 4, the
    // attenuator's 6.0206 dB loss. ngspice-44.2 prints the same to 1e-15
    // (tests/conformance/tests/netlist/sp/pi_donoise.sp).
    const y = [4]Complex{ .{ .re = 1.0 / 30.0, .im = 0 }, .{ .re = -2.0 / 75.0, .im = 0 }, .{ .re = -2.0 / 75.0, .im = 0 }, .{ .re = 1.0 / 30.0, .im = 0 } };
    const got = twoPort(y, y, 1.0 / 50.0);
    const db4 = 6.020599913279624;
    try testing.expectApproxEqRel(db4, got[0].re, 1e-12);
    try testing.expectApproxEqAbs(0, got[1].mag(), 1e-12);
    try testing.expectApproxEqRel(db4, got[2].re, 1e-12);
    try testing.expectApproxEqRel(46.875, got[3].re, 1e-12);
    // A noiseless two-port: ngspice's floors keep every figure finite, and
    // its NF is the 0 dB of a noiseless amplifier.
    const quiet = twoPort(y, .{ Complex.zero, Complex.zero, Complex.zero, Complex.zero }, 1.0 / 50.0);
    for (quiet) |v| try testing.expect(std.math.isFinite(v.re) and std.math.isFinite(v.im));
    try testing.expectApproxEqAbs(0, quiet[0].re, 1e-9);
}

test names {
    // Every slot `columns` sizes is written, in ngspice's order.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [8][]const u8 = undefined;
    try names(arena.allocator(), 2, &out);
    try testing.expectEqualStrings("v(Cy_1_2)", out[1]);
    try testing.expectEqualStrings("v(NF)", out[4]);
    try testing.expectEqualStrings("v(Rn)", out[7]);
    try testing.expectEqual(@as(usize, 9), columns(3));
    try testing.expectEqual(@as(usize, 1), columns(1));
}
