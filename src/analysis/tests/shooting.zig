//! Shooting on circuits whose trapezoid ringing nothing damps, on each of
//! its four Newton paths: the monodromy's dense Jacobian and GMRES (`Mono`),
//! and past `Mono` the finite-difference columns and matrix-free GMRES.
//! Oracle: the bilinear-warped phasor. On a linear circuit driven by a
//! sampled sine, trapezoid's periodic orbit over N steps of dt is the
//! phasor solution at s = j(2/dt)tan(w dt/2), the bilinear map of
//! (2/dt)(z-1)/(z+1) at z = exp(j w dt): DFT bin 1 is |H(s)| and every
//! other bin zero, the Nyquist bin among them. A trapezoid current no
//! charge backs rings (-1)^k with multiplier +1 over an even N, so it shows
//! up only in that bin. N = 64, T = 1 ms; src/tests/espice.zig runs the
//! same two decks through the netlist.

const std = @import("std");
const testing = std.testing;
const analysis = @import("../types.zig");
const pss = @import("../pss/pss.zig");
const Shoot = @import("../pss/Shoot.zig");
const converger = @import("solver").converger;
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const models = @import("models");

const Complex = std.math.Complex(f64);

const steps = 64;
const f0: f64 = 1e3;

/// A shooting Newton path: the monodromy's or, as past its memory budget,
/// finite differences; dense below `Shoot.krylov_threshold` unknowns,
/// GMRES past it.
const Path = enum { mono_dense, mono_krylov, fd_dense, fd_krylov };

const paths = [_]Path{ .mono_dense, .mono_krylov, .fd_dense, .fd_krylov };

/// Both decks drive a with vs a 0 sin(0 1 1k). `cvloop`: c1 a b 1u, c2 b 0
/// 1u, r1 b 0 1k, where vs, c1 and c2 are a loop whose current rings in
/// vs's column alone. `island`: r1 a b 1k, c1 b c 1u, l1 c 0 10m, r2 c 0
/// 100, where c1 alone holds charge at b and c, so rows b + c sum no
/// dynamic current.
const Deck = enum { cvloop, island };

// ---- private ----

/// `deck` on `path`, every unknown probed: a GMRES path pads the circuit
/// past `Shoot.krylov_threshold` with a resistor ladder off a (vs holds
/// a, so b and c do not see it). Writes v(b)'s and v(c)'s bin-1 amplitudes
/// (v(c) 0 for `cvloop`) and returns the worst ringing, any unknown's
/// |Nyquist component| over its peak.
fn solveOn(deck: Deck, path: Path, a1: *[2]f64) !f64 {
    const a = testing.allocator;
    var lib = try Library.init(a);
    defer lib.deinit();
    var b = try Builder.init(a, &lib);
    const na = try b.addNode();
    const nb = try b.addNode();
    const nc = if (deck == .island) try b.addNode() else analysis.GROUND;
    try b.addDevice(models.vsource, "", &.{ .dc = 0, .waveform = 2, .sin_vo = 0, .sin_va = 1, .sin_freq = f0 }, &.{}, .{ na, analysis.GROUND });
    switch (deck) {
        .cvloop => {
            try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ na, nb });
            try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ nb, analysis.GROUND });
            try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ nb, analysis.GROUND });
        },
        .island => {
            try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ na, nb });
            try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ nb, nc });
            try b.addDevice(models.inductor, "", &.{ .l = 10e-3 }, &.{}, .{ nc, analysis.GROUND });
            try b.addDevice(models.resistor, "", &.{ .r = 100 }, &.{}, .{ nc, analysis.GROUND });
        },
    }
    const krylov = path == .mono_krylov or path == .fd_krylov;
    if (krylov) {
        var prev = na;
        for (0..Shoot.krylov_threshold) |_| {
            const next = try b.addNode();
            try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, next });
            prev = next;
        }
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, analysis.GROUND });
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try analysis.Circuit.instantiate(&prepared, a);
    defer ckt.deinit();
    const n: usize = ckt.n;
    try testing.expectEqual(krylov, n >= Shoot.krylov_threshold);
    const x_dc = try dcPoint(&ckt, a);
    defer a.free(x_dc);

    const probes = try a.alloc(u32, n);
    defer a.free(probes);
    for (probes, 0..) |*p, i| p.* = @intCast(i);
    const cols = 1 + n;
    const wave = try a.alloc(f64, (steps + 1) * cols);
    defer a.free(wave);
    var s: Shoot = undefined;
    try s.init(&ckt, x_dc, probes, wave, .{ .period = 1 / f0, .n_samples = steps, .shooting_tol = 1e-11 }, a);
    defer s.deinit();
    try testing.expect(s.mono != null);
    // Past `Mono`'s memory budget, as a long period on a large circuit.
    if (path == .fd_dense or path == .fd_krylov) {
        if (s.mono) |*m| m.deinit(a);
        s.mono = null;
    }
    const res = try s.runAlone();
    try testing.expect(res.converged);

    a1.* = .{ bin1(wave, cols, 1 + nb), if (deck == .island) bin1(wave, cols, 1 + nc) else 0 };
    var worst: f64 = 0;
    for (1..cols) |c| {
        var sum: f64 = 0;
        var peak: f64 = 0;
        for (0..steps) |k| {
            const x = wave[k * cols + c];
            sum += if (k % 2 == 0) x else -x;
            peak = @max(peak, @abs(x));
        }
        if (peak != 0) worst = @max(worst, @abs(sum) / steps / peak);
    }
    return worst;
}

/// The warped phasor amplitudes |v(b)|, |v(c)| of `deck` on a 1 V drive.
fn warped(deck: Deck) [2]f64 {
    const dt = 1 / f0 / steps;
    const s = Complex.init(0, 2 / dt * @tan(std.math.pi * f0 * dt));
    const sc1 = s.mul(Complex.init(1e-6, 0));
    const g1 = Complex.init(1e-3, 0);
    switch (deck) {
        // v(b) = s c1 / (s (c1 + c2) + 1/r1): 0.4984268547.
        .cvloop => return .{ sc1.div(sc1.add(sc1).add(g1)).magnitude(), 0 },
        .island => {
            // [1/r1 + s c1, -s c1; -s c1, s c1 + 1/(s l1) + 1/r2] [vb; vc]
            // = [1/r1; 0] by Cramer: 0.1135029113, 0.0514505927.
            const a11 = g1.add(sc1);
            const a22 = sc1.add(s.mul(Complex.init(10e-3, 0)).reciprocal()).add(Complex.init(1e-2, 0));
            const det = a11.mul(a22).sub(sc1.mul(sc1));
            return .{ g1.mul(a22).div(det).magnitude(), g1.mul(sc1).div(det).magnitude() };
        },
    }
}

/// Column `col`'s DFT bin-1 amplitude, 2/N |Σ_k x_k exp(-2πik/N)|, over the
/// period's N rows of `wave`.
fn bin1(wave: []const f64, cols: usize, col: usize) f64 {
    var re: f64 = 0;
    var im: f64 = 0;
    for (0..steps) |k| {
        const ang = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / steps;
        re += wave[k * cols + col] * @cos(ang);
        im += wave[k * cols + col] * @sin(ang);
    }
    return 2 * std.math.hypot(re, im) / steps;
}

/// x_dc of `ckt` by DC Newton from zero; the caller frees it.
fn dcPoint(ckt: *analysis.Circuit, a: std.mem.Allocator) ![]f64 {
    const x = try a.alloc(f64, ckt.n);
    errdefer a.free(x);
    @memset(x, 0);
    try ckt.computeBaseline();
    const ws = try ckt.workspace();
    ckt.setSimState(.{ .kind = .dc });
    _ = try converger.run(ckt, ws, x, 0, .{}, analysis.EvalHook{});
    return x;
}

test "shooting on a capacitor and voltage source loop: every Newton path publishes the warped phasor, the loop current unringing" {
    // Red (unit run 9's binary, 2026-11-11): the dense monodromy path
    // fails with error.Singular (i(vs)'s column of the shooting Jacobian
    // is exactly zero); its GMRES path, on this deck padded past the
    // threshold as here (scratchpad deck cvloopk.sp), publishes i(vs)
    // ringing 3.144e-3 A on a 6.319e-3 A peak as converged.
    const want = warped(.cvloop);
    for (paths) |path| {
        var a1: [2]f64 = undefined;
        const ringing = try solveOn(.cvloop, path, &a1);
        try testing.expectApproxEqRel(want[0], a1[0], 1e-8);
        try testing.expect(ringing < 1e-6);
    }
}

test "shooting on a floating capacitor island: every Newton path publishes the warped phasor, the island unringing" {
    // Red (unit run 9's binary, 2026-11-11): the dense monodromy path
    // publishes v(b) and v(c) ringing at a Nyquist 157 V on the 1 V drive
    // as converged, bin 1 right. Its GMRES path was clean already (it does
    // not step along the near-null direction): this pins the paths to one
    // answer.
    const want = warped(.island);
    for (paths) |path| {
        var a1: [2]f64 = undefined;
        const ringing = try solveOn(.island, path, &a1);
        try testing.expectApproxEqRel(want[0], a1[0], 1e-8);
        try testing.expectApproxEqRel(want[1], a1[1], 1e-8);
        try testing.expect(ringing < 1e-6);
    }
}

test "shooting with a capacitor and voltage source loop frees everything on every allocation failure" {
    const a = testing.allocator;
    var lib = try Library.init(a);
    defer lib.deinit();
    var b = try Builder.init(a, &lib);
    const na = try b.addNode();
    const nb = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 0, .waveform = 2, .sin_vo = 0, .sin_va = 1, .sin_freq = f0 }, &.{}, .{ na, analysis.GROUND });
    try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ na, nb });
    try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ nb, analysis.GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ nb, analysis.GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try analysis.Circuit.instantiate(&prepared, a);
    defer ckt.deinit();
    const x_dc = try dcPoint(&ckt, a);
    defer a.free(x_dc);
    const shoot = struct {
        fn f(gpa: std.mem.Allocator, c: *analysis.Circuit, x: []const f64) !void {
            _ = try pss.solve(c, x, &.{}, &.{}, .{ .period = 1 / f0, .n_samples = steps }, gpa);
        }
    }.f;
    try testing.checkAllAllocationFailures(a, shoot, .{ &ckt, x_dc });
}
