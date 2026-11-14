//! S-parameter sweep (`.sp`) and HSPICE `.lin` network parameters. One
//! linearization gives G and C, the port z0 terminations go into the
//! frequency solver's copy of G, and each frequency is one lane of
//! `freq.Stream` with one right-hand side per port leg. The wave math is
//! `sp_network.zig`, the mixed-mode basis of balanced ports `sp_basis.zig`,
//! and `.lin`'s columns after S `sp_lin.zig`.
//! In: a run context and the query's ports. Out: complex point-major rows
//! in ngspice's column order: frequency, the probes (node voltages and
//! branch currents) of the last port's drive, S11, S12, ..., Snn over the
//! modes, Y and Z (derived from S on the host, so a lane's replayed sweep
//! publishes them too), then donoise's columns (`sp_noise.zig`); `.lin`
//! publishes frequency, S and its own columns (`sp_lin.zig`).
//! Cites ngspice span.c (column and plot names, :516, :544-571, :599-601;
//! the port drives, :825), cktspdum.c:146-149 (the last drive's solution
//! dumped ahead of S, Y and Z); HSPICE [SA Ch.17];
//! dev/analysis/s-parameters.md.
//!
//! Contents:
//! - `pub const Options = core.query.Sp`
//! - `pub const k_boltzmann`, `pub const t0_kelvin`
//! - `pub fn plan(ctx: *const RunCtx, opts: Options) !?freq.Plan`
//! - `pub fn run(ctx: *const RunCtx, opts: Options) !Result`
//! - `pub fn columns(n_modes: usize, n_probes: usize, opts: Options) usize`
//! - `pub fn modeCount(ports: []const Port) usize`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Complex = @import("core").numerics.Complex;
const Port = @import("core").query.Port;
const FreqSolver = @import("solver").freq_solve.FreqSolver;
const root = @import("../types.zig");
const freq = @import("freq.zig");
const net = @import("sp_network.zig");
const sp_lin = @import("sp_lin.zig");
const sp_noise = @import("sp_noise.zig");
const Basis = @import("sp_basis.zig").Basis;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sp;

/// ngspice CONSTboltz (const.h), the constant the device noise models use.
pub const k_boltzmann = net.k_boltzmann;
/// Noise figure reference temperature, K (IEEE; HSPICE's RN and GN too).
pub const t0_kelvin = net.t0_kelvin;

/// Returns the leading multi-RHS sweep, one drive per port leg, including
/// the one-port default's series termination; null for `.lin` and donoise,
/// which keep their sweep live because later delay and noise solves
/// continue that solver's pivot history. Fails with
/// error.InvalidQueryOptions for a `.net` query past two legs.
pub fn plan(ctx: *const root.RunCtx, opts: Options) !?freq.Plan {
    if (opts.lin != null or opts.noise) return null;
    const scratch = ctx.scratch_allocator;
    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    var basis = try Basis.init(scratch, if (opts.ports.len > 0) opts.ports else &one_port, .{ false, false });
    defer basis.deinit(scratch);

    if (opts.net and basis.legs.len > 2) return error.InvalidQueryOptions;
    return try sweepPlan(scratch, basis.legs, opts, ctx.circuit.n);
}

/// Contract entry: `opts.ports` (or the deck's drive source as port 1), the
/// full S matrix over the modes (`sp_basis.zig`; a balanced port is two)
/// per frequency, then `.lin`'s columns (`sp_lin.names`), or Y, Z and
/// donoise's (`sp_noise.names`). Without `.lin`, `ctx.probes` come first,
/// read off the drive of the last port (the highest port number; a
/// balanced one's + leg), as ngspice dumps them. An open or shorted port
/// (singular E -+ S) gives non-finite Y or Z entries, not an error.
/// Fails with error.InvalidQueryOptions for a `.net` query past two legs,
/// a balanced query past `sp_basis.legs_max` legs, or a `.lin` common mode
/// asked of a single-ended port.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    const ports: []const Port = if (opts.ports.len > 0) opts.ports else &one_port;
    var basis = try Basis.init(scratch, ports, if (opts.lin) |l| l.common else .{ false, false });
    defer basis.deinit(scratch);

    // Solves run over the legs; every published matrix is over the modes,
    // one per leg.
    const legs = basis.legs;
    const n_modes = legs.len;
    // `netRow`'s fixed 2x2 scratch; core/validate.zig does not bound it.
    if (opts.net and n_modes > 2) return error.InvalidQueryOptions;
    const n_points: usize = opts.sweep.count();
    const probes: []const u32 = if (opts.lin == null) ctx.probes else &.{};
    const names = if (opts.lin) |lin| try sp_lin.names(a, n_modes, lin) else try sNames(ctx, n_modes, opts.noise);
    assert(names.len == columns(n_modes, probes.len, opts));
    const row_len = names.len * 2;
    const s_col = 1 + probes.len;
    const n2 = n_modes * n_modes;
    // `net.params`' S, Y, Z and H, then its scratch.
    const work = try scratch.alloc(Complex, net.paramCount(n_modes) + n2);
    defer scratch.free(work);

    const data = try a.alloc(f64, n_points * row_len);
    const sw = try sweepPlan(scratch, legs, opts, n);
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
        // Leg k < ports.len is port k's (first) leg.
        const last = pt.x[(ports.len - 1) * nn ..][0..nn];
        for (probes, 1..) |node, col| {
            row[col * 2] = last[node];
            row[col * 2 + 1] = last[n + node];
        }
        const s_row = row[2 * s_col ..];
        if (opts.net) {
            net.netRow(n, legs, pt.x, s_row);
        } else for (0..n_modes) |p| net.writeColumn(n, legs, pt.x[p * nn ..][0..nn], s_row, p);
        try basis.toModes(s_row[0 .. 2 * n2]);
        if (opts.lin != null) continue;
        const syz = work[0..net.paramCount(n_modes)];
        net.readComplex(s_row[0 .. 2 * n2], syz[0..n2]);
        net.params(basis.z0, .{ 0, 1 }, syz, work[syz.len..]);
        net.writeComplex(syz[n2..][0 .. 2 * n2], s_row[2 * n2 ..][0 .. 4 * n2]);
    }
    if (opts.lin) |lin| {
        try sp_lin.fill(ctx, &fs, &basis, sw.omegas, sw.rhs, data, row_len, lin);
    } else if (opts.noise) try sp_noise.fill(ctx, &fs, &basis, sw.omegas, data, row_len, s_col);
    return .{
        // The job name ngspice opens the plot under (span.c:599-601).
        .plotname = if (opts.lin != null) "LIN Analysis" else "SP Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}

/// Returns the columns `run` publishes for `n_modes` modes (`modeCount`)
/// over a deck of `n_probes` probes, the frequency included;
/// `session.schemaOf` sizes the result with it.
pub fn columns(n_modes: usize, n_probes: usize, opts: Options) usize {
    if (opts.lin) |lin| return sp_lin.columns(n_modes, lin);
    return 1 + n_probes + 3 * n_modes * n_modes + if (opts.noise) sp_noise.columns(n_modes) else 0;
}

/// Returns the modes (published ports) of `ports`: a balanced port counts
/// twice. At least 1, because an empty list means `run`'s one port at the
/// deck's drive source.
pub fn modeCount(ports: []const Port) usize {
    var n: usize = @max(ports.len, 1);
    for (ports) |p| n += @intFromBool(p.balanced != null);
    return n;
}

// ---- private ----

/// One unit drive per port leg (`Basis.legs`): the sweep of `plan` and
/// `run`. A deck's port already has its z0 in series in the circuit (its
/// portnum V card), so only the one-port default at the drive source, an
/// ideal V card, gets its z0 here, on its branch row; `.net` keeps every
/// port ideal.
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

/// `frequency`, the probes, the S, Y and Z columns, then donoise's when
/// `noise`. ngspice names them `S_<row>_<col>` (1-based, and Y_, Z_) as
/// UID_OTHER (span.c:544-571), and its raw writer types every non-current
/// UID as a voltage, so the file spells them `v(S_1_1)`.
fn sNames(ctx: *const root.RunCtx, n_ports: usize, noise: bool) Allocator.Error![]const []const u8 {
    const a = ctx.allocator;
    const head = try root.probeNames(ctx, "frequency");
    const n2 = n_ports * n_ports;
    const end = head.len + 3 * n2;
    const names = try a.alloc([]const u8, end + if (noise) sp_noise.columns(n_ports) else 0);
    @memcpy(names[0..head.len], head);
    for ([_][]const u8{ "S", "Y", "Z" }, 0..) |m, b| for (0..n_ports) |i| for (0..n_ports) |j| {
        names[head.len + b * n2 + i * n_ports + j] = try a.print("v({s}_{d}_{d})", .{ m, i + 1, j + 1 });
    };
    if (noise) try sp_noise.names(a, n_ports, names[end..]);
    return names;
}

test {
    _ = net;
    _ = sp_lin;
    _ = sp_noise;
    _ = @import("sp_basis.zig");
}

test modeCount {
    // Oracle: the port list itself; a balanced port is two modes.
    try std.testing.expectEqual(@as(usize, 1), modeCount(&.{}));
    try std.testing.expectEqual(@as(usize, 3), modeCount(&.{
        .{ .node = 1, .branch = 4, .balanced = .{ .node = 2, .neg = 0, .branch = 5 } },
        .{ .node = 3, .branch = 6 },
    }));
}
