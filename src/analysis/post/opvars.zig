//! Device operating-point variables (`@m1[gm]`, #236): the columns an
//! `.op`, `.dc` or `.tran` result gains from each named instance evaluated
//! alone at every recorded point (`Hooks.local_eval`). Its collapsed
//! unknowns merge into their nodes and its internal nodes are eliminated,
//! so a partial is what the terminals show: G_t = G_PP - G_PI G_II⁻¹ G_IP,
//! and C_t = dY/ds at s = 0 of the same complement of G + sC, which is
//! C_PP - C_PI K - G_PI G_II⁻¹ (C_IP - C_II K) with K = G_II⁻¹ G_IP.
//! Names and terminal order (d, g, s, b) after ngspice's MOSFETs. A device
//! parameter (`@v1[dc]`) is read from its row, and along the `.dc` that
//! sweeps it is the sweep's value. At a `.tran` row a terminal current
//! carries its charging current and a conductance its companion, as
//! ngspice's do (`<dev>load.c`): the integrator replayed over the
//! instance's charges at the recorded rows, each under the step that
//! reached it (`Result.steps`, `integrator.stepCoeffs`), as
//! `tran/emir.zig` runs it live. CPU and GPU runs record the same steps.
//! In: a recorded result and its circuit. Out: the result with one column
//! per `deck.opvars` entry.
//! Cites ngspice (the variable names and terminal order, NIintegrate);
//! #236.
//!
//! Contents:
//! - `pub fn publish(a: Allocator, scratch: Allocator, circuit: *const Circuit, deck: *const Deck, res: Result, job: Query) !Result`

const std = @import("std");
const core = @import("core");
const abi = @import("device").abi;
const dense_lu = @import("solver").dense_lu;
const types = @import("../types.zig");
const integrator = @import("../tran/integrator.zig");
const Method = core.query.Method;

/// A merged evaluation's dense `n x n` partials and its internal unknowns.
const Terminals = struct {
    n: usize,
    g: []const f64,
    c: []const f64,
    in: []const u32,
    /// At least `in.len * (in.len + 2)` values, and `in.len` pivots.
    work: []f64,
    piv: []u32,

    /// ∂f_i/∂x_j and ∂q_i/∂x_j between terminals `i` and `j` with the
    /// internal unknowns eliminated; NaN when G_II is singular.
    // ponytail: factors G_II per call, a few times per value; factor once
    // per point if a deck saves many variables of large-node models.
    fn partial(t: Terminals, i: usize, j: usize) [2]f64 {
        const n = t.n;
        var g = t.g[i * n + j];
        var c = t.c[i * n + j];
        const ni = t.in.len;
        if (ni == 0) return .{ g, c };
        var off: usize = 0;
        const lu = types.take(t.work, &off, ni * ni);
        const k = types.take(t.work, &off, ni);
        const m = types.take(t.work, &off, ni);
        for (t.in, 0..) |r, a| for (t.in, 0..) |col, b| {
            lu[a * ni + b] = t.g[r * n + col];
        };
        dense_lu.factorize(ni, lu, t.piv) catch return @splat(std.math.nan(f64));
        for (t.in, k) |r, *kv| kv.* = t.g[r * n + j];
        dense_lu.solveFactored(ni, lu, t.piv, k, k);
        for (t.in, m) |r, *mv| {
            var s = t.c[r * n + j];
            for (t.in, k) |col, kv| s -= t.c[r * n + col] * kv;
            mv.* = s;
        }
        dense_lu.solveFactored(ni, lu, t.piv, m, m);
        for (t.in, k, m) |col, kv, mv| {
            g -= t.g[i * n + col] * kv;
            c -= t.c[i * n + col] * kv + t.g[i * n + col] * mv;
        }
        return .{ g, c };
    }
};

/// What `columns` reads of the query: the device parameter its `.dc`
/// sweeps, and a `.tran`'s step per row and trapezoid weight.
const Run = struct { swept: ?core.query.Dc.SweepTarget.Param, steps: []const core.Step, xmu: f64 };

/// The step that reached a `.tran` row past a run's first: its method and
/// the coefficients the integrator took it with.
const Closed = struct { method: Method, k: integrator.StepCoeffs };

/// A charging variable's replay (`core.OpVar.charging`): its instance's
/// terminal charges at this row and the ones before, newest first, and the
/// dynamic current the integrator carries into each terminal, as
/// `tran/emir.zig` keeps them per terminal live. `g` is gear-3..6's
/// history term.
const Replay = struct {
    ring: [7][]f64,
    i: []f64,
    g: []f64,

    /// `n` values per slot, taken from `store` at `off`.
    fn init(store: []f64, off: *usize, n: usize) Replay {
        var r: Replay = .{ .ring = undefined, .i = types.take(store, off, n), .g = types.take(store, off, n) };
        for (&r.ring) |*h| h.* = types.take(store, off, n);
        return r;
    }

    /// Takes `q`, this row's terminal charges. At a run's first row (no
    /// `step`) it seeds every slot with them and `i` with 0, as `Sim.init`
    /// seeds its history; at a later row it advances `i` over them under
    /// `step`, as `Sim.end` advances its own (`integrator.advanceCurrent`).
    fn advance(r: *Replay, q: []const f64, step: ?Closed) void {
        std.debug.assert(q.len == r.i.len);
        const s = step orelse {
            for (r.ring) |h| @memcpy(h, q);
            @memset(r.i, 0);
            return;
        };
        std.mem.rotate([]f64, &r.ring, r.ring.len - 1);
        @memcpy(r.ring[0], q);
        const k = integrator.order(s.method);
        std.debug.assert(k + 1 <= r.ring.len);
        if (k >= 3) integrator.gearHistory(r.g, r.ring[0 .. k + 1], s.k.ag);
        integrator.advanceCurrent(s.method, r.i, r.ring[0], r.ring[1], if (k >= 3) r.g else r.ring[2], s.k.c);
    }
};

/// `res`, the result of query `job`, with its columns past `deck.probes`,
/// recorded from `deck.opvar_probes`, replaced by one column per
/// `deck.opvars` entry, and its tangent blocks likewise; allocated in `a`,
/// with work in `scratch`. Along a `.dc` that sweeps a device parameter
/// its column is the sweep's value, as ngspice's `@v1[dc]` along `.dc v1`.
/// Asserts that `res` is `[scale] ++ deck.opvar_probes`, and that its
/// steps, if any, number its rows.
pub fn publish(a: std.mem.Allocator, scratch: std.mem.Allocator, circuit: *const types.Circuit, deck: *const core.Deck, res: types.Result, job: core.query.Query) !types.Result {
    std.debug.assert(res.varnames.len == deck.opvar_probes.len or res.varnames.len == deck.opvar_probes.len + 1);
    std.debug.assert(res.steps.len == 0 or res.steps.len == res.npoints);
    const scale = res.varnames.len - deck.opvar_probes.len;
    const kept = scale + deck.probes.len;
    const names = try a.alloc([]const u8, kept + deck.opvars.len);
    @memcpy(names[0..kept], res.varnames[0..kept]);
    for (names[kept..], deck.opvars) |*name, v| name.* = v.label;
    // `validateDeck` refused a `.tran` whose rows no replay serves a
    // transient value over (`error.UnreplayedOpVar`); a kept one keeps its
    // steps (`Executor.create`).
    if (job == .tran) for (deck.opvars) |v| std.debug.assert(!v.dynamic or ((v.charging or v.companion != null) and
        (res.data.len == 0 or res.steps.len == res.npoints) and job.tran.t_start <= 0 and !job.tran.uic and !job.tran.snapshot));
    const run: Run = .{
        .swept = if (job == .dc) switch (job.dc.target) {
            .device => |d| d,
            .temp => null,
        } else null,
        .steps = res.steps,
        .xmu = if (job == .tran) job.tran.xmu else 0.5,
    };
    var out = res;
    out.varnames = names;
    out.data = try columns(a, scratch, circuit, deck, res.data, scale, run);
    out.tangents = try columns(a, scratch, circuit, deck, res.tangents, scale, run);
    return out;
}

// ---- private ----

/// The step that reached row `j` (> 0) of a `.tran` block whose rows
/// `steps` reached, its coefficients from that step and the ones before it
/// as `Sim.begin` took them from its own history.
fn closed(steps: []const core.Step, j: usize, xmu: f64) Closed {
    std.debug.assert(j >= 1 and j < steps.len);
    const s = steps[j];
    // A run starts at order 1 and climbs one order per accepted step at
    // most, so the history a step reads never reaches row 0.
    std.debug.assert(integrator.order(s.method) <= j);
    var dts: [7]f64 = @splat(s.h);
    for (dts[0..@min(dts.len, j)], 0..) |*d, i| d.* = steps[j - i].h;
    return .{ .method = s.method, .k = integrator.stepCoeffs(s.method, &dts, xmu) };
}

/// `publish` over the point-major rows of `in`: blocks of `run.steps.len`
/// rows in a `.tran` (its tangent blocks repeat its rows), each replayed
/// from its first.
fn columns(a: std.mem.Allocator, scratch: std.mem.Allocator, circuit: *const types.Circuit, deck: *const core.Deck, in: []const f64, scale: usize, run: Run) ![]const f64 {
    const w_in = scale + deck.opvar_probes.len;
    const kept = scale + deck.probes.len;
    const w_out = kept + deck.opvars.len;
    std.debug.assert(in.len % w_in == 0);
    const rows = in.len / w_in;
    std.debug.assert(run.steps.len == 0 or rows % run.steps.len == 0);
    const out = try a.alloc(f64, rows * w_out);
    if (rows == 0) return out;
    var n_max: usize = 0;
    var own_max: usize = 0;
    var n_replay: usize = 0;
    for (deck.opvars) |v| {
        n_max = @max(n_max, circuit.batches[v.batch].n_u);
        own_max = @max(own_max, circuit.batches[v.batch].hooks.op_vars.len);
        if (v.charging) n_replay += 9 * @as(usize, v.ports);
    }
    const replay_store = try scratch.alloc(f64, n_replay);
    defer scratch.free(replay_store);
    const replays = try scratch.alloc(Replay, deck.opvars.len);
    defer scratch.free(replays);
    var replay_off: usize = 0;
    for (deck.opvars, replays) |v, *r| r.* = .init(replay_store, &replay_off, if (v.charging) v.ports else 0);
    std.debug.assert(replay_off == n_replay);
    // A parameter keeps the run's value over every row; the swept one reads
    // each point's scale value.
    const fixed = try scratch.alloc(f64, deck.opvars.len);
    defer scratch.free(fixed);
    const on_scale = try scratch.alloc(bool, deck.opvars.len);
    defer scratch.free(on_scale);
    for (deck.opvars, fixed, on_scale) |v, *f, *s| {
        f.* = 0;
        s.* = false;
        const ord = v.param orelse continue;
        const b = circuit.batches[v.batch];
        const l = try b.hooks.param_layout.?(b.ctx).unwrap();
        f.* = l.ptr(ord).*;
        const t = run.swept orelse continue;
        s.* = scale == 1 and t.type == circuit.batch_types[v.batch] and t.index == v.index and
            std.ascii.eqlIgnoreCase(t.param_name, l.fields[ord / l.count].name);
    }
    const x = try scratch.alloc(f64, circuit.n);
    defer scratch.free(x);
    @memset(x, 0);
    const reals = try scratch.alloc(f64, 6 * n_max + 3 * n_max * n_max + own_max);
    defer scratch.free(reals);
    const ints = try scratch.alloc(u32, 3 * n_max);
    defer scratch.free(ints);
    for (0..rows) |r| {
        const src = in[r * w_in ..][0..w_in];
        const dst = out[r * w_out ..][0..w_out];
        @memcpy(dst[0..kept], src[0..kept]);
        for (deck.opvar_probes, src[scale..]) |row, v| x[row] = v;
        const j = if (run.steps.len == 0) 0 else r % run.steps.len;
        const step: ?Closed = if (j == 0) null else closed(run.steps, j, run.xmu);
        for (deck.opvars, dst[kept..], fixed, on_scale, replays) |v, *o, f, s, *rp| {
            o.* = if (s) src[0] else v.times * (if (v.param != null) f else value(circuit.batches[v.batch], v, x, reals, ints, rp, step));
        }
    }
    return out;
}

/// Variable `v` of its instance at `x`: the model's own value, or a
/// terminal quantity, NaN for a bulk one of a device with three terminals
/// or a partial whose internal block is singular. `step` is what reached a
/// `.tran` row past its run's first: an own value adds its companion
/// conductance under it, and a charging variable's terminal currents their
/// charging currents through `rp`. `reals` and `ints` are work, sized as
/// `columns` sizes them.
fn value(b: abi.Batch, v: core.OpVar, x: []const f64, reals: []f64, ints: []u32, rp: *Replay, step: ?Closed) f64 {
    const n: usize = b.n_u;
    const ports: usize = v.ports;
    var off: usize = 0;
    const ev: abi.LocalEval = .{
        .vars = types.take(reals, &off, b.hooks.op_vars.len),
        .x = types.take(reals, &off, n),
        .f = types.take(reals, &off, n),
        .q = types.take(reals, &off, n),
        .g = types.take(reals, &off, n * n),
        .c = types.take(reals, &off, n * n),
        .root = ints[0..n],
    };
    b.hooks.local_eval.?(b.ctx, x, v.index, ev);
    if (v.own) |k| {
        std.debug.assert(!v.charging);
        const c = v.companion orelse return ev.vars[k];
        const s = step orelse return ev.vars[k];
        return ev.vars[k] + s.k.c.ag0 * ev.vars[c];
    }
    std.debug.assert(v.param == null and v.companion == null);
    std.debug.assert(ports >= 2 and ports <= n);
    merge(n, ev);
    if (v.charging) {
        rp.advance(ev.q[0..ports], step);
        for (ev.f[0..ports], rp.i) |*f, i| f.* += i;
    }
    // The internal unknowns that are still their own nodes.
    var n_in: usize = 0;
    const in = ints[n..][0..n];
    for (ports..n) |u| if (ev.root[u] == u) {
        in[n_in] = @intCast(u);
        n_in += 1;
    };
    const t: Terminals = .{ .n = n, .g = ev.g, .c = ev.c, .in = in[0..n_in], .work = reals[off..], .piv = ints[2 * n ..][0..n] };
    const bulk = ports > 3;
    const nan = std.math.nan(f64);
    // ngspice's frame: type × each current and voltage (core.OpVar.Quantity).
    const sign: f64 = if (v.pmos) -1 else 1;
    return switch (v.quantity) {
        .id, .ids => sign * ev.f[0],
        .ig => sign * ev.f[1],
        .is => sign * ev.f[2],
        .ib => if (bulk) sign * ev.f[3] else nan,
        .gm => t.partial(0, 1)[0],
        .gds => t.partial(0, 0)[0],
        .gmbs => if (bulk) t.partial(0, 3)[0] else nan,
        .cgg => t.partial(1, 1)[1],
        .cgd => -t.partial(1, 0)[1],
        .cgs => -t.partial(1, 2)[1],
        .cgb => if (bulk) -t.partial(1, 3)[1] else nan,
        // The terminal cgg, overlap included, never a model's own `cgg`.
        .ft => t.partial(0, 1)[0] / (2 * std.math.pi * t.partial(1, 1)[1]),
        .vgs => sign * (ev.x[1] - ev.x[2]),
        .vds => sign * (ev.x[0] - ev.x[2]),
        .vbs => if (bulk) sign * (ev.x[3] - ev.x[2]) else nan,
        .v => ev.x[0] - ev.x[1],
        .p => power: {
            var s: f64 = 0;
            for (ev.f[0..ports], ev.x[0..ports]) |f, xv| s += f * xv;
            break :power s;
        },
    };
}

/// Folds each collapsed unknown's row, then its column, into its root's,
/// as the circuit's shared row and slot sum them. Rows first, so an entry
/// between two collapsed unknowns reaches the roots' entry.
fn merge(n: usize, ev: abi.LocalEval) void {
    for (0..n) |u| {
        const r = rootOf(ev.root, u);
        if (r == u) continue;
        ev.f[r] += ev.f[u];
        ev.q[r] += ev.q[u];
        for ([_][]f64{ ev.g, ev.c }) |m| for (0..n) |k| {
            m[r * n + k] += m[u * n + k];
        };
    }
    for (0..n) |u| {
        const r = rootOf(ev.root, u);
        if (r == u) continue;
        for ([_][]f64{ ev.g, ev.c }) |m| for (0..n) |k| {
            m[k * n + r] += m[k * n + u];
        };
    }
}

/// The unknown `u` finally collapses into.
fn rootOf(root: []const u32, u: usize) usize {
    var r = u;
    var hops: usize = 0;
    while (root[r] != r) : (hops += 1) {
        std.debug.assert(hops < root.len);
        r = root[r];
    }
    return r;
}

test "an internal node eliminates to the terminals' series conductance and charge" {
    // Terminals 0, 1 and internal node 2: g1 from 0 to 2, g2 from 2 to 1,
    // a capacitor c2 from 2 to 1. Seen from the terminals: G = g1 g2 /
    // (g1 + g2), and C = c2 g1² / (g1 + g2)² (the RC's low-frequency
    // admittance slope).
    const g1 = 2.0;
    const g2 = 3.0;
    const c2 = 5.0;
    const g = [9]f64{ g1, 0, -g1, 0, g2, -g2, -g1, -g2, g1 + g2 };
    const c = [9]f64{ 0, 0, 0, 0, c2, -c2, 0, -c2, c2 };
    var work: [3]f64 = undefined;
    var piv: [1]u32 = undefined;
    const t: Terminals = .{ .n = 3, .g = &g, .c = &c, .in = &.{2}, .work = &work, .piv = &piv };
    const p = t.partial(0, 1);
    try std.testing.expectApproxEqRel(-g1 * g2 / (g1 + g2), p[0], 1e-15);
    try std.testing.expectApproxEqRel(-c2 * g1 * g1 / ((g1 + g2) * (g1 + g2)), p[1], 1e-15);
}

test "a collapsed unknown's row and column fold into its node" {
    // Unknown 2 collapses into 0: the 3x3 stamp of a resistor g from 2 to
    // 1 becomes the same resistor from 0 to 1.
    var x = [_]f64{ 0, 0, 0 };
    var f = [_]f64{ 0, -1, 1 };
    var q = [_]f64{ 0, 0, 0 };
    var g = [9]f64{ 0, 0, 0, 0, 4, -4, 0, -4, 4 };
    var c: [9]f64 = @splat(0);
    var root = [_]u32{ 0, 1, 0 };
    merge(3, .{ .x = &x, .f = &f, .q = &q, .g = &g, .c = &c, .root = &root });
    try std.testing.expectEqualSlices(f64, &.{ 1, -1 }, &.{ f[0], f[1] });
    try std.testing.expectEqualSlices(f64, &.{ 4, -4, -4, 4 }, &.{ g[0], g[1], g[3], g[4] });
}
