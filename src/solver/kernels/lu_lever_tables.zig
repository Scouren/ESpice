//! Tables of the device LU's levers, built by `lu_tables.build` beside
//! today's: the G7 tail levels (`Options.g7`) and the supernode run tables
//! of G2 part 2 stage A (`Options.runs`), the latter from C1's `lu_runs`
//! tables of the same factor. In: the factor's pattern and C1's tables;
//! out: the `Tab` tables of their names.
//! Cites: docs/perf_research/10-device-lu-chain.md (M1, M2); `lu_runs.zig`.
//!
//! Contents:
//! - `pub const TailLevels = struct`
//! - `pub const RunTables = struct`
//! - `pub fn tailLevels(ar: std.mem.Allocator, tn: u32, tl_ptr: []const u32, tl_col: []const u32, tu_ptr: []const u32, tu_col: []const u32) !TailLevels`
//! - `pub fn runTables(ar: std.mem.Allocator, lu: *const SparseLu, v: lu_runs.View, coff: []const u32, pos: []u32) !RunTables`

const std = @import("std");
const assert = std.debug.assert;
const klu = @import("lu.zig");
const SparseLu = @import("../sparse_lu.zig").SparseLu;
const lu_runs = @import("../lu_runs.zig");

/// `Options.g7`'s tables (`Tab.tl_in`..`t_nlv`); empty without the lever.
pub const TailLevels = struct {
    /// Per tail row: first in-panel entry, levels; per panel: counts.
    tl_in: []const u32 = &.{},
    tu_in: []const u32 = &.{},
    tl_lv: []const u32 = &.{},
    tu_lv: []const u32 = &.{},
    t_nlv: []const u32 = &.{},
};

/// `Options.runs`' tables (`Tab.rcol`, `rinfo`, `rmap`, `lpv`, see there);
/// empty without the lever.
pub const RunTables = struct {
    /// Per column, its runs' range (C1's `run_ptr`).
    rcol: []const u32 = &.{},
    /// Six words per run.
    rinfo: []const u32 = &.{},
    /// Rectangular rows' destination slots.
    rmap: []const u32 = &.{},
    /// Per L entry, its `val` slot in its panel, or `NONE`.
    lpv: []const u32 = &.{},
    /// Panel slots `val` holds after the discard slot.
    pv_len: u32 = 0,
};

/// `lpv` entry of an L slot outside every panel (`lu_steps`' `no_panel`).
const NONE: u32 = std.math.maxInt(u32);

/// The G7 tables of a tail of `tn` rows from its panel rows (`tl_col`
/// ascending per row, `tu_col` descending): per row its first in-panel
/// entry and its in-panel level, per panel the level counts. A level is one
/// past the deepest level among the row's in-panel entries, so rows of one
/// level never read each other. O(tail entries).
pub fn tailLevels(ar: std.mem.Allocator, tn: u32, tl_ptr: []const u32, tl_col: []const u32, tu_ptr: []const u32, tu_col: []const u32) !TailLevels {
    const pn = klu.panel;
    assert(tl_ptr.len == @as(usize, tn) + 1);
    assert(tu_ptr.len == @as(usize, tn) + 1);
    const np = (tn + pn - 1) / pn;
    const tl_in = try ar.alloc(u32, tn);
    const tu_in = try ar.alloc(u32, tn);
    const tl_lv = try ar.alloc(u32, tn);
    const tu_lv = try ar.alloc(u32, tn);
    const nlv = try ar.alloc(u32, 2 * @as(usize, np));
    @memset(nlv, 0);
    // Forward, rows ascending: a row's in-panel entries are left of it.
    for (0..tn) |ii| {
        const i: u32 = @intCast(ii);
        const r0 = i / pn * pn;
        var e = tl_ptr[i];
        while (e < tl_ptr[i + 1] and tl_col[e] < r0) e += 1;
        tl_in[i] = e;
        var lv: u32 = 0;
        for (tl_col[e..tl_ptr[i + 1]]) |c| lv = @max(lv, tl_lv[c] + 1);
        assert(lv < pn);
        tl_lv[i] = lv;
        nlv[i / pn] = @max(nlv[i / pn], lv + 1);
    }
    // Back, rows descending: a row's in-panel entries are right of it.
    var i = tn;
    while (i > 0) {
        i -= 1;
        const r1 = @min(i / pn * pn + pn, tn);
        var e = tu_ptr[i];
        while (e < tu_ptr[i + 1] and tu_col[e] >= r1) e += 1;
        tu_in[i] = e;
        var lv: u32 = 0;
        for (tu_col[e..tu_ptr[i + 1]]) |c| lv = @max(lv, tu_lv[c] + 1);
        assert(lv < pn);
        tu_lv[i] = lv;
        nlv[np + i / pn] = @max(nlv[np + i / pn], lv + 1);
    }
    return .{ .tl_in = tl_in, .tu_in = tu_in, .tl_lv = tl_lv, .tu_lv = tu_lv, .t_nlv = nlv };
}

/// The run tables for `lu`'s factor from C1's tables `v` of it, the
/// panels placed in `val` from `coff[n] + 1` on. A run at U position `at`
/// of column k holds steps t0..t0+len-1 of panel [first, last] with nr
/// rows: its rectangular rows are panel slots t0 - first + len - 1..nr,
/// every one a row of column k (or, below a void pivot, the discard slot).
/// `pos` is n words of scratch. OutOfMemory also means the panels pass
/// u32 slots.
pub fn runTables(ar: std.mem.Allocator, lu: *const SparseLu, v: lu_runs.View, coff: []const u32, pos: []u32) !RunTables {
    const n = lu.n;
    const lp = lu.lp;
    const up = lu.up;
    const li = lu.li.items;
    const ui = lu.ui.items;
    assert(v.run_ptr.len == @as(usize, n) + 1);
    assert(pos.len >= n);
    const pv0: u64 = @as(u64, coff[n]) + 1;
    const pv_len = std.math.cast(u32, v.pv.len) orelse return error.OutOfMemory;
    if (pv0 + pv_len > NONE) return error.OutOfMemory;
    const nrun = v.run_at.len;
    const rinfo = try ar.alloc(u32, 6 * nrun);
    // Rectangular rows per run, then their destinations.
    var total: usize = 0;
    for (v.run_at, v.run_len) |at, len| {
        const pid = v.sn[ui[at]];
        const nr = (v.last[pid] - v.first[pid]) + (lp[v.last[pid] + 1] - lp[v.last[pid]]);
        total += nr - (ui[at] - v.first[pid] + len - 1);
    }
    const rmap = try ar.alloc(u32, total);
    const mark = try ar.alloc(u32, n);
    @memset(mark, NONE);
    var m: u32 = 0;
    for (0..n) |kk| {
        const k: u32 = @intCast(kk);
        if (v.run_ptr[k] == v.run_ptr[k + 1]) continue;
        const base = coff[k];
        const nuk = up[k + 1] - up[k];
        for (up[k]..up[k + 1]) |p| pos[ui[p]] = base + @as(u32, @intCast(p)) - up[k];
        pos[k] = base + nuk;
        for (lp[k]..lp[k + 1]) |q| pos[li[q]] = base + nuk + 1 + @as(u32, @intCast(q)) - lp[k];
        for (ui[up[k]..up[k + 1]]) |i| mark[i] = k;
        mark[k] = k;
        for (li[lp[k]..lp[k + 1]]) |r| mark[r] = k;
        for (v.run_ptr[k]..v.run_ptr[k + 1]) |r| {
            const at = v.run_at[r];
            const len = v.run_len[r];
            const t0 = ui[at];
            const pid = v.sn[t0];
            assert(pid != NONE);
            const first = v.first[pid];
            const last = v.last[pid];
            const mb = last - first; // block rows
            const nr = mb + (lp[last + 1] - lp[last]);
            const s0 = t0 - first;
            assert(at >= up[k] and at + len <= up[k + 1] and t0 + len - 1 <= last);
            const pb = pv0 + v.off[pid] + @as(u64, s0) * nr;
            rinfo[6 * r ..][0..6].* = .{ at, len, @intCast(pb), nr, s0, m };
            var s = s0 + len - 1;
            while (s < nr) : (s += 1) {
                const row = if (s < mb) first + 1 + s else li[lp[last] + s - mb];
                rmap[m] = if (lu.void_col[k] and row > k) coff[n] else blk: {
                    // Symbolic closure: L[:,t] for t in U[:,k] lies in k's pattern.
                    assert(mark[row] == k);
                    break :blk pos[row];
                };
                m += 1;
            }
        }
    }
    assert(m == total);
    const lpv = try ar.alloc(u32, li.len);
    @memset(lpv, NONE);
    for (0..n) |s| {
        if (v.sn[s] == NONE) continue;
        for (lp[s]..lp[s + 1]) |q| lpv[q] = @intCast(pv0 + v.lpos[q]);
    }
    return .{ .rcol = v.run_ptr, .rinfo = rinfo, .rmap = rmap, .lpv = lpv, .pv_len = pv_len };
}
