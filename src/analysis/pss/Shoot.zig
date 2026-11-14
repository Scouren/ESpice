//! One shooting solve between its period integrations: the DC point (or,
//! for an oscillator, its started orbit) in, a periodic x0, its period and
//! the solve's status out. `next` names the period the solve needs, the
//! caller integrates it (on the host, as lanes, or on the GPU), `done`
//! consumes the outcome; the Newton system (Phi - I) dx0 = -phi, each
//! free row (`free`) asking for no ringing instead, is the monodromy
//! recurrence (`Mono.zig`), a dense finite-difference Jacobian below
//! `krylov_threshold` unknowns, or JFNK GMRES. Pinned once `init` ran:
//! `sc` and `krylov` are reached by pointer.
//! Cites: pss.zig's; ngspice pssinit.c:16-20, dcpss.c:3560-3566, 3884 and
//! 4218 (an oscillator's one settling transient, whose time the shooting
//! continues); ngspice-45 dcpss.c:762-786 (the steadycoeff test).
//!
//! Contents:
//! - `pub const Request = struct`
//! - `pub const krylov_threshold: usize`
//! - `ShootingKrylovCtx.matvec` (the GMRES operator, `shootingMatvec`)
//! - `pub fn init(s: *Shoot, ckt: *root.Circuit, x_dc: []const f64, probes: []const u32, wave: []f64, options: Options, allocator: std.mem.Allocator) !void`
//! - `pub fn deinit(s: *Shoot) void`
//! - `pub fn next(s: *Shoot) error{QueryCancelled}!?Request`
//! - `pub fn done(s: *Shoot, ok: bool) !void`
//! - `pub fn runAlone(s: *Shoot) !SolveResult`

const std = @import("std");
const num = @import("core").numerics;
const converger = @import("solver").converger;
const dense_lu = @import("solver").dense_lu;
const Gmres = @import("solver").gmres.Gmres;
const root = @import("../types.zig");
const Mono = @import("Mono.zig");
const period = @import("period.zig");
const pss = @import("pss.zig");
const start_mod = @import("start.zig");

const Companion = period.Companion;
const MonoKrylovCtx = Mono.MonoKrylovCtx;
const Options = pss.Options;
const SolveResult = pss.SolveResult;
const integrateOnePeriod = period.integrateOnePeriod;
const take = root.take;
const startOscillator = start_mod.startOscillator;
const swingOf = start_mod.swingOf;

/// One shooting solve between its period integrations, so `solve` and
/// `runLanes` share every step but the integration: `next` names the
/// period the solve needs, the caller integrates it, `done` consumes the
/// outcome. The statements are `solve`'s own, in its order. Pinned once
/// `init` ran: `sc` and `krylov` are reached by pointer.
ckt: *root.Circuit,
ws: *converger.Workspace,
probes: []const u32,
wave: []f64,
/// The query's options; `opts` carries the period the solve is at.
options: Options,
opts: Options,
allocator: std.mem.Allocator,
n: usize,
arena: []f64,
x0: []f64,
x_end: []f64,
phi: []f64,
x0_pert: []f64,
x_end_pert: []f64,
dx0: []f64,
/// Dense path's FD Jacobian (n*n), else empty.
j_phi: []f64,
/// Krylov path's right-hand side (n), else empty.
neg_phi: []f64,
sc: Companion,
/// `sc.island`'s n entries, then `free`'s.
marks: []u32,
/// The free rows (`period.freeRows` at the start x0), ascending. A current
/// that only a loop of capacitors and voltage sources carries rings
/// (-1)^k undamped under trapezoid, so over an even step count its column
/// of Phi - I is zero and every amplitude of it is periodic. Its row asks
/// for no ringing instead: the base period's Nyquist component there
/// (`nyq`) zero, its Jacobian row the alternating step sums
/// (`Mono.Alternating`, or their finite difference), its column exactly
/// e_j.
free: []const u32,
/// Each free row's Nyquist component over the last base period.
nyq: []f64,
/// Two records of the free rows, each a period's (n_samples + 1) rows of
/// (1 + free.len), as `integrateOnePeriod` takes them: the base period's
/// past `Mono`, then a finite-difference period's. Empty without free rows.
rec: []f64,
krylov: ?Gmres,
/// The monodromy recurrence, unless over `mono_budget`.
mono: ?Mono = null,
iter: u16 = 0,
res_norm: f64 = std.math.inf(f64),
/// The last base period passed `shooting_tol` and `steady`.
settled: bool = false,
stage: Stage = .base,
/// The FD column the `.column` stage integrates next.
col: usize = 0,
/// Set when `stage` reaches `.done`.
result: SolveResult = undefined,
/// An autonomous start's swing ratio per period (start.zig's `Start`),
/// named when the solve finds no periodic orbit.
swing_ratio: f64 = 1,

/// One period integration: `x` holds its start and receives its end;
/// a non-empty `wave` records it as `integrateOnePeriod` documents.
pub const Request = struct { x: []f64, probes: []const u32, wave: []f64, opts: Options };

/// ponytail: node count at which the Newton solve switches from the dense FD
/// Jacobian (n+1 period integrations, O(n^2) storage) to matrix-free GMRES
/// (one integration per matvec).
pub const krylov_threshold: usize = 50;

const Shoot = @This();

const Stage = enum { base, column, final, done };

/// The largest relative period change one autonomous Newton step takes;
/// a longer step is shortened, all unknowns together.
const max_period_step: f64 = 0.2;

/// GMRES matvec context: one FD directional derivative of the shooting map.
const ShootingKrylovCtx = struct {
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    /// Current shooting iterate.
    x0: []const f64,
    /// phi(x0), already computed.
    phi: []const f64,
    /// Scratch, n long: the perturbed start and its endpoint.
    x_pert: []f64,
    x_end_pert: []f64,
    options: Options,
    n: usize,
    /// `Shoot.free`, their base Nyquist components and the record a
    /// perturbed period writes of them (`Shoot.rec`'s second half).
    free: []const u32,
    nyq: []const f64,
    rec: []f64,
    /// Set when an integration fails on cancellation or memory, which the
    /// void matvec cannot return; `krylovSolve` returns it.
    failure: ?error{ QueryCancelled, OutOfMemory } = null,

    /// The GMRES operator, `shootingMatvec`.
    pub const matvec = shootingMatvec;
};

/// `solve`'s setup: buffers, the GMRES workspace past
/// `krylov_threshold`, the baseline, and for an autonomous circuit the
/// oscillator start. Errors as `solve`'s; on error nothing is held.
pub fn init(s: *Shoot, ckt: *root.Circuit, x_dc: []const f64, probes: []const u32, wave: []f64, options: Options, allocator: std.mem.Allocator) !void {
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;
    const ncols = 1 + probes.len;
    std.debug.assert(wave.len == 0 or wave.len == (@as(usize, options.n_samples) + 1) * ncols);
    @memset(wave, 0);

    const use_krylov = n >= krylov_threshold;
    // One block for the whole continuation, every size known up front:
    //   x0, x_end, phi, x0_pert, x_end_pert, dx0   6n
    //   q_prev, q_cur, i_prev                      3n
    //   a_vals                                     nnz
    //   j_phi (dense) or neg_phi (Krylov)          n*n or n
    // and `marks`, 2n u32 of its own.
    const dense_extra = if (!use_krylov) n * n else 0;
    const krylov_extra = if (use_krylov) n else 0;
    const arena = try allocator.alloc(f64, 9 * n + nnz + dense_extra + krylov_extra);
    errdefer allocator.free(arena);
    const marks = try allocator.alloc(u32, 2 * n);
    errdefer allocator.free(marks);
    var off: usize = 0;
    const x0 = take(arena, &off, n);
    const x_end = take(arena, &off, n);
    const phi = take(arena, &off, n);
    const x0_pert = take(arena, &off, n);
    const x_end_pert = take(arena, &off, n);
    const dx0 = take(arena, &off, n);
    const sc: Companion = .{
        .q_prev = take(arena, &off, n),
        .q_cur = take(arena, &off, n),
        .i_prev = take(arena, &off, n),
        .a_vals = take(arena, &off, nnz),
        .island = marks[0..n],
    };
    // The unused path's buffer slices the arena to zero length so both
    // stay mutable []f64.
    const j_phi = if (!use_krylov) arena[off..][0 .. n * n] else arena[0..0];
    const neg_phi = if (use_krylov) arena[off..][0..n] else arena[0..0];
    var krylov: ?Gmres = null;
    if (use_krylov) {
        const m = @min(options.gmres_restart, @as(u32, @intCast(n)));
        krylov = try Gmres.init(allocator, @intCast(n), m);
    }
    errdefer if (krylov) |*k| k.deinit(allocator);

    const autonomous = options.osc_node != root.GROUND or options.phase_node == .largest_swing;
    var mono = try Mono.init(allocator, ckt, options.n_samples, autonomous);
    errdefer if (mono) |*m| m.deinit(allocator);
    try ckt.computeBaseline();
    const ws = try ckt.workspace();
    s.* = .{
        .mono = mono,
        .ckt = ckt,
        .ws = ws,
        .probes = probes,
        .wave = wave,
        .options = options,
        .opts = options,
        .allocator = allocator,
        .n = n,
        .arena = arena,
        .x0 = x0,
        .x_end = x_end,
        .phi = phi,
        .x0_pert = x0_pert,
        .x_end_pert = x_end_pert,
        .dx0 = dx0,
        .j_phi = j_phi,
        .neg_phi = neg_phi,
        .sc = sc,
        .marks = marks,
        .free = &.{},
        .nyq = &.{},
        .rec = &.{},
        .krylov = krylov,
    };
    num.copySimd(x0, x_dc[0..n]);
    if (autonomous) {
        const start = try startOscillator(ckt, ws, &s.sc, x0, options, allocator);
        s.options.osc_node = start.osc_node;
        s.opts.osc_node = start.osc_node;
        s.opts.period = start.period;
        s.opts.t_origin = start.t_origin;
        s.swing_ratio = start.swing_ratio;
    }
    // The free rows, from the planes `periodStart` leaves at x0.
    period.periodStart(ckt, &s.sc, x0, &.{}, &.{}, s.opts);
    const f = if (ckt.has_charge) period.freeRows(ckt, ckt.g_vals, ckt.c_vals, s.sc.island, s.opts.osc_node, marks[n..]) else 0;
    s.free = marks[n..][0..f];
    s.nyq = try allocator.alloc(f64, f);
    errdefer allocator.free(s.nyq);
    s.rec = try allocator.alloc(f64, if (f == 0) 0 else 2 * (@as(usize, options.n_samples) + 1) * (1 + f));
}

/// Frees what `init` allocated.
pub fn deinit(s: *Shoot) void {
    if (s.mono) |*m| m.deinit(s.allocator);
    if (s.krylov) |*k| k.deinit(s.allocator);
    s.allocator.free(s.rec);
    s.allocator.free(s.nyq);
    s.allocator.free(s.marks);
    s.allocator.free(s.arena);
    s.* = undefined;
}

/// The next period the solve needs, or null once `result` is set.
/// Fails only when a checkpoint cancels.
pub fn next(s: *Shoot) error{QueryCancelled}!?Request {
    const n = s.n;
    sw: switch (s.stage) {
        .base => {
            if (s.iter >= s.options.max_shooting_iter) {
                s.stage = .final;
                continue :sw .final;
            }
            if (s.iter != 0) try s.ckt.checkpoint(.{ .phase = .periodic, .completed = s.iter });
            // x0 -> x_end, recording the trajectory the monodromy
            // recurrence linearizes around.
            num.copySimd(s.x_end, s.x0);
            if (s.mono) |*m| return .{ .x = s.x_end, .probes = m.rows, .wave = m.traj, .opts = s.opts };
            return .{ .x = s.x_end, .probes = s.free, .wave = s.rec[0 .. s.rec.len / 2], .opts = s.opts };
        },
        .column => {
            // denseFdSolve's column `col`.
            const j = s.col;
            num.copySimd(s.x0_pert[0..n], s.x0[0..n]);
            var o = s.opts;
            if (o.osc_node != root.GROUND and j == o.osc_node) o.period *= 1 + o.fd_epsilon else s.x0_pert[j] += o.fd_epsilon;
            num.copySimd(s.x_end_pert, s.x0_pert);
            return .{ .x = s.x_end_pert, .probes = s.free, .wave = s.rec[s.rec.len / 2 ..], .opts = o };
        },
        .final => {
            num.copySimd(s.x_end, s.x0);
            return .{ .x = s.x_end, .probes = s.probes, .wave = s.wave, .opts = s.opts };
        },
        .done => return null,
    }
}

/// Consumes the outcome of the request `next` returned: `ok` is that
/// integration's return. Errors as `solve`'s: a Krylov solve's
/// cancellation or memory, `dense_lu`'s singular Jacobian, and an
/// autonomous solve's error.NoPeriodicSteadyState (`end`).
pub fn done(s: *Shoot, ok: bool) !void {
    const n = s.n;
    switch (s.stage) {
        .base => {
            if (!ok) return s.end(.{ .converged = false, .iterations = s.iter, .residual_norm = std.math.inf(f64) });
            // x_end + (-1)*x0 is exactly x_end - x0.
            num.copySimd(s.phi, s.x_end);
            num.axpy(s.phi, -1.0, s.x0);
            s.res_norm = num.normInf(s.phi);
            s.settled = s.res_norm < s.options.shooting_tol and s.steady();
            if (s.settled) {
                s.stage = .final;
                return;
            }
            s.baseNyquist();
            if (try s.monoStep()) return;
            if (s.krylov) |*k| {
                // ponytail: unpreconditioned; add an ILU preconditioner if GMRES stalls.
                try s.krylovSolve(k);
                s.update();
            } else {
                s.stage = .column;
                s.col = 0;
                try s.advanceColumn();
            }
        },
        .column => {
            const j = s.col;
            if (!ok) {
                unitColumn(s.j_phi, n, j);
            } else {
                // Column j is stride n in row-major J, so the store stays scalar.
                const col = s.x_end_pert[0..n];
                fdColumn(col, col, s.x0_pert[0..n], s.phi[0..n], 1.0 / s.opts.fd_epsilon);
                const rec = s.rec[s.rec.len / 2 ..];
                for (s.free, s.nyq, 0..) |row, b, a| col[row] = (period.nyquist(rec, 1 + s.free.len, 1 + a) - b) / s.opts.fd_epsilon;
                for (col, 0..) |d, row| s.j_phi[row * n + j] = d;
            }
            s.col += 1;
            try s.advanceColumn();
        },
        .final => {
            if (!ok) @memset(s.wave, 0);
            try s.end(.{ .converged = s.settled, .iterations = s.iter, .residual_norm = s.res_norm });
        },
        .done => unreachable,
    }
}

/// Integrates every period the solve asks for on the host, to `result`.
pub fn runAlone(s: *Shoot) !SolveResult {
    while (try s.next()) |r| try s.done(try integrateOnePeriod(s.ckt, s.ws, &s.sc, r.x, r.probes, r.wave, r.opts));
    return s.result;
}

// ---- private ----
/// Ends the solve on `result`. An autonomous solve that did not converge
/// found no periodic orbit: a decaying oscillation has none but its
/// equilibrium, which the pinned phase node excludes, so the shooting
/// residual stalls at the decay. That is error.NoPeriodicSteadyState,
/// after a line naming the residual and `swing_ratio`, never the last
/// iterate published as a steady state. A driven solve publishes its last
/// period with a warning (`pss.finish`).
fn end(s: *Shoot, result: SolveResult) error{NoPeriodicSteadyState}!void {
    // ponytail: convergence is the only certificate, so an unstable periodic
    // orbit the Newton lands on publishes as a steady state. The upgrade is
    // the Floquet eigenvalues of the converged monodromy (`Mono`): refuse
    // when any but the phase multiplier 1 has magnitude above 1.
    s.result = result;
    s.stage = .done;
    if (result.converged or s.options.osc_node == root.GROUND) return;
    const r = s.swing_ratio;
    const trend = if (r < 1) "below 1: it decays" else if (r > 1) "above 1: it grows" else if (r == 1) "1: it holds" else "not a number";
    std.debug.print("pss: no periodic steady state: the oscillator's shooting did not converge (residual {e}); " ++
        "over its start-up the swing changed by a factor {d:.6} a period ({s})\n", .{ result.residual_norm, r, trend });
    return error.NoPeriodicSteadyState;
}

/// ngspice's steadycoeff test (ngspice-45 dcpss.c:762-786) on the base
/// period just integrated, as `Options.steady_coeff` states it; true at 0.
/// The swing is read from the monodromy's trajectory of that period.
fn steady(s: *const Shoot) bool {
    const c = s.options.steady_coeff;
    if (c == 0) return true;
    const tol = s.options.tol;
    // ponytail: past `Mono`'s budget no trajectory is kept and the swing
    // is 0: the floor alone bounds the residual, tighter than ngspice. A
    // running max/min per unknown in the period integration lifts that.
    const traj: []const f64 = if (s.mono) |m| m.traj else &.{};
    for (s.phi[0..s.n], 0..) |r, i| {
        const name = s.ckt.nodeName(@intCast(i));
        const floor = if (name.len == 0 or std.mem.indexOfScalar(u8, name, '#') != null) tol.abstol else tol.vntol;
        const swing = if (traj.len == 0) 0 else swingOf(traj, s.n, @intCast(i));
        // Negated, so a NaN residual fails.
        if (!(@abs(r) <= (swing * tol.reltol + floor) * tol.trtol * c)) return false;
    }
    return true;
}

/// The Newton step on the recorded monodromy (`Mono`): every column of
/// the dense Jacobian in one recurrence pass, or GMRES on (Φ - I) with
/// one pass per matvec, the free rows' alternating sums riding each pass.
/// The autonomous period column is one more recurrence column. False,
/// nothing changed, when there is no record or a step Jacobian is
/// singular: the caller keeps its FD path.
fn monoStep(s: *Shoot) !bool {
    const m = if (s.mono) |*m| m else return false;
    const n = s.n;
    const f = s.free.len;
    m.build(s.ckt, s.opts);
    defer m.ready = false;
    const osc = s.opts.osc_node;
    if (s.krylov) |*k| {
        // A matvec's free-row sums, then d(phi)/d(ln T)'s (zero if driven).
        const sums = try s.allocator.alloc(f64, 2 * f);
        defer s.allocator.free(sums);
        @memset(sums, 0);
        // d(phi)/d(ln T) into x_end_pert.
        if (osc != root.GROUND) {
            @memset(s.x_end_pert[0..n], 0);
            if (!try m.apply(s.allocator, s.ckt, s.opts, s.x_end_pert[0..n], 1, 0, .{ .rows = s.free, .sums = sums[f..] })) return false;
        }
        s.krylovRhs();
        var ctx: MonoKrylovCtx = .{
            .mono = m,
            .gpa = s.allocator,
            .ckt = s.ckt,
            .options = s.opts,
            .n = n,
            .dphi_dlnt = s.x_end_pert[0..n],
            .free = s.free,
            .sums = sums[0..f],
            .dalt = sums[f..],
        };
        @memset(s.dx0[0..n], 0);
        _ = k.solve(&ctx, s.neg_phi[0..n], s.dx0[0..n], s.options.gmres_tol, s.options.gmres_max_restarts);
        if (ctx.failure) |err| return err;
        if (ctx.singular) return false;
        s.update();
        return true;
    }
    // Dense: J = Φ - I, row-major, from the n unit columns, the period
    // column `osc` (unless ground) entering zero; each free row its
    // alternating sums, from the same pass.
    const blk = try s.allocator.alloc(f64, n * n + f * n);
    defer s.allocator.free(blk);
    const cols = blk[0 .. n * n];
    const sums = blk[n * n ..];
    @memset(cols, 0);
    for (0..n) |j| cols[j * n + j] = if (j == osc and osc != root.GROUND) 0 else 1;
    const period_col: ?usize = if (osc != root.GROUND) osc else null;
    if (!try m.apply(s.allocator, s.ckt, s.opts, cols, n, period_col, .{ .rows = s.free, .sums = sums })) return false;
    for (0..n) |j| for (0..n) |row| {
        const col_osc = j == osc and osc != root.GROUND;
        s.j_phi[row * n + j] = cols[j * n + row] - @as(f64, if (row == j and !col_osc) 1 else 0);
    };
    for (s.free, 0..) |row, a| @memcpy(s.j_phi[row * n ..][0..n], sums[a * n ..][0..n]);
    for (s.free, s.nyq) |row, v| s.phi[row] = v;
    try dense_lu.factorizeSolveNeg(n, s.j_phi, s.phi[0..n], s.dx0);
    s.update();
    return true;
}

/// Each free row's Nyquist component over the base period just
/// integrated, into `nyq`, from the record its request carried.
fn baseNyquist(s: *Shoot) void {
    const f = s.free.len;
    for (s.nyq, s.free, 0..) |*v, row, a| v.* = if (s.mono) |m|
        period.nyquist(m.traj, s.n + 1, 1 + row)
    else
        period.nyquist(s.rec[0 .. s.rec.len / 2], 1 + f, 1 + a);
}

/// `neg_phi` as the Krylov right-hand side: -phi, each free row the
/// negated Nyquist component it asks to zero.
fn krylovRhs(s: *Shoot) void {
    num.scale(s.neg_phi[0..s.n], -1.0, s.phi[0..s.n]);
    for (s.free, s.nyq) |row, v| s.neg_phi[row] = -v;
}

/// Column j of the row-major n x n `a` as e_j.
fn unitColumn(a: []f64, n: usize, j: usize) void {
    for (0..n) |row| a[row * n + j] = if (row == j) 1 else 0;
}

/// The FD stage from column `col`: each free column is exactly e_j (Φ - I
/// leaves it zero, its own Nyquist row 1, the others' 0) with no period
/// integrated; past the last column, the Newton step.
fn advanceColumn(s: *Shoot) !void {
    const n = s.n;
    while (s.col < n and std.mem.indexOfScalar(u32, s.free, @intCast(s.col)) != null) : (s.col += 1) unitColumn(s.j_phi, n, s.col);
    if (s.col < n) return;
    for (s.free, s.nyq) |row, v| s.phi[row] = v;
    try dense_lu.factorizeSolveNeg(n, s.j_phi, s.phi[0..n], s.dx0);
    s.stage = .base;
    s.update();
}

/// The damped Newton update that ends a shooting iteration.
fn update(s: *Shoot) void {
    var damping: f64 = 1.0;
    const osc = s.options.osc_node;
    if (osc != root.GROUND) {
        const d_ln_t = s.dx0[osc];
        s.dx0[osc] = 0;
        if (@abs(d_ln_t) > max_period_step) damping = max_period_step / @abs(d_ln_t);
        s.opts.period *= 1 + damping * d_ln_t;
    }
    num.axpy(s.x0, damping, s.dx0);
    s.iter += 1;
}

/// w = (Phi - I) v by one FD period integration:
/// w = (phi(x0 + eps*v) - phi(x0)) / eps, each free row the FD of its
/// Nyquist component instead, and a free column exactly e_j (no
/// perturbation along it). A failed integration returns w = 0, which
/// GMRES treats as a null direction. Autonomous: v[osc] moves ln T
/// instead of x0[osc].
fn shootingMatvec(ctx: *ShootingKrylovCtx, v: []const f64, w: []f64) void {
    const n = ctx.n;
    const inv_eps = 1.0 / ctx.options.fd_epsilon;

    num.copySimd(ctx.x_pert[0..n], ctx.x0[0..n]);
    num.axpy(ctx.x_pert[0..n], ctx.options.fd_epsilon, v[0..n]);
    for (ctx.free) |row| ctx.x_pert[row] = ctx.x0[row];
    var opts = ctx.options;
    const osc = opts.osc_node;
    if (osc != root.GROUND) {
        ctx.x_pert[osc] = ctx.x0[osc];
        opts.period *= 1 + ctx.options.fd_epsilon * v[osc];
    }

    num.copySimd(ctx.x_end_pert, ctx.x_pert);
    const ok = integrateOnePeriod(ctx.ckt, ctx.ws, ctx.sc, ctx.x_end_pert, ctx.free, ctx.rec, opts) catch |err| blk: {
        ctx.failure = ctx.failure orelse err;
        break :blk false;
    };
    if (!ok) {
        // ponytail: a zero column is safer than propagating NaN.
        @memset(w[0..n], 0);
        return;
    }
    fdColumn(w[0..n], ctx.x_end_pert, ctx.x_pert, ctx.phi, inv_eps);
    const cols = 1 + ctx.free.len;
    for (ctx.free, ctx.nyq, 0..) |row, b, a| w[row] = (period.nyquist(ctx.rec, cols, 1 + a) - b) * inv_eps + v[row];
}

/// out = ((x_end - x_start) - phi) * inv_eps, the FD derivative of phi;
/// `out` may alias `x_end`.
fn fdColumn(out: []f64, x_end: []const f64, x_start: []const f64, phi: []const f64, inv_eps: f64) void {
    num.sub(out, x_end, x_start);
    num.sub(out, out, phi);
    num.scale(out, inv_eps, out);
}

/// Krylov path past `Mono`: solves the Newton system, (Phi - I) dx0 =
/// -phi with each free row asking for no ringing, by matrix-free GMRES
/// from a zero start.
fn krylovSolve(s: *Shoot, krylov: *Gmres) error{ QueryCancelled, OutOfMemory }!void {
    const n = s.n;
    s.krylovRhs();
    var ctx: ShootingKrylovCtx = .{
        .ckt = s.ckt,
        .ws = s.ws,
        .sc = &s.sc,
        .x0 = s.x0,
        .phi = s.phi,
        .x_pert = s.x0_pert,
        .x_end_pert = s.x_end_pert,
        .options = s.opts,
        .n = n,
        .free = s.free,
        .nyq = s.nyq,
        .rec = s.rec[s.rec.len / 2 ..],
    };
    @memset(s.dx0[0..n], 0);
    _ = krylov.solve(&ctx, s.neg_phi[0..n], s.dx0[0..n], s.opts.gmres_tol, s.opts.gmres_max_restarts);
    if (ctx.failure) |err| return err;
}
