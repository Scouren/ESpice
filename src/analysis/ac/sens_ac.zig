//! AC sensitivity (ngspice `.sens <out> ac <sweep>`): dy/dp of the complex
//! output y(w) = v(out) - v(ref) at every point, for each parameter `.sens`
//! lists, and dy/d(acmag), dy/d(acphase) for every V and I card: one with no
//! AC spec has amplitude 0 and phase 0, so dy/d(acmag) = lambda_s and
//! dy/d(acphase) = 0, as ngspice publishes them.
//! One forward and one adjoint sweep (`acmatch.solveSweep`, so `.acmatch`'s
//! `freq.Stream` placement, its sibling's) serve every column: a
//! parameter costs acmatch's dG/dp, dC/dp fold, and a source reads the
//! adjoint at its rows, lambda_s = lambda^T e_s:
//!   dy/d(acmag)   = lambda_s e^(j phase)       (times m on an I card)
//!   dy/d(acphase) = lambda_s (j pi / 180) b_s  (per degree, as ngspice)
//! In: a run context and `Sens` with `ac` set. Out: complex point-major rows
//! (frequency, one column per parameter named as the DC form names it, then
//! `<src>_acmag` and `<src>_acphase` per source), plot "Sensitivity Analysis".
//! Divergence: ngspice reloads only DEVacLoad at the frozen operating point
//! (cktsens.c:916-934, `sens_load`); this is the total derivative, the
//! operating-point shift included. The two agree on a linear circuit and
//! differ on a nonlinear one where p moves the bias.
//! Cites ngspice inp2dot.c:481-570 (the card), cktsens.c:224-238 (names),
//! vsrc.c:14-15 and isrc.c:16-17 (`acmag`, `acphase`).
//!
//! Contents:
//! - `pub fn run(ctx: *const RunCtx, opts: sens.Options) !Result`

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const Complex = core.numerics.Complex;
const GROUND = core.GROUND;
const root = @import("../types.zig");
const dcmatch = @import("../dc/dcmatch.zig");
const sens = @import("../sweep/sens.zig");
const acmatch = @import("acmatch.zig");
const freq = @import("freq.zig");

/// The two columns each AC source adds, in order.
const source_suffixes = [_][]const u8{ "acmag", "acphase" };

/// Contract entry: complex point-major rows (frequency, dy/dp per
/// parameter, then dy/d(acmag) and dy/d(acphase) per AC source).
pub fn run(ctx: *const root.RunCtx, opts: sens.Options) !root.Result {
    assert(opts.ac != null);
    const scratch = ctx.scratch_allocator;
    const refs = try sens.sensParams(ctx.circuit, opts.card_names, scratch);
    defer scratch.free(refs);

    // One group per parameter at scale 1: each column is dy/dp.
    const groups = try dcmatch.Groups.init(scratch, refs, .{});
    defer groups.deinit(scratch);

    assert(groups.count() == refs.len);
    const freqs, const omegas = try freq.axis(scratch, opts.ac.?);
    defer freq.freeAxis(scratch, freqs);

    const sol = try acmatch.solveSweep(ctx, opts.output_node, opts.output_neg, omegas);
    defer scratch.free(sol.all);

    const dy = try scratch.alloc(Complex, refs.len * omegas.len);
    defer scratch.free(dy);

    try acmatch.groupShifts(ctx, refs, groups, omegas, sol, dy);
    return publish(ctx, opts, refs, freqs, sol, dy);
}

// ---- private ----

/// The result rows in the results arena, which owns every allocation here.
fn publish(ctx: *const root.RunCtx, opts: sens.Options, refs: []const root.ParamRef, freqs: []const f64, sol: acmatch.Solutions, dy: []const Complex) !root.Result {
    const a = ctx.allocator;
    const n: usize = ctx.circuit.n;
    const n_points = freqs.len;
    const srcs = opts.ac_sources;
    assert(dy.len == refs.len * n_points);
    const names = try a.alloc([]const u8, 1 + refs.len + source_suffixes.len * srcs.len);
    names[0] = "frequency";
    for (names[1..][0..refs.len], refs) |*name, ref| name.* = try sens.columnName(a, ctx.scratch_allocator, ctx, opts, ref);
    for (srcs, 0..) |src, s| for (source_suffixes, 0..) |suffix, i| {
        // ngspice prints keywords in lower case, as the DC form's columns.
        const name = try a.print("v({s}_{s})", .{ src.name, suffix });
        names[1 + refs.len + source_suffixes.len * s + i] = std.ascii.lowerString(name, name);
    };
    const row_len = 2 * names.len;
    const data = try a.alloc(f64, n_points * row_len);
    const per_degree: Complex = .{ .re = 0, .im = std.math.pi / 180.0 };
    for (0..n_points) |k| {
        const row = data[k * row_len ..][0..row_len];
        row[0] = freqs[k];
        row[1] = 0;
        for (0..refs.len) |g| {
            const d = dy[g * n_points + k];
            row[2 * (1 + g) ..][0..2].* = .{ d.re, d.im };
        }
        const adj = sol.adjoint(k);
        for (srcs, 0..) |src, s| {
            const lam = sourceAdjoint(adj, n, src);
            const mag = lam.mul(.{ .re = src.unit[0], .im = src.unit[1] });
            const phase = lam.mul(.{ .re = src.re, .im = src.im }).mul(per_degree);
            row[2 * (1 + refs.len + source_suffixes.len * s) ..][0..4].* = .{ mag.re, mag.im, phase.re, phase.im };
        }
    }
    return .{
        .plotname = "Sensitivity Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}

/// lambda^T e_s, the output's change per unit phasor of one source: the
/// drive subtracts it at `pos` and adds it at `neg` (`acExcitation`), and
/// lambda = conj(adj) of the stacked-real adjoint. Ground rows carry none.
fn sourceAdjoint(adj: []const f64, n: usize, src: sens.Options.AcSource) Complex {
    assert(adj.len >= 2 * n);
    assert(src.pos < n and src.neg < n);
    var lam = Complex.zero;
    if (src.pos != GROUND) lam = lam.sub(.{ .re = adj[src.pos], .im = -adj[n + src.pos] });
    if (src.neg != GROUND) lam = lam.add(.{ .re = adj[src.neg], .im = -adj[n + src.neg] });
    return lam;
}
