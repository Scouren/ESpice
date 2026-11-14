//! Lever C1, stage 1: the tables that let the column replay apply a run of
//! consecutive supernode steps in a column's U list as one dense panel
//! update (`Replay.columnPanels`) instead of one `scatterAxpy` per step.
//! In: a factored `SparseLu` (permuted L rows). Out: per pivot epoch, the
//! supernodes a run uses, each L entry's slot in a dense column-major copy
//! of its panel, and per column the runs of its U list. Built once by
//! `SparseLu.factor`; a refactor only reads them and refills the copy.
//! Cites: docs/perf_research/04-levers-cpu.md ("C1"); Demmel, Eisenstat,
//! Gilbert, Li and Liu, "A supernodal approach to sparse partial
//! pivoting", SIAM J. Matrix Anal. Appl. 20(3), 1999.
//!
//! Contents:
//! - `pub const run_min = 4`
//! - `pub const admit_share = 0.7`
//! - `pub const View = struct`
//! - `pub const Share = struct`
//!   - `pub fn admitted(s: Share) bool`
//! - `pub const Tables = struct`
//!   - `pub fn deinit(self: *Tables, gpa: Allocator) void`
//!   - `pub fn clear(self: *Tables) void`
//!   - `pub fn view(self: *const Tables) View`
//! - `pub fn build(self: *SparseLu, gpa: Allocator) Allocator.Error!void`
//! - `pub fn chainHeads(self: *const SparseLu, mark: []u32, sn: []u32) void`
//! - `pub fn share(self: *const SparseLu, sn: []const u32) Share`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const SparseLu = @import("sparse_lu.zig").SparseLu;
const testing = std.testing;

/// A run of fewer consecutive supernode steps keeps the per-step
/// `scatterAxpy`. ponytail: provisional; the brief's step-2
/// microbenchmark (pairs/ns against run length on sram_bsim4_10k) fits it.
pub const run_min = 4;

/// The host replay applies a factor's runs only when they hold at least
/// this share of its pairs; below it the column loop runs (bitwise the
/// same). The panel replay pays one `copyPanel` store per L entry of every
/// panel step, every refactor, whatever the runs; it saves part of each
/// run pair's index load and scattered update. Break-even depends on pairs
/// per panel L entry and on that saved part, which the share alone does
/// not carry, so the code gives no number. ponytail: provisional, inside
/// the measured gap (2026-11, transient factors): admitted logic_bsim4_10k
/// 98.0%, sram_bsim4_10k 95.0%, logic_bsim4_1k 86.7%, sram_bsim4_1k 85.5%
/// (all faster under C1); declined chain_bsim4_10k 23.6%,
/// chain_psp103_10k 23.7% (slower). 0.7 sits above chain_bsim4_10k's
/// 52.1% under C8's order, which showed no gain. Refit when a deck lands
/// inside 24-85%; the next measure is run pairs per panel L entry.
pub const admit_share = 0.7;

/// A factor's pairs, all of them and those inside runs of at least
/// `run_min` steps (`share`).
pub const Share = struct {
    runs: u64,
    all: u64,

    /// Whether the runs hold at least `admit_share` of the pairs.
    pub fn admitted(s: Share) bool {
        assert(s.runs <= s.all);
        return s.all != 0 and @as(f64, @floatFromInt(s.runs)) >= admit_share * @as(f64, @floatFromInt(s.all));
    }
};

/// The tables as slices, held by value in a `Replay`. Empty when the
/// factor has no run, and then the replay never reads them.
pub const View = struct {
    /// Step -> panel id, or NONE.
    sn: []const u32 = &.{},
    /// Per panel: its first and last step and its offset in `pv`. A panel
    /// [first, last] has nrows = (last - first) + |L[:,last]| rows: slot
    /// s < last - first is row first + 1 + s (the block), slot
    /// last - first + i is L[:,last]'s i-th stored row.
    first: []const u32 = &.{},
    last: []const u32 = &.{},
    off: []const u32 = &.{},
    /// L entry -> its index in `pv`; read only in panel columns.
    lpos: []const u32 = &.{},
    /// Panel values, column-major, nrows per member step. Refilled by every
    /// panel replay before any run reads them; slots above a column's
    /// first row are never read.
    pv: []f64 = &.{},
    /// Column k's runs are run_at/run_len[run_ptr[k]..run_ptr[k + 1]]:
    /// U positions p..p+len-1 hold steps ui[p]..ui[p]+len-1 of one panel.
    run_ptr: []const u32 = &.{},
    run_at: []const u32 = &.{},
    run_len: []const u32 = &.{},
};

/// The owned tables behind a `View`; `SparseLu.runs`. Empty (every list
/// length 0) unless the last `factor` ran with `runs_on` and found a run.
/// Each list backs the `View` field of its name.
pub const Tables = struct {
    sn: std.ArrayList(u32) = .empty,
    first: std.ArrayList(u32) = .empty,
    last: std.ArrayList(u32) = .empty,
    off: std.ArrayList(u32) = .empty,
    lpos: std.ArrayList(u32) = .empty,
    pv: std.ArrayList(f64) = .empty,
    run_ptr: std.ArrayList(u32) = .empty,
    run_at: std.ArrayList(u32) = .empty,
    run_len: std.ArrayList(u32) = .empty,
    /// The runs passed `admit_share`: the serial and subtree replays take
    /// the panels. False leaves them on the column loop; the tables stay
    /// for the kernels that read them (`lu_tables.Options.runs`).
    admitted: bool = false,

    /// Frees every list.
    pub fn deinit(self: *Tables, gpa: Allocator) void {
        inline for (.{ &self.sn, &self.first, &self.last, &self.off, &self.lpos, &self.run_ptr, &self.run_at, &self.run_len }) |l| l.deinit(gpa);
        self.pv.deinit(gpa);
    }

    /// Empties every list, keeping capacity: the replay then takes the
    /// plain column loop (`run_ptr` empty).
    pub fn clear(self: *Tables) void {
        inline for (.{ &self.sn, &self.first, &self.last, &self.off, &self.lpos, &self.run_ptr, &self.run_at, &self.run_len }) |l| l.clearRetainingCapacity();
        self.pv.clearRetainingCapacity();
        self.admitted = false;
    }

    /// The slices a `Replay` carries; valid until the next `build` or
    /// `clear`.
    pub fn view(self: *const Tables) View {
        return .{
            .sn = self.sn.items,
            .first = self.first.items,
            .last = self.last.items,
            .off = self.off.items,
            .lpos = self.lpos.items,
            .pv = self.pv.items,
            .run_ptr = self.run_ptr.items,
            .run_at = self.run_at.items,
            .run_len = self.run_len.items,
        };
    }
};

const NONE: u32 = std.math.maxInt(u32);

/// Builds `self.runs` for the factor just made, in O(nnz(L + U)). A
/// supernode is a maximal chain of steps s, s+1 with L[:,s] = {s+1} ∪
/// L[:,s+1] (so L[:,t] = {t+1..last} ∪ L[:,last] for each member t); only
/// chains some run uses get a panel. Leaves the tables empty when there is
/// no run, a refactor tape exists, or the panels pass 2^32 values. Uses the
/// full factor's DFS scratch (`flag`), so it runs inside `factor`. On
/// error the tables are empty. Asserts that `self` is factored.
pub fn build(self: *SparseLu, gpa: Allocator) Allocator.Error!void {
    assert(self.factored);
    const t = &self.runs;
    t.clear();
    const n = self.n;
    if (n < 2 or self.tv.items.len != 0) return;
    assert(self.flag.len == n);
    errdefer t.clear();
    const lp = self.lp;
    const up = self.up;
    const li = self.li.items;
    const ui = self.ui.items;
    const mark = self.flag;

    // Chains: sn[s] is the first step of s's chain.
    try t.sn.resize(gpa, n);
    const sn = t.sn.items;
    chainHeads(self, mark, sn);

    var nruns: u32 = 0;
    for (0..n) |k| {
        var p = up[k];
        while (p < up[k + 1]) {
            const len = runLen(ui, sn, p, up[k + 1]);
            nruns += @intFromBool(len >= run_min);
            p += len;
        }
    }
    if (nruns == 0) return t.clear();
    // Decided once per pivot epoch, on chains `sn` (overwritten below).
    const admitted = share(self, sn).admitted();
    try t.run_ptr.resize(gpa, @as(usize, n) + 1);
    try t.run_at.resize(gpa, nruns);
    try t.run_len.resize(gpa, nruns);
    // mark[head] == 0: some run uses the chain.
    @memset(mark, NONE);
    var at: u32 = 0;
    for (0..n) |k| {
        t.run_ptr.items[k] = at;
        var p = up[k];
        while (p < up[k + 1]) {
            const len = runLen(ui, sn, p, up[k + 1]);
            if (len >= run_min) {
                t.run_at.items[at] = p;
                t.run_len.items[at] = len;
                mark[sn[ui[p]]] = 0;
                at += 1;
            }
            p += len;
        }
    }
    t.run_ptr.items[n] = at;
    assert(at == nruns);

    // One panel per used chain, laid end to end in `pv`.
    var total: u64 = 0;
    var h: u32 = 0; // chain head
    while (h < n) {
        var e = h;
        while (e + 1 < n and sn[e + 1] == h) e += 1;
        if (mark[h] == 0) {
            assert(e > h);
            const nrows: u64 = (e - h) + (lp[e + 1] - lp[e]);
            const size = (e - h + 1) * nrows;
            if (total + size > NONE) return t.clear();
            try t.first.append(gpa, h);
            try t.last.append(gpa, e);
            try t.off.append(gpa, @intCast(total));
            total += size;
        }
        h = e + 1;
    }
    try t.pv.resize(gpa, @intCast(total));
    @memset(t.pv.items, 0);
    try t.lpos.resize(gpa, li.len);
    @memset(sn, NONE);
    for (t.first.items, t.last.items, t.off.items, 0..) |f, l, o, pid| {
        const m = l - f + 1;
        const common = li[lp[l]..lp[l + 1]];
        const nrows: u32 = m - 1 + @as(u32, @intCast(common.len));
        for (common, 0..) |r, i| mark[r] = m - 1 + @as(u32, @intCast(i));
        for (f..l + 1) |step| {
            sn[step] = @intCast(pid);
            const b: u32 = @intCast(step - f);
            for (lp[step]..lp[step + 1]) |p| {
                const r = li[p];
                assert(r > step);
                const slot = if (r <= l) r - f - 1 else mark[r];
                assert(slot >= b and slot < nrows);
                t.lpos.items[p] = o + b * nrows + slot;
                t.pv.items[o + b * nrows + slot] = self.lx.items[p];
            }
        }
    }
    t.admitted = admitted;
}

/// Writes sn[s] = the first step of s's supernode chain (s itself when it
/// joins no neighbour), using `mark` (n entries) as scratch. O(nnz(L)).
/// Asserts that `self` is factored and both slices have n entries.
pub fn chainHeads(self: *const SparseLu, mark: []u32, sn: []u32) void {
    assert(self.factored);
    assert(mark.len == self.n and sn.len == self.n);
    if (self.n == 0) return;
    @memset(mark, NONE);
    sn[0] = 0;
    for (1..self.n) |s| sn[s] = if (joins(self, mark, @intCast(s - 1))) sn[s - 1] else @intCast(s);
}

/// Pairs of `self`'s factor, all and inside runs of at least `run_min`
/// steps, for chains `sn` (`chainHeads`). O(nnz(U)). Asserts that `self`
/// is factored and `sn` has n entries.
pub fn share(self: *const SparseLu, sn: []const u32) Share {
    assert(self.factored);
    assert(sn.len == self.n);
    const ui = self.ui.items;
    var s: Share = .{ .runs = 0, .all = 0 };
    for (0..self.n) |k| {
        var p = self.up[k];
        while (p < self.up[k + 1]) {
            const len = runLen(ui, sn, p, self.up[k + 1]);
            var f: u64 = 0;
            for (ui[p..][0..len]) |i| f += self.lp[i + 1] - self.lp[i];
            s.all += f;
            if (len >= run_min) s.runs += f;
            p += len;
        }
    }
    return s;
}

// ---- private ----

/// Whether steps s and s+1 form a supernode: L[:,s] = {s+1} ∪ L[:,s+1],
/// neither void. `mark` holds no stamp s on entry. Rows are distinct, so
/// equal counts plus inclusion is equality.
fn joins(self: *const SparseLu, mark: []u32, s: u32) bool {
    assert(s + 1 < self.n);
    if (self.void_col[s] or self.void_col[s + 1]) return false;
    const li = self.li.items;
    const a = li[self.lp[s]..self.lp[s + 1]];
    const b = li[self.lp[s + 1]..self.lp[s + 2]];
    if (a.len != b.len + 1) return false;
    for (b) |r| mark[r] = s;
    for (a) |r| {
        if (r != s + 1 and mark[r] != s) return false;
    }
    return true;
}

/// Length of the run at U position p0 (p0 < p1): consecutive positions
/// holding consecutive steps of one chain.
fn runLen(ui: []const u32, sn: []const u32, p0: u32, p1: u32) u32 {
    assert(p0 < p1);
    const head = sn[ui[p0]];
    var p = p0 + 1;
    while (p < p1 and ui[p] == ui[p - 1] + 1 and sn[ui[p]] == head) p += 1;
    assert(p <= p1);
    return p - p0;
}

fn expectBitwise(a: []const f64, b: []const f64) !void {
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

fn expectAllZero(w: []const f64) !void {
    for (w) |v| try testing.expectEqual(@as(f64, 0), v);
}

/// Factors `vals` on two LUs, `off` (the column loop, the oracle) and
/// `on` (`runs_on`), then refactors `rounds` perturbations of it on both
/// and compares L, U, pivots and a solve bitwise. Round 2 grows an L entry
/// 1e20 past its pivot, so both refactors fail; both then full-factor (the
/// fallback) and the rounds go on. Returns whether `on` had runs.
fn checkPair(gpa: Allocator, rnd: std.Random, n: u32, col_ptr: []const u32, row_idx: []const u32, vals: []const f64, q: []const u32) !bool {
    assert(q.len == n);
    assert(col_ptr.len == @as(usize, n) + 1);
    var off = try SparseLu.init(gpa, n, col_ptr, q);
    defer off.deinit(gpa);
    var on = try SparseLu.init(gpa, n, col_ptr, q);
    defer on.deinit(gpa);
    on.runs_on = true;
    try off.factor(gpa, col_ptr, row_idx, vals, 1e-3);
    try on.factor(gpa, col_ptr, row_idx, vals, 1e-3);
    // Admitted regardless of `admit_share`: the panel replay is the code
    // under test, whatever the runs' share.
    on.runs.admitted = on.runs.run_ptr.items.len != 0;
    try testing.expect(off.tv.items.len == 0);
    try testing.expectEqualSlices(u32, off.pinv, on.pinv);
    const had_runs = on.runs.run_ptr.items.len != 0;
    // Tables are built per factor; a refactor allocates nothing (it takes
    // no allocator) and must not move them.
    const pv_ptr = on.runs.pv.items.ptr;
    const pert = try gpa.alloc(f64, vals.len);
    defer gpa.free(pert);
    const buf = try gpa.alloc(f64, 3 * @as(usize, n));
    defer gpa.free(buf);
    const b = buf[0..n];
    const xa = buf[n .. 2 * n];
    const xb = buf[2 * n ..];
    for (b) |*v| v.* = 2 * rnd.float(f64) - 1;
    for (0..5) |round| {
        for (pert, vals) |*o, v| o.* = v * (0.9 + 0.2 * rnd.float(f64));
        if (round == 2) {
            // The first column with an entry below its pivot.
            var hit = false;
            for (0..n) |k| {
                for (col_ptr[q[k]]..col_ptr[q[k] + 1]) |p| {
                    if (!hit and off.prow[p] > k) {
                        pert[p] *= 1e20;
                        hit = true;
                    }
                }
            }
        }
        const ra = off.refactor(col_ptr, pert, 1e-12);
        const rb = on.refactor(col_ptr, pert, 1e-12);
        try expectAllZero(off.w);
        try expectAllZero(on.w);
        if (ra) |_| {
            try rb;
        } else |e| {
            try testing.expectError(e, rb);
            try off.factor(gpa, col_ptr, row_idx, pert, 1e-3);
            try on.factor(gpa, col_ptr, row_idx, pert, 1e-3);
            on.runs.admitted = on.runs.run_ptr.items.len != 0;
            try testing.expectEqualSlices(u32, off.pinv, on.pinv);
            continue;
        }
        if (round < 2) try testing.expect(on.runs.pv.items.ptr == pv_ptr);
        try expectBitwise(off.lx.items, on.lx.items);
        try expectBitwise(off.ux.items, on.ux.items);
        try expectBitwise(off.udiag, on.udiag);
        try testing.expectEqual(off.replay_mult, on.replay_mult);
        off.solve(b, xa);
        on.solve(b, xb);
        try expectBitwise(xa, xb);
    }
    return had_runs;
}

test "C1 panels: the panel replay is bitwise the column loop, with and without supernodes, failures included" {
    // Oracle: `refactorColumns` (lever off), compared bitwise on L, U,
    // the pivots and a solve.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc1);
    const rnd = prng.random();

    // A dense diagonally dominant 64-block over 32 border rows whose
    // columns hold only their diagonal: one supernode, steps 0..63, with
    // the border as its common rows, so every U list of the block is one
    // run and both the triangular part and `panelRows` run.
    {
        const n = 96;
        const nb = 64;
        var col_ptr: [n + 1]u32 = undefined;
        var row_idx: [n * n]u32 = undefined;
        var vals: [n * n]f64 = undefined;
        var nnz: u32 = 0;
        for (0..n) |j| {
            col_ptr[j] = nnz;
            for (0..n) |i| {
                if (j >= nb and i != j) continue;
                row_idx[nnz] = @intCast(i);
                vals[nnz] = if (i == j) 2 * n else 1 / @as(f64, @floatFromInt(1 + i + 2 * j)) - 0.01;
                nnz += 1;
            }
        }
        col_ptr[n] = nnz;
        var q: [n]u32 = undefined;
        for (&q, 0..) |*c, i| c.* = @intCast(i);
        try testing.expect(try checkPair(gpa, rnd, n, &col_ptr, row_idx[0..nnz], vals[0..nnz], &q));
    }

    // A tridiagonal chain past the tape: every L column is one entry, so
    // no two steps join and the tables stay empty.
    {
        const n = 4096;
        const col_ptr = try gpa.alloc(u32, n + 1);
        defer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, 3 * n);
        defer gpa.free(row_idx);
        const vals = try gpa.alloc(f64, 3 * n);
        defer gpa.free(vals);
        var nnz: u32 = 0;
        for (0..n) |j| {
            col_ptr[j] = nnz;
            for ([_]i64{ -1, 0, 1 }) |d| {
                const i = @as(i64, @intCast(j)) + d;
                if (i < 0 or i >= n) continue;
                row_idx[nnz] = @intCast(i);
                vals[nnz] = if (d == 0) 4 else rnd.float(f64) - 0.5;
                nnz += 1;
            }
        }
        col_ptr[n] = nnz;
        const q = try gpa.alloc(u32, n);
        defer gpa.free(q);
        for (q, 0..) |*c, i| c.* = @intCast(i);
        try testing.expect(!try checkPair(gpa, rnd, n, col_ptr, row_idx[0..nnz], vals[0..nnz], q));
    }

    // Random dense-ish systems with shuffled orders: supernodes where the
    // fill closes, runs broken by the topological order elsewhere.
    for (0..16) |_| {
        const n: u32 = rnd.intRangeAtMost(u32, 48, 64);
        const sys = try SparseLu.test_access.TestSystem.init(gpa, rnd, n, 0.3 + 0.4 * rnd.float(f64));
        defer sys.deinit(gpa);
        const q = try gpa.alloc(u32, n);
        defer gpa.free(q);
        for (q, 0..) |*c, i| c.* = @intCast(i);
        rnd.shuffle(u32, q);
        // A singular draw fails both factors alike; nothing to compare.
        var probe = try SparseLu.init(gpa, n, sys.col_ptr, q);
        defer probe.deinit(gpa);
        probe.factor(gpa, sys.col_ptr, sys.row_idx, sys.vals, 1e-3) catch continue;
        if (probe.tv.items.len != 0) continue;
        _ = try checkPair(gpa, rnd, n, sys.col_ptr, sys.row_idx, sys.vals, q);
    }
}

test "C1 admission: a factor mostly outside runs keeps the column loop, a dense block takes the panels" {
    // Oracle: hand counts. A dense 24-block on diagonal pivots is one
    // chain; column k of it lists steps 0..k-1 (one run of length k),
    // whose L columns hold 23 - i rows: column k has
    // sum_{i<k} (23 - i) pairs, 4324 for k = 1..23, 4190 of them in the
    // runs of k >= 4 (all but 23 + 45 + 66). Past the 2048-flop tape, so
    // the tables are built. A tridiagonal band of 5000 before it
    // (uncoupled) joins no chain and adds 4999 single pairs: 4190 / 9323
    // is under `admit_share`, 4190 / 4324 over it.
    const gpa = testing.allocator;
    const d = 24;
    for ([_]u32{ 0, 5000 }) |m| {
        const n = m + d;
        const col_ptr = try gpa.alloc(u32, n + 1);
        defer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, 3 * m + d * d);
        defer gpa.free(row_idx);
        const vals = try gpa.alloc(f64, 3 * m + d * d);
        defer gpa.free(vals);
        var nnz: u32 = 0;
        for (0..n) |j| {
            col_ptr[j] = nnz;
            const lo = if (j < m) j -| 1 else m;
            const hi = if (j < m) @min(j + 2, m) else n;
            for (lo..hi) |i| {
                row_idx[nnz] = @intCast(i);
                vals[nnz] = if (i == j) 20 else 1;
                nnz += 1;
            }
        }
        col_ptr[n] = nnz;
        const q = try gpa.alloc(u32, n);
        defer gpa.free(q);
        for (q, 0..) |*c, i| c.* = @intCast(i);
        var lu = try SparseLu.init(gpa, n, col_ptr, q);
        defer lu.deinit(gpa);
        lu.runs_on = true;
        try lu.factor(gpa, col_ptr, row_idx[0..nnz], vals[0..nnz], 1e-3);
        try testing.expect(lu.tv.items.len == 0);
        const sn = try gpa.alloc(u32, 2 * @as(usize, n));
        defer gpa.free(sn);
        chainHeads(&lu, sn[n..], sn[0..n]);
        const got = share(&lu, sn[0..n]);
        try testing.expectEqual(Share{ .runs = 4190, .all = 4324 + @as(u64, m -| 1) }, got);
        // The tables exist either way; only the host replay is declined.
        try testing.expect(lu.runs.run_ptr.items.len != 0);
        try testing.expectEqual(m == 0, lu.runs.admitted);
    }
}

test "C1 panels: build releases storage on every allocation failure" {
    const gpa = testing.allocator;
    const n = 48;
    var col_ptr: [n + 1]u32 = undefined;
    var row_idx: [n * n]u32 = undefined;
    var vals: [n * n]f64 = undefined;
    for (0..n) |j| {
        col_ptr[j] = @intCast(j * n);
        for (0..n) |i| {
            row_idx[j * n + i] = @intCast(i);
            vals[j * n + i] = if (i == j) 2 * n else 1 / @as(f64, @floatFromInt(1 + i + j));
        }
    }
    col_ptr[n] = n * n;
    var q: [n]u32 = undefined;
    for (&q, 0..) |*c, i| c.* = @intCast(i);
    const life = struct {
        fn f(a: Allocator, cp: []const u32, ri: []const u32, v: []const f64, qq: []const u32) !void {
            var lu = try SparseLu.init(a, n, cp, qq);
            defer lu.deinit(a);
            lu.runs_on = true;
            try lu.factor(a, cp, ri, v, 1e-3);
            try lu.refactor(cp, v, 1e-12);
        }
    }.f;
    try life(gpa, &col_ptr, &row_idx, &vals, &q);
    try testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, life, .{ @as([]const u32, &col_ptr), @as([]const u32, &row_idx), @as([]const f64, &vals), @as([]const u32, &q) });
}
