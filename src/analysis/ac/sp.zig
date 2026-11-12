//! S-parameter sweep (`.sp`) and HSPICE `.lin` network parameters. One
//! linearization gives G and C, the port z0 terminations go into the
//! frequency solver's copy of G, and each frequency is one lane of
//! `freq.Stream` with one right-hand side per port. The wave math is
//! `sp_network.zig`, and `.lin`'s columns after S `sp_lin.zig`.
//! In: a run context and the query's ports. Out: complex point-major rows
//! (frequency, S11, S12, ..., Snn, then `.lin`'s or ngspice donoise's
//! columns, `sp_noise.zig`).
//! Cites ngspice span.c (column and plot names, :544-551, :599-601);
//! HSPICE [SA Ch.17]; dev/analysis/s-parameters.md.
//!
//! Contents:
//! - `pub const Options = core.query.Sp`
//! - `pub const k_boltzmann`, `pub const t0_kelvin`
//! - `pub fn plan(ctx: *const RunCtx, opts: Options) !?freq.Plan`
//! - `pub fn run(ctx: *const RunCtx, opts: Options) !Result`
//! - `pub fn columns(n_ports: usize, opts: Options) usize`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Port = @import("core").query.Port;
const FreqSolver = @import("solver").freq_solve.FreqSolver;
const root = @import("../types.zig");
const freq = @import("freq.zig");
const net = @import("sp_network.zig");
const sp_lin = @import("sp_lin.zig");
const sp_noise = @import("sp_noise.zig");

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sp;

/// ngspice CONSTboltz (const.h), the constant the device noise models use.
pub const k_boltzmann = net.k_boltzmann;
/// Noise figure reference temperature, K (IEEE; HSPICE's RN and GN too).
pub const t0_kelvin = net.t0_kelvin;

/// Returns the leading multi-RHS sweep, including the one-port default's
/// series termination; null for `.lin` and donoise, which keep their sweep live
/// because later delay and noise solves continue that solver's pivot
/// history. Fails with error.InvalidQueryOptions for a `.net` query past
/// two ports.
pub fn plan(ctx: *const root.RunCtx, opts: Options) !?freq.Plan {
    if (opts.lin != null or opts.noise) return null;
    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    const ports: []const Port = if (opts.ports.len > 0) opts.ports else &one_port;
    if (opts.net and ports.len > 2) return error.InvalidQueryOptions;
    return try sweepPlan(ctx.scratch_allocator, ports, opts, ctx.circuit.n);
}

/// Contract entry: `opts.ports` (or the deck's drive source as port 1), the
/// full S matrix per frequency, then `.lin`'s columns (`sp_lin.names`) or
/// donoise's (`sp_noise.names`).
/// Fails with error.InvalidQueryOptions for a `.net` query past two ports.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    const ports: []const Port = if (opts.ports.len > 0) opts.ports else &one_port;
    const n_ports = ports.len;
    // `netRow`'s fixed 2x2 scratch; core/validate.zig does not bound it.
    if (opts.net and n_ports > 2) return error.InvalidQueryOptions;
    const z0 = try scratch.alloc(f64, n_ports);
    defer scratch.free(z0);

    for (ports, z0) |p, *z| z.* = p.z0;
    const n_points: usize = opts.sweep.count();
    const names = if (opts.lin) |lin| try sp_lin.names(a, n_ports, lin) else try sNames(a, n_ports, opts.noise);
    const row_len = names.len * 2;
    const data = try a.alloc(f64, n_points * row_len);
    const sw = try sweepPlan(scratch, ports, opts, n);
    defer sw.deinit(scratch);

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit();

    // The one-port default's z0: its branch row gains -z0 i_br.
    sw.configure(&fs);
    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, sw.omegas, sw.rhs, false);
    defer stream.deinit(scratch);

    stream.pre = ctx.freq_pre;
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * row_len ..][0..row_len];
        row[0] = sw.freqs[pt.k];
        row[1] = 0;
        if (opts.net) {
            net.netRow(n, ports, pt.x, row[2..]);
        } else for (0..n_ports) |p| net.writeColumn(n, ports, pt.x[p * nn ..][0..nn], row[2..], p);
    }
    if (opts.lin) |lin| {
        try sp_lin.fill(ctx, &fs, ports, z0, sw.omegas, sw.rhs, data, row_len, lin);
    } else if (opts.noise) try sp_noise.fill(ctx, &fs, ports, z0, sw.omegas, data, row_len, 1 + n_ports * n_ports);
    return .{
        // The job name ngspice opens the plot under (span.c:599-601).
        .plotname = if (opts.lin != null) "LIN Analysis" else "SP Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}

/// Returns the columns `run` publishes for `n_ports` ports, the frequency
/// included; `session.schemaOf` sizes the result with it. An empty port
/// list is `run`'s one port at the deck's drive source.
pub fn columns(n_ports: usize, opts: Options) usize {
    if (opts.lin) |lin| return sp_lin.columns(n_ports, lin);
    return 1 + n_ports * n_ports + if (opts.noise) sp_noise.columns(n_ports) else 0;
}

// ---- private ----

/// One unit drive per port: the sweep of `plan` and `run`. A deck's port
/// already has its z0 in series in the circuit (its portnum V card), so
/// only the one-port default at the drive source, an ideal V card, gets
/// its z0 here, on its branch row; `.net` keeps every port ideal.
fn sweepPlan(scratch: Allocator, ports: []const Port, opts: Options, n: usize) !freq.Plan {
    const rhs = try scratch.alloc(f64, ports.len * 2 * n);
    errdefer scratch.free(rhs);

    fillRhs(ports, n, rhs);
    const diag = try scratch.alloc(freq.Plan.Diagonal, if (opts.net or opts.ports.len != 0) 0 else ports.len);
    errdefer scratch.free(diag);

    for (diag, ports[0..diag.len]) |*d, port| d.* = .{ .row = port.branch, .value = -port.z0 };
    const freqs, const omegas = try freq.axis(scratch, opts.sweep);
    return .{ .freqs = freqs, .omegas = omegas, .rhs = rhs, .adjoint = false, .g_diagonal = diag };
}

/// The unit drive of each port: its source voltage on a branch port, or for
/// `.net` a unit current into `node` and out of `neg`.
fn fillRhs(ports: []const Port, n: usize, rhs: []f64) void {
    assert(rhs.len == ports.len * 2 * n);
    @memset(rhs, 0);
    for (ports, 0..) |port, p| {
        if (port.branch != Port.no_branch) {
            rhs[p * 2 * n + port.branch] = 1.0;
            continue;
        }
        if (port.node != root.GROUND) rhs[p * 2 * n + port.node] = 1.0;
        if (port.neg != root.GROUND) rhs[p * 2 * n + port.neg] = -1.0;
    }
}

/// `frequency`, the S columns, then donoise's when `noise`. ngspice names
/// them `S_<row>_<col>` (1-based) as UID_OTHER (span.c:544-551), and its
/// raw writer types every non-current UID as a voltage, so the file spells
/// them `v(S_1_1)`.
fn sNames(a: Allocator, n_ports: usize, noise: bool) Allocator.Error![]const []const u8 {
    const s_end = 1 + n_ports * n_ports;
    const names = try a.alloc([]const u8, s_end + if (noise) sp_noise.columns(n_ports) else 0);
    names[0] = "frequency";
    for (0..n_ports) |i| for (0..n_ports) |j| {
        names[1 + i * n_ports + j] = try a.print("v(S_{d}_{d})", .{ i + 1, j + 1 });
    };
    if (noise) try sp_noise.names(a, n_ports, names[s_end..]);
    return names;
}

test {
    _ = net;
    _ = sp_lin;
    _ = sp_noise;
}
