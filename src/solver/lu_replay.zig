//! The numeric replay of a frozen `SparseLu` factor: new values in, new L,
//! U and pivots out on the old pattern and pivot sequence, with no search
//! and no allocation. Two kernels, the column loop (`Replay.column`, which
//! `subtree`, `kernels/lu.zig` and the lane LUs reproduce) and, for small
//! factors, a flat slot tape in L1; the tape's bits are the column loop's.
//! Lever C1 adds `columnPanels`, the column loop with supernode runs as
//! dense panel updates (`lu_runs.zig`), bitwise the column loop too.
//! Cites: dev/solvers/refactor-tape-2026-09.md, gilbert-peierls-lu.md
//! ("Two replay thresholds"), docs/perf_research/04-levers-cpu.md ("C1").
//!
//! Contents:
//! - `pub const Replay = struct`
//!   - `pub inline fn column(r: Replay, w: []f64, k: usize, nonfinite: *u64, mult: *f64) bool`
//!   - `pub inline fn columnAfter(r: Replay, w: []f64, k: usize, nonfinite: *u64, mult: *f64, ready: anytype) bool`
//!   - `pub inline fn columnPanels(r: Replay, w: []f64, k: usize, nonfinite: *u64, mult: *f64, ready: anytype) bool`
//! - `pub const NoWait = struct`
//!   - `pub inline fn wait(_: NoWait, _: u32) void`
//! - `pub const tape_max_flops = 2048`
//! - `pub inline fn scatterAxpy(dst: []f64, idx: []const u32, src: []const f64, p0: u32, p1: u32, f: f64) void`
//! - `pub fn refactorColumns(self: *SparseLu, col_ptr: []const u32, vals: []const f64, growth_limit: f64) error{SingularMatrix}!void`
//! - `pub fn refactorPanels(self: *SparseLu, col_ptr: []const u32, vals: []const f64, growth_limit: f64) error{SingularMatrix}!void`
//! - `pub fn buildTape(self: *SparseLu, gpa: Allocator, col_ptr: []const u32) Allocator.Error!void`
//! - `pub fn refactorTape(self: *SparseLu, vals: []const f64, growth_limit: f64) error{SingularMatrix}!void`

const std = @import("std");
const assert = std.debug.assert;
const num = @import("core").numerics;
const Allocator = std.mem.Allocator;
const sparse_lu = @import("sparse_lu.zig");
const SparseLu = sparse_lu.SparseLu;
const instrument = sparse_lu.instrument;
const lu_panel = @import("lu_panel.zig");
const lu_runs = @import("lu_runs.zig");

/// One factor's slices, copied by value so a replay holds them in
/// registers: LLVM cannot prove the `ux[p]` store disjoint from a
/// `SparseLu`, and the field reloads cost 35% of the replay on
/// scaling/parallel_inverters_100.
pub const Replay = struct {
    li: []const u32,
    lx: []f64,
    ui: []const u32,
    ux: []f64,
    lp: []const u32,
    up: []const u32,
    prow: []const u32,
    udiag: []f64,
    q: []const u32,
    void_col: []const bool,
    scaled_pivot: []const bool,
    col_ptr: []const u32,
    vals: []const f64,
    growth_limit: f64,
    /// Lever C1's run tables; empty unless the factor built them, and read
    /// only by `columnPanels`.
    runs: lu_runs.View = .{},

    /// Replays pivot step k into its own slots of L, U and `udiag`,
    /// through the dense accumulator `w` (n entries, all-zero on entry
    /// and on return, failure included). Reads only the final values of
    /// the steps in U[:,k], so any schedule that runs those first gets
    /// the serial loop's bits. ORs a non-finite store into `nonfinite`
    /// (the caller tests it once), and a monitored step's largest
    /// multiplier into `mult` (`SparseLu.replay_mult`). False when the
    /// pivot fails: zero or non-finite, or below `growth_limit` times
    /// its column max (`scaled_pivot` steps excepted).
    pub inline fn column(r: Replay, w: []f64, k: usize, nonfinite: *u64, mult: *f64) bool {
        return r.columnAfter(w, k, nonfinite, mult, struct {
            inline fn wait(_: @This(), _: u32) void {}
        }{});
    }

    /// `column`, calling `ready.wait(i)` before it reads L[:,i] for
    /// each step i in U[:,k], so a schedule that runs the steps of
    /// U[:,k] concurrently can block until each is final.
    pub inline fn columnAfter(r: Replay, w: []f64, k: usize, nonfinite: *u64, mult: *f64, ready: anytype) bool {
        return r.columnWith(false, w, k, nonfinite, mult, ready);
    }

    /// `columnAfter` with each run of `runs` in U[:,k] applied as one
    /// dense panel update (lever C1), and L[:,k] copied into its panel when
    /// k is a panel step. Bitwise `columnAfter`: every slot receives the
    /// same subtractions in the same order. `ready.wait(t)` is called for
    /// every step t of a run before any of its L columns is read. Requires
    /// the tables (`runs.run_ptr` non-empty) of this factor.
    pub inline fn columnPanels(r: Replay, w: []f64, k: usize, nonfinite: *u64, mult: *f64, ready: anytype) bool {
        assert(r.runs.run_ptr.len == r.lp.len);
        return r.columnWith(true, w, k, nonfinite, mult, ready);
    }

    inline fn columnWith(r: Replay, comptime panels: bool, w: []f64, k: usize, nonfinite: *u64, mult: *f64, ready: anytype) bool {
        const li = r.li;
        const lx = r.lx;
        const ui = r.ui;
        const ux = r.ux;
        const lp = r.lp;
        const c = r.q[k];
        const uk0 = r.up[k];
        const uk1 = r.up[k + 1];
        const lk0 = lp[k];
        const lk1 = lp[k + 1];
        // `w` is all-zero here (see the field doc).
        for (r.col_ptr[c]..r.col_ptr[c + 1]) |p| w[r.prow[p]] = r.vals[p];

        // Replay the triangular solve in stored topological order.
        // Zeroing w[i] right after the read is safe: only earlier
        // entries write row i, since L[r][i] != 0 puts r after i.
        if (panels) {
            const run1 = r.runs.run_ptr[k + 1];
            var p: usize = uk0;
            for (r.runs.run_ptr[k]..run1) |run| {
                const at = r.runs.run_at[run];
                assert(at >= p and at < uk1);
                while (p < at) : (p += 1) r.stepU(w, p, nonfinite, ready);
                p = r.applyRun(w, @intCast(run), nonfinite, ready);
            }
            assert(p <= uk1);
            while (p < uk1) : (p += 1) r.stepU(w, p, nonfinite, ready);
        } else for (uk0..uk1) |p| {
            const i = ui[p];
            const uki = w[i];
            w[i] = 0;
            ux[p] = uki;
            nonfinite.* |= @as(u64, @bitCast(uki - uki));
            ready.wait(i);
            scatterAxpy(w, li, lx, lp[i], lp[i + 1], uki);
        }

        // Void slots were checked by the caller; the fabricated pivot
        // is valid.
        if (r.void_col[k]) {
            r.udiag[k] = 1;
            for (lk0..lk1) |p| {
                lx[p] = 0;
                w[li[p]] = 0;
            }
            w[k] = 0;
            // The flops above also hit rows below k, which a void
            // column keeps no L entry for. Finite factors add exact
            // zeros there, but a NaN multiplier leaves 0 * NaN behind,
            // and a replay that fails before those rows' own steps
            // would hand it to the next call. Void columns are rare.
            for (ui[uk0..uk1]) |i| for (li[lp[i]..lp[i + 1]]) |row| {
                w[row] = 0;
            };
            return true;
        }
        const d = w[k];
        w[k] = 0;
        if (d == 0 or !std.math.isFinite(d)) {
            for (lk0..lk1) |p| w[li[p]] = 0;
            return false;
        }
        r.udiag[k] = d;

        // A scale-accepted pivot is decades below its raw column max
        // by design, so the raw monitor would reject every replay.
        // ponytail: those steps run unmonitored; a row-scaled cmax
        // needs rscale in permuted coordinates.
        if (r.growth_limit > 0 and !r.scaled_pivot[k]) {
            // The max of |v|'s bit patterns: exact, cheaper than a float
            // @max, and NaN (whose pattern sorts above inf) survives it,
            // so a non-finite v fails the test below. Every L entry here
            // is then at most 1 / growth_limit: finite, unflagged.
            var cbits: i64 = @bitCast(@abs(d));
            for (lk0..lk1) |p| {
                const row = li[p];
                const v = w[row];
                w[row] = 0;
                cbits = @max(cbits, @as(i64, @bitCast(@abs(v))));
                lx[p] = v / d;
            }
            const cmax: f64 = @bitCast(cbits);
            if (!(@abs(d) >= r.growth_limit * cmax)) return false;
            mult.* = @max(mult.*, cmax / @abs(d));
            if (panels) r.copyPanel(k);
            return true;
        }
        for (lk0..lk1) |p| {
            const row = li[p];
            const l = w[row] / d;
            nonfinite.* |= @as(u64, @bitCast(l - l));
            lx[p] = l;
            w[row] = 0;
        }
        if (panels) r.copyPanel(k);
        return true;
    }

    /// The column loop's step for U entry p.
    inline fn stepU(r: Replay, w: []f64, p: usize, nonfinite: *u64, ready: anytype) void {
        const i = r.ui[p];
        const uki = w[i];
        w[i] = 0;
        r.ux[p] = uki;
        nonfinite.* |= @as(u64, @bitCast(uki - uki));
        ready.wait(i);
        scatterAxpy(w, r.li, r.lx, r.lp[i], r.lp[i + 1], uki);
    }

    /// Applies run `run` (steps t0..t0+len-1 of panel [first, last] at U
    /// positions at..at+len-1) as `lu_panel.panelRun` does in the full
    /// factor: the block rows t0+1..last, consecutive steps and so already
    /// contiguous in `w`, as a dense triangular solve, then the rows of
    /// L[:,last] by `panelRows`, W at a time. Per row the subtractions
    /// stay in step order, each `w -= l * u` unfused, so the result is
    /// the `stepU` loop's bitwise. Returns the U position after the run.
    inline fn applyRun(r: Replay, w: []f64, run: u32, nonfinite: *u64, ready: anytype) usize {
        const v = r.runs;
        const at: usize = v.run_at[run];
        const len: u32 = v.run_len[run];
        const t0 = r.ui[at];
        const pid = v.sn[t0];
        assert(pid != NONE);
        const first = v.first[pid];
        const last = v.last[pid];
        assert(t0 >= first and t0 + len - 1 <= last);
        const m = last - first + 1;
        const common = r.li[r.lp[last]..r.lp[last + 1]];
        const nrows: u32 = m - 1 + @as(u32, @intCast(common.len));
        const pv = v.pv[v.off[pid]..];
        const x = w[t0 + 1 .. last + 1];
        for (0..len) |j| {
            const t = t0 + @as(u32, @intCast(j));
            assert(r.ui[at + j] == t);
            const u = w[t];
            w[t] = 0;
            r.ux[at + j] = u;
            nonfinite.* |= @as(u64, @bitCast(u - u));
            ready.wait(t);
            const b = t - first;
            lu_panel.subScaled(x[j..], pv[b * nrows ..][b .. m - 1], u);
        }
        const us = r.ux[at..][0..len];
        const vals = pv[(t0 - first) * nrows + (m - 1) ..];
        const nc: u32 = @intCast(common.len);
        const W = comptime std.simd.suggestVectorLength(f64) orelse 1;
        var i: u32 = 0;
        while (i + W <= nc) : (i += W) lu_panel.panelRows(W, w, common, vals, nrows, i, us);
        while (i < nc) : (i += 1) lu_panel.panelRows(1, w, common, vals, nrows, i, us);
        return at + len;
    }

    /// Copies L[:,k], just stored, into its panel when k is a panel step.
    inline fn copyPanel(r: Replay, k: usize) void {
        if (r.runs.sn[k] == NONE) return;
        const lpos = r.runs.lpos;
        const pv = r.runs.pv;
        for (r.lp[k]..r.lp[k + 1]) |p| pv[lpos[p]] = r.lx[p];
    }
};

/// The `ready` of a replay whose U steps are all final already.
pub const NoWait = struct {
    /// Returns at once.
    pub inline fn wait(_: NoWait, _: u32) void {}
};

/// Factors with at most this many flops get the flat tape, 12 bytes
/// per flop, so it stays in L1 between Newton iterates. A larger tape
/// streams from L2 and loses to the column loop
/// (dev/solvers/refactor-tape-2026-09.md).
pub const tape_max_flops = 2048;

comptime {
    // 24 KB of tape: inside a 32 KB L1d with room for the slot values.
    assert(@sizeOf([3]u32) == 12);
    assert(tape_max_flops * @sizeOf([3]u32) <= 24 * 1024);
}

const NONE: u32 = std.math.maxInt(u32);

/// dst[idx[p]] -= src[p] * f for p in [p0, p1): the scatter-axpy of
/// the column replay and both `solve` substitutions.
///
/// Stepped two at a time by hand because circuit columns are 1 to 3
/// entries long (scaling/parallel_inverters_100: 205 of length 1, 200
/// of length 2). LLVM unrolls the plain loop by 4, a body that never
/// runs, and every call still pays its guard chain. A gather-modify-
/// scatter has nothing to widen without AVX-512; a run-vectorized
/// variant lost (dev/solvers/refactor-tape-2026-09.md). Pairing is
/// bitwise the one-at-a-time loop: a column's rows are distinct.
pub inline fn scatterAxpy(dst: []f64, idx: []const u32, src: []const f64, p0: u32, p1: u32, f: f64) void {
    var p = p0;
    while (p + 1 < p1) : (p += 2) {
        dst[idx[p]] -= src[p] * f;
        dst[idx[p + 1]] -= src[p + 1] * f;
    }
    if (p < p1) dst[idx[p]] -= src[p] * f;
}

/// Column-at-a-time replay: the path for matrices too big for a tape,
/// and the tape's oracle.
pub fn refactorColumns(
    self: *SparseLu,
    col_ptr: []const u32,
    vals: []const f64,
    growth_limit: f64,
) error{SingularMatrix}!void {
    return refactorWith(false, self, col_ptr, vals, growth_limit);
}

/// `refactorColumns` through `Replay.columnPanels` (lever C1): bitwise
/// its result, failures included. Asserts that the factor built run
/// tables (`SparseLu.runs`).
pub fn refactorPanels(
    self: *SparseLu,
    col_ptr: []const u32,
    vals: []const f64,
    growth_limit: f64,
) error{SingularMatrix}!void {
    assert(self.runs.run_ptr.items.len == @as(usize, self.n) + 1);
    return refactorWith(true, self, col_ptr, vals, growth_limit);
}

/// Records the refactor as flat slot operations. Every A entry and
/// flop target of column k is a slot of column k's pattern (U rows,
/// the diagonal, L rows), except below-diagonal rows of a void column,
/// which has no L: those go to the discard slot.
pub fn buildTape(self: *SparseLu, gpa: Allocator, col_ptr: []const u32) Allocator.Error!void {
    const n = self.n;
    const lp = self.lp;
    const up = self.up;
    const li = self.li.items;
    const ui = self.ui.items;
    self.tape.clearRetainingCapacity();
    self.tv.clearRetainingCapacity();
    var flops: usize = 0;
    for (ui) |i| flops += lp[i + 1] - lp[i];
    if (flops > tape_max_flops) return;
    const nu: u32 = @intCast(ui.len);
    const lx0 = nu + n;
    const discard: u32 = lx0 + @as(u32, @intCast(li.len));
    try self.tape.ensureTotalCapacityPrecise(gpa, flops);
    try self.lsrc.resize(gpa, li.len);
    for (0..n) |k| @memset(self.lsrc.items[lp[k]..lp[k + 1]], @intCast(k));
    try self.tv.resize(gpa, discard + 1);
    const pos = self.flag; // DFS scratch is free until the next factor
    for (0..n) |k| {
        const void_k = self.void_col[k];
        for (up[k]..up[k + 1]) |p| pos[ui[p]] = @intCast(p);
        pos[k] = nu + @as(u32, @intCast(k));
        for (lp[k]..lp[k + 1]) |q| pos[li[q]] = lx0 + @as(u32, @intCast(q));
        self.tape_col[k] = @intCast(self.tape.items.len);
        for (up[k]..up[k + 1]) |p| {
            const i = ui[p];
            for (lp[i]..lp[i + 1]) |q| {
                const r = li[q];
                const dst = if (void_k and r > k) discard else pos[r];
                self.tape.appendAssumeCapacity(.{ dst, lx0 + @as(u32, @intCast(q)), @intCast(p) });
            }
        }
        const c = self.q[k];
        for (col_ptr[c]..col_ptr[c + 1]) |a| {
            const r = self.prow[a];
            self.amap[a] = if (void_k and r > k) discard else pos[r];
        }
    }
    assert(self.tape.items.len == flops);
    self.tape_col[n] = @intCast(self.tape.items.len);
}

/// `refactor` through the tape: the column loop's operations per slot
/// in the same order, so bitwise its result, without the dense
/// scatter and gather. U slots are final before any flop reads them.
pub fn refactorTape(self: *SparseLu, vals: []const f64, growth_limit: f64) error{SingularMatrix}!void {
    const n = self.n;
    const tv = self.tv.items;
    const tape = self.tape.items;
    const tcol = self.tape_col;
    const lp = self.lp;
    const nu = self.ux.items.len;
    const lx0 = nu + n;
    const void_col = self.void_col;
    const scaled_pivot = self.scaled_pivot;
    assert(tv.len == lx0 + self.lx.items.len + 1);
    assert(vals.len >= self.amap.len);
    @memset(tv, 0);
    for (self.amap, vals[0..self.amap.len]) |s, v| tv[s] = v;
    for (0..n) |k| {
        for (tape[tcol[k]..tcol[k + 1]]) |f| tv[f[0]] -= tv[f[1]] * tv[f[2]];
        const lcol = tv[lx0 + lp[k] .. lx0 + lp[k + 1]];
        if (void_col[k]) {
            tv[nu + k] = 1;
            continue;
        }
        const d = tv[nu + k];
        if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
        if (growth_limit > 0 and !scaled_pivot[k]) {
            var cmax: f64 = @abs(d);
            for (lcol) |*v| {
                cmax = @max(cmax, @abs(v.*));
                v.* /= d;
            }
            if (@abs(d) < growth_limit * cmax) return error.SingularMatrix;
        } else {
            for (lcol) |*v| v.* /= d;
        }
    }
    // The copies out flag a non-finite L or U entry, as the column
    // loop's stores do.
    var nonfinite: u64 = 0;
    for (self.ux.items, tv[0..nu]) |*o, v| {
        o.* = v;
        nonfinite |= @as(u64, @bitCast(v - v));
    }
    @memcpy(self.udiag, tv[nu..lx0]);
    self.replay_mult = null;
    for (self.lx.items, tv[lx0 .. lx0 + self.lx.items.len]) |*o, v| {
        o.* = v;
        nonfinite |= @as(u64, @bitCast(v - v));
    }
    if (nonfinite != 0) return error.SingularMatrix;
}

// ---- private ----

fn refactorWith(
    comptime panels: bool,
    self: *SparseLu,
    col_ptr: []const u32,
    vals: []const f64,
    growth_limit: f64,
) error{SingularMatrix}!void {
    const r = self.replay(col_ptr, vals, growth_limit);
    self.replay_mult = null;
    // Nonzero once a stored L or U entry is NaN or inf: an off-pivot
    // one never meets a pivot test, and the solve skips it where its
    // column's solution is zero. Tested once, after the last column;
    // ORs the bits of x - x, as `factorPass` does.
    var nonfinite: u64 = 0;
    var mult: f64 = 0;
    for (0..self.n) |k| {
        const ok = if (panels) r.columnPanels(self.w, k, &nonfinite, &mult, NoWait{}) else r.column(self.w, k, &nonfinite, &mult);
        if (!ok) return error.SingularMatrix;
    }
    if (nonfinite != 0) return error.SingularMatrix;
    if (growth_limit > 0) self.replay_mult = mult;
}
