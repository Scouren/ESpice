//! One shooting period: a start state x0 and a fixed step count in, x(T)
//! out by fixed-step trapezoid, with each step's Newton on the trapezoid
//! companion, the device commits, and (when asked) one wave row per step.
//! The lane drivers in pss.zig run the same start, hook and accept per lane
//! around a lane Newton.
//! Cites: Verilog-A LRM §4.6.1 (sources follow their waveform only in the
//! transient phase).
//!
//! Contents:
//! - `pub const Companion = struct`
//! - `pub const PeriodHook = integrator.Hook(.trapezoidal)`
//! - `pub const no_island: u32`
//! - `pub fn integrateOnePeriod(ckt: *root.Circuit, ws: *converger.Workspace, sc: *Companion, x: []f64, probes: []const u32, wave: []f64, options: Options) error{ QueryCancelled, OutOfMemory }!bool`
//! - `pub fn periodStart(ckt: *root.Circuit, sc: *Companion, x: []const f64, probes: []const u32, wave: []f64, options: Options) void`
//! - `pub fn markIslands(ckt: *const root.Circuit, c_vals: []const f64, island: []u32) void`
//! - `pub fn seamCut(ckt: *const root.Circuit, c_vals: []const f64, island: []const u32, v: []f64) void`
//! - `pub fn freeRows(ckt: *const root.Circuit, g_vals: []const f64, c_vals: []const f64, island: []const u32, skip: u32, out: []u32) usize`
//! - `pub fn nyquist(wave: []const f64, cols: usize, col: usize) f64`
//! - `pub fn stepTime(options: Options, k: usize) f64`
//! - `pub fn stepOptions(options: Options) converger.Options`
//! - `pub fn periodHook(sc: *Companion, alpha: f64, has_charge: bool) PeriodHook`
//! - `pub fn periodAccept(ckt: *root.Circuit, hook: *const PeriodHook, x: []const f64, probes: []const u32, wave: []f64, k: usize, t: f64, converged: bool) bool`

const std = @import("std");
const num = @import("core").numerics;
const converger = @import("solver").converger;
const root = @import("../types.zig");
const integrator = @import("../tran/integrator.zig");
const Options = @import("core").query.Pss;

/// Trapezoidal companion state, reused across every period integration.
pub const Companion = struct {
    /// q at the previous accepted step.
    q_prev: []f64,
    /// q(x) from the last Newton assemble.
    q_cur: []f64,
    /// Dynamic current of the previous accepted step.
    i_prev: []f64,
    /// G + alpha*C, nnz long.
    a_vals: []f64,
    /// Each unknown's zero-charge island at the period's start
    /// (`markIslands`), n long; `periodStart`'s scratch.
    island: []u32,
};

/// Newton hook for one fixed step: residual adds
/// alpha*(q(x) - q_prev) - i_prev with alpha = 2/dt, matrix G + alpha*C.
pub const PeriodHook = integrator.Hook(.trapezoidal);

/// `markIslands`' mark for an unknown in no zero-charge island.
pub const no_island: u32 = std.math.maxInt(u32);

/// Integrates x in place over [0, T] in n_samples trapezoid steps, the
/// sources at `t_origin` plus t. A non-empty `wave` receives n_samples+1
/// point-major rows [t, v(probes)...] of stride 1 + probes.len, t from the
/// period's start. Returns false on the first step whose Newton fails.
pub fn integrateOnePeriod(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x: []f64,
    probes: []const u32,
    wave: []f64,
    options: Options,
) error{ QueryCancelled, OutOfMemory }!bool {
    const steps: usize = options.n_samples;
    const dt = options.period / @as(f64, @floatFromInt(steps));
    periodStart(ckt, sc, x, probes, wave, options);
    for (0..steps) |k| {
        const t = stepTime(options, k);
        const t_sim = options.t_origin + t;
        const hook = periodHook(sc, 2.0 / dt, ckt.has_charge);
        ckt.setSimState(.{ .t = t_sim, .dt = dt, .kind = .tran });
        const nr = converger.run(ckt, ws, x, t_sim, stepOptions(options), hook) catch |err| switch (err) {
            error.QueryCancelled, error.OutOfMemory => |e| return e,
            else => null, // else: a numerical failure fails the period
        };
        if (!periodAccept(ckt, &hook, x, probes, wave, k, t, nr != null and nr.?.converged)) return false;
    }
    return true;
}

/// `integrateOnePeriod`'s start: the transient-phase sim state at
/// `t_origin`, the trapezoid seam state at x, and the t = 0 wave row.
pub fn periodStart(ckt: *root.Circuit, sc: *Companion, x: []const f64, probes: []const u32, wave: []f64, options: Options) void {
    const n: usize = ckt.n;
    const dt = options.period / @as(f64, @floatFromInt(options.n_samples));
    // Sources follow their waveform only under `analysis("tran")` (§4.6.1),
    // so every evaluated point declares the transient phase.
    ckt.setSimState(.{ .t = options.t_origin, .dt = dt, .kind = .tran });
    if (ckt.has_charge) {
        ckt.eval(x, options.t_origin);
        num.copySimd(sc.q_prev[0..n], ckt.q_vec[0..n]);
        // Carry the trapezoid state across the period seam: a converged step
        // leaves i_prev = -f(x), so at x0 it is -rhs. A zero seed loses
        // dt*i0/2 of charge per period. Being a function of x0, it sits
        // inside the shooting Jacobian; `seamCut` keeps the part charge
        // carries.
        for (sc.i_prev[0..n], ckt.rhs[0..n]) |*i, f| i.* = -f;
        markIslands(ckt, ckt.c_vals, sc.island);
        seamCut(ckt, ckt.c_vals, sc.island, sc.i_prev[0..n]);
    }
    if (wave.len != 0) {
        const row = wave[0 .. 1 + probes.len];
        row[0] = 0;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
    }
}

/// Marks the zero-charge islands of `c_vals`: unknowns joined by nonzero C
/// entries (ground aside) whose rows' charges sum to zero, every column's
/// entries over the island cancelling, so the island's summed KCL row
/// carries no dynamic current at any x. A row without C entries is one
/// alone; the two nodes of a capacitor that only inductors and resistors
/// meet (hartley's c1) are one. `island[i]` is the island's lowest
/// unknown, or `no_island`. Asserts `island` holds n entries.
pub fn markIslands(ckt: *const root.Circuit, c_vals: []const f64, island: []u32) void {
    const n: usize = ckt.n;
    std.debug.assert(island.len == n);
    std.debug.assert(c_vals.len >= ckt.nnz);
    for (island, 0..) |*p, i| p.* = @intCast(i);
    // Union under the lower root, so every parent is at most its child.
    for (1..n) |j| for (ckt.col_ptr[j]..ckt.col_ptr[j + 1]) |s| {
        if (ckt.row_idx[s] == 0 or c_vals[s] == 0) continue;
        const a = find(island, ckt.row_idx[s]);
        const b = find(island, @intCast(j));
        island[@max(a, b)] = @min(a, b);
    };
    // Parents precede children, so one ascending pass flattens to roots.
    for (island) |*p| p.* = island[p.*];
    // A column whose entries do not cancel charges its island.
    for (1..n) |j| {
        var sum: f64 = 0;
        var mag: f64 = 0;
        for (ckt.col_ptr[j]..ckt.col_ptr[j + 1]) |s| if (ckt.row_idx[s] != 0) {
            sum += c_vals[s];
            mag += @abs(c_vals[s]);
        };
        // ponytail: 1e-12 of the column separates rounding from a charge to
        // ground; a grounded capacitor under 1e-12 of its floating
        // neighbours reads as none, a seed error of that order.
        const r = island[j];
        if (@abs(sum) > 1e-12 * mag and r != no_island) island[r] = no_island;
    }
    for (island) |*p| {
        if (p.* != no_island and island[p.*] == no_island) p.* = no_island;
    }
}

/// Cuts the seam seed `v` (x0's dynamic current, one per row) to what
/// charge carries: zero on a row without a diagonal C entry, and zero
/// summed over each `markIslands` island, its lowest row taking the rest.
/// Trapezoid carries a current no charge backs as i_k = -i_{k-1},
/// undamped: over an even step count its multiplier is +1 and no x0
/// closes it, a singular shooting Jacobian. A consistent x0 seeds such
/// rows nothing, so the cut leaves a periodic orbit's seed as it is.
/// ponytail: charge without a diagonal C entry keeps a zero seed.
pub fn seamCut(ckt: *const root.Circuit, c_vals: []const f64, island: []const u32, v: []f64) void {
    const n: usize = ckt.n;
    std.debug.assert(island.len == n);
    std.debug.assert(v.len == n);
    for (v, island, ckt.diag_slots[0..n], 0..) |*e, r, d, i| {
        if (c_vals[d] == 0 or r == i) e.* = 0;
    }
    // A root precedes its island, so each read of `e` is the row's own.
    for (v, island, 0..) |e, r, i| {
        if (r != no_island and r != i) v[r] -= e;
    }
}

/// Lists in `out` the free rows of shooting at a period's start, from its
/// planes `g_vals` and `c_vals` and `markIslands`' `island` on them, and
/// returns how many: each unknown j but `skip` that no charge reads (C
/// column j zero) and whose G column is a dynamic current `seamCut`
/// keeps, as a voltage source's current closing a loop of capacitors
/// (colpitt's vcc, c2, c1, ccs). Trapezoid carries a change of such an
/// x0[j] as (-1)^k e_j, undamped: over an even step count its column of
/// Φ - I is zero and the period leaves that ringing's amplitude free.
/// Asserts `out` holds n entries.
/// ponytail: read at one x0. A reader of the loop current whose stamp
/// moves with x (a B source on i(vs)) leaves the column only nearly zero;
/// that row's periodicity residual then stalls, reported, short of the
/// shooting tolerance.
pub fn freeRows(ckt: *const root.Circuit, g_vals: []const f64, c_vals: []const f64, island: []const u32, skip: u32, out: []u32) usize {
    const n: usize = ckt.n;
    std.debug.assert(island.len == n);
    std.debug.assert(out.len == n);
    var count: usize = 0;
    for (1..n) |j| {
        const lo = ckt.col_ptr[j];
        const hi = ckt.col_ptr[j + 1];
        var drives = false;
        const kept = for (lo..hi) |s| {
            const r = ckt.row_idx[s];
            if (r == 0) continue;
            if (c_vals[s] != 0) break false;
            if (g_vals[s] == 0) continue;
            drives = true;
            // `seamCut` zeroes a row without charge, and keeps an island's
            // rows only while they sum to zero.
            if (c_vals[ckt.diag_slots[r]] == 0) break false;
            if (island[r] != no_island and islandSum(g_vals[lo..hi], ckt.row_idx[lo..hi], island, island[r]) != 0) break false;
        } else true;
        if (!kept or !drives or j == skip) continue;
        out[count] = @intCast(j);
        count += 1;
    }
    return count;
}

/// Column `col`'s Nyquist component (1/N) Σ_{k<N} (-1)^k x_k over a
/// period's N + 1 rows of `cols` in `wave`, as `integrateOnePeriod`
/// records them: the amplitude of a trapezoid ringing.
pub fn nyquist(wave: []const f64, cols: usize, col: usize) f64 {
    std.debug.assert(col < cols);
    std.debug.assert(wave.len % cols == 0 and wave.len > cols);
    const steps = wave.len / cols - 1;
    var sum: f64 = 0;
    for (0..steps) |k| {
        const x = wave[k * cols + col];
        sum += if (k % 2 == 0) x else -x;
    }
    return sum / @as(f64, @floatFromInt(steps));
}

/// The end time of step k of a period, from the period's start: the
/// sources see `t_origin` plus it.
pub fn stepTime(options: Options, k: usize) f64 {
    return options.period * @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(options.n_samples));
}

/// One step's Newton options: the shooting budget and tolerance, and
/// `.options dv`, which HSPICE applies to every transient step. Every
/// other field is `converger.Options`' default.
pub fn stepOptions(options: Options) converger.Options {
    return .{ .max_iter = options.max_newton_iter, .abstol = options.newton_tol, .dv = options.tol.dv orelse std.math.inf(f64) };
}

/// The companion hook of one step at `alpha` = 2/dt.
pub fn periodHook(sc: *Companion, alpha: f64, has_charge: bool) PeriodHook {
    return .{
        .method = {},
        .c = .{ .ag0 = alpha, .ag2 = 0 },
        .q_prev = sc.q_prev,
        .i_prev = sc.i_prev,
        .q_cur = sc.q_cur,
        .a_vals = sc.a_vals,
        .has_charge = has_charge,
    };
}

/// Step k's end: a failed Newton reverts the devices and fails the
/// period (false); a converged one commits them, advances the trapezoid
/// history and records wave row k + 1 at t.
pub fn periodAccept(ckt: *root.Circuit, hook: *const PeriodHook, x: []const f64, probes: []const u32, wave: []f64, k: usize, t: f64, converged: bool) bool {
    if (!converged) {
        _ = ckt.stateCtl(.revert);
        return false;
    }
    _ = ckt.stateCtl(.commit);
    if (hook.has_charge) hook.accept(ckt.n);
    if (wave.len != 0) {
        const ncols = 1 + probes.len;
        const row = wave[(k + 1) * ncols ..][0..ncols];
        row[0] = t;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
    }
    return true;
}

// ---- private ----

/// The root of `i` in the union-find forest `p`, halving the path.
fn find(p: []u32, i: u32) u32 {
    var x = i;
    for (0..p.len) |_| {
        if (p[x] == x) return x;
        p[x] = p[p[x]];
        x = p[x];
    }
    unreachable; // a forest's path is shorter than its node count
}

/// Σ `vals` over the entries whose row (`rows`, ground aside) lies in the
/// island rooted at `top`.
fn islandSum(vals: []const f64, rows: []const u32, island: []const u32, top: u32) f64 {
    var sum: f64 = 0;
    for (vals, rows) |v, r| {
        if (r != 0 and island[r] == top) sum += v;
    }
    return sum;
}
