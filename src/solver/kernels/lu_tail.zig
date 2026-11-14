//! The device LU's tail solves and the ticket and done-stamp waits every
//! kernel of `kernels/lu.zig` shares: the factor's values, the tables and
//! the head's `y` in, the tail rows of `y` and `dx` out. The last
//! `t.n - t.t0` pivot steps run as panels of `panel` rows, one block each
//! by ticket: a panel's rows gather each earlier panel's columns once it
//! publishes, then sweep their own diagonal block from shared memory.
//! With `lever_g7` (G7 stage 1, mechanism M2) a panel loads its block
//! before it waits and sweeps it one in-panel dependency level per barrier
//! step instead of one row per step; each row keeps its own subtraction
//! order, so the solution stays bitwise `SparseLu.solve`'s.
//! std only: the kernel root compiles this file for NVPTX and AMDGCN.
//! Cites: dev/solvers/gpu-lu.md §4; docs/perf_research/10-device-lu-chain.md
//! (M2).
//!
//! Contents:
//! - `pub fn Tail(comptime Sy: type) type`
//!   - `pub const PanelShared = struct`
//!   - `pub fn lpanel(t: Tab, x: P(u32), val: P(f64), y: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32) bool`
//!   - `pub fn upanel(t: Tab, x: P(u32), val: P(f64), y: P(f64), dx: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32) bool`
//!   - `pub inline fn wait(p: anytype, stamp: u32) void`
//!   - `pub inline fn takeTicket(sy: P(u32), which: u32, sh: anytype, tid: u32) u32`

const std = @import("std");
const klu = @import("lu.zig");
const Tab = klu.Tab;
const panel = klu.panel;
const sync_header = klu.sync_header;

/// The tail kernels over `Sy` (see `klu.Kernels`): `Sy.P` pointers,
/// `Sy.barrier`, `Sy.pause`, `Sy.acquire`/`Sy.release`.
pub fn Tail(comptime Sy: type) type {
    return struct {
        const P = Sy.P;

        /// Panel block scratch: the ticket, each row's running value and
        /// its next entry (its in-panel level once the gathers end, under
        /// `lever_g7`), the block's presence masks, pivots and values.
        pub const PanelShared = struct { k: u32, a: [panel]f64, e: [panel]u32, mask: [panel]u64, d: [panel]f64, blk: [panel][panel]f64 };

        /// The forward tail for the panel its ticket names: its rows take
        /// every earlier panel's columns as each publishes (a row's
        /// subtractions stay in ascending column order), then sweep their
        /// own panel's columns from a dense copy in shared memory, and
        /// publish. The rows leave `y` holding L^-1 for the tail. `sh` is a
        /// `*PanelShared`. Returns false once the tickets run out.
        pub fn lpanel(t: Tab, x: P(u32), val: P(f64), y: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32) bool {
            const b = takeTicket(sy, 4, sh, tid);
            const np = t.panels();
            if (b >= np) return false;
            if (sy[1] != 0) return true;
            if (t.levers & klu.lever_g7 != 0) {
                lpanelLevels(t, x, val, y, sy, stamp, sh, tid, nt, b);
                return true;
            }
            const done = sy + sync_header + 3 * t.n;
            const r0 = b * panel;
            const r1 = @min(r0 + panel, t.n - t.t0);
            var i = r0 + tid;
            while (i < r1) : (i += nt) {
                sh.a[i - r0] = y[t.t0 + i];
                sh.e[i - r0] = x[t.tl_ptr + i];
            }
            var j: u32 = 0;
            while (j < b) : (j += 1) {
                if (tid == 0) wait(&done[j], stamp);
                Sy.barrier();
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    const ga = gatherUntil(true, sh.a[i - r0], x, val, y + t.t0, t.tl_col, t.tl_slot, sh.e[i - r0], x[t.tl_ptr + i + 1], (j + 1) * panel);
                    sh.a[i - r0] = ga.acc;
                    sh.e[i - r0] = ga.e;
                }
            }
            loadBlock(x, val, t.tl_ptr, t.tl_col, t.tl_slot, r0, r1, sh, tid, nt);
            var c = r0;
            while (c < r1) : (c += 1) {
                // Row c holds every subtraction from columns before it.
                Sy.barrier();
                const yc = sh.a[c - r0];
                if (yc == 0) continue;
                const bit = @as(u64, 1) << @intCast(c - r0);
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    if (sh.mask[i - r0] & bit != 0) sh.a[i - r0] -= sh.blk[i - r0][c - r0] * yc;
                }
            }
            Sy.barrier();
            i = r0 + tid;
            while (i < r1) : (i += nt) y[t.t0 + i] = sh.a[i - r0];
            Sy.barrier();
            if (tid == 0) Sy.release(&done[b], stamp);
            return true;
        }

        /// The back tail for the panel its ticket names, last panel first:
        /// its rows take every later panel's columns as each publishes
        /// (descending), then sweep their own panel from its last row, each
        /// row dividing by its pivot when its turn comes, and publish z into
        /// `y` and `dx`.
        pub fn upanel(t: Tab, x: P(u32), val: P(f64), y: P(f64), dx: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32) bool {
            const b = takeTicket(sy, 5, sh, tid);
            const np = t.panels();
            if (b >= np) return false;
            if (sy[1] != 0) return true;
            if (t.levers & klu.lever_g7 != 0) {
                upanelLevels(t, x, val, y, dx, sy, stamp, sh, tid, nt, np - 1 - b, np);
                return true;
            }
            const done = sy + sync_header + 3 * t.n + np;
            const pb = np - 1 - b;
            const r0 = pb * panel;
            const r1 = @min(r0 + panel, t.n - t.t0);
            var i = r0 + tid;
            while (i < r1) : (i += nt) {
                sh.a[i - r0] = y[t.t0 + i];
                sh.e[i - r0] = x[t.tu_ptr + i];
            }
            var j = np - 1;
            while (j > pb) : (j -= 1) {
                if (tid == 0) wait(&done[j], stamp);
                Sy.barrier();
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    const ga = gatherUntil(false, sh.a[i - r0], x, val, y + t.t0, t.tu_col, t.tu_slot, sh.e[i - r0], x[t.tu_ptr + i + 1], j * panel);
                    sh.a[i - r0] = ga.acc;
                    sh.e[i - r0] = ga.e;
                }
            }
            loadBlock(x, val, t.tu_ptr, t.tu_col, t.tu_slot, r0, r1, sh, tid, nt);
            // The panel's pivots, staged with the block.
            i = r0 + tid;
            while (i < r1) : (i += nt) sh.d[i - r0] = val[x[t.t_diag + i]];
            var c = r1;
            while (c > r0) {
                c -= 1;
                Sy.barrier();
                if (tid == (c - r0) % nt) {
                    const z = sh.a[c - r0] / sh.d[c - r0];
                    sh.a[c - r0] = z;
                    y[t.t0 + c] = z;
                    dx[x[t.q + t.t0 + c]] = z;
                }
                Sy.barrier();
                const zc = sh.a[c - r0];
                if (zc == 0) continue;
                const bit = @as(u64, 1) << @intCast(c - r0);
                i = r0 + tid;
                while (i < c) : (i += nt) {
                    if (sh.mask[i - r0] & bit != 0) sh.a[i - r0] -= sh.blk[i - r0][c - r0] * zc;
                }
            }
            Sy.barrier();
            if (tid == 0) Sy.release(&done[pb], stamp);
            return true;
        }

        /// Spins until `p` holds `stamp`. Ends: the awaited column belongs
        /// to an earlier ticket, and a step waits only on earlier ones, so
        /// the earliest unfinished step never waits and always publishes.
        pub inline fn wait(p: anytype, stamp: u32) void {
            var spins: u32 = 0;
            while (Sy.acquire(p) != stamp) : (spins +%= 1) Sy.pause(spins);
        }

        /// Lane 0 takes the next ticket of counter `which` (a relaxed RMW);
        /// every lane returns it after the barrier.
        pub inline fn takeTicket(sy: P(u32), which: u32, sh: anytype, tid: u32) u32 {
            if (tid == 0) sh.k = @atomicRmw(u32, &sy[which], .Add, 1, .monotonic);
            Sy.barrier();
            return sh.k;
        }

        // ---- private ----

        /// `lpanel` under `lever_g7` for panel b: the block loads before the
        /// waits (`val` and the tables are final before the launch), then
        /// the earlier panels' columns as each publishes, then one barrier
        /// step per in-panel level, each row of the level pulling its
        /// masked columns in ascending order with `lpanel`'s zero skip.
        /// Rows of one level never read each other (`Tab.tl_lv`).
        fn lpanelLevels(t: Tab, x: P(u32), val: P(f64), y: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32, b: u32) void {
            const done = sy + sync_header + 3 * t.n;
            const r0 = b * panel;
            const r1 = @min(r0 + panel, t.n - t.t0);
            var i = r0 + tid;
            while (i < r1) : (i += nt) {
                sh.a[i - r0] = y[t.t0 + i];
                sh.e[i - r0] = x[t.tl_ptr + i];
            }
            blockAt(x, val, t.tl_in, t.tl_ptr, t.tl_col, t.tl_slot, r0, r1, sh, tid, nt);
            var j: u32 = 0;
            while (j < b) : (j += 1) {
                if (tid == 0) wait(&done[j], stamp);
                Sy.barrier();
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    const ga = gatherUntil(true, sh.a[i - r0], x, val, y + t.t0, t.tl_col, t.tl_slot, sh.e[i - r0], x[t.tl_in + i], (j + 1) * panel);
                    sh.a[i - r0] = ga.acc;
                    sh.e[i - r0] = ga.e;
                }
            }
            // A lane's own rows: their gather cursors are spent.
            i = r0 + tid;
            while (i < r1) : (i += nt) sh.e[i - r0] = x[t.tl_lv + i];
            const nlv = x[t.t_nlv + b];
            // Level 0 rows have no in-panel entry.
            var v: u32 = 1;
            while (v < nlv) : (v += 1) {
                // Every row of a lower level is final.
                Sy.barrier();
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    if (sh.e[i - r0] != v) continue;
                    var acc = sh.a[i - r0];
                    var m = sh.mask[i - r0];
                    // Ends: one of at most 64 bits cleared per pass.
                    while (m != 0) : (m &= m - 1) {
                        const c = @ctz(m);
                        const yc = sh.a[c];
                        if (yc != 0) acc -= sh.blk[i - r0][c] * yc;
                    }
                    sh.a[i - r0] = acc;
                }
            }
            Sy.barrier();
            i = r0 + tid;
            while (i < r1) : (i += nt) y[t.t0 + i] = sh.a[i - r0];
            Sy.barrier();
            if (tid == 0) Sy.release(&done[b], stamp);
        }

        /// `upanel` under `lever_g7` for panel pb (of np): as
        /// `lpanelLevels`, with the pivots staged before the waits too, the
        /// masked columns pulled in descending order, and each row dividing
        /// by its pivot in its own level's step.
        fn upanelLevels(t: Tab, x: P(u32), val: P(f64), y: P(f64), dx: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32, pb: u32, np: u32) void {
            const done = sy + sync_header + 3 * t.n + np;
            const r0 = pb * panel;
            const r1 = @min(r0 + panel, t.n - t.t0);
            var i = r0 + tid;
            while (i < r1) : (i += nt) {
                sh.a[i - r0] = y[t.t0 + i];
                sh.e[i - r0] = x[t.tu_ptr + i];
                sh.d[i - r0] = val[x[t.t_diag + i]];
            }
            blockAt(x, val, t.tu_in, t.tu_ptr, t.tu_col, t.tu_slot, r0, r1, sh, tid, nt);
            var j = np - 1;
            while (j > pb) : (j -= 1) {
                if (tid == 0) wait(&done[j], stamp);
                Sy.barrier();
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    const ga = gatherUntil(false, sh.a[i - r0], x, val, y + t.t0, t.tu_col, t.tu_slot, sh.e[i - r0], x[t.tu_in + i], j * panel);
                    sh.a[i - r0] = ga.acc;
                    sh.e[i - r0] = ga.e;
                }
            }
            i = r0 + tid;
            while (i < r1) : (i += nt) sh.e[i - r0] = x[t.tu_lv + i];
            const nlv = x[t.t_nlv + np + pb];
            var v: u32 = 0;
            while (v < nlv) : (v += 1) {
                Sy.barrier();
                i = r0 + tid;
                while (i < r1) : (i += nt) {
                    if (sh.e[i - r0] != v) continue;
                    var acc = sh.a[i - r0];
                    var m = sh.mask[i - r0];
                    // Ends: one of at most 64 bits cleared per pass.
                    while (m != 0) {
                        const c = 63 - @clz(m);
                        m ^= @as(u64, 1) << @intCast(c);
                        const zc = sh.a[c];
                        if (zc != 0) acc -= sh.blk[i - r0][c] * zc;
                    }
                    const z = acc / sh.d[i - r0];
                    sh.a[i - r0] = z;
                    y[t.t0 + i] = z;
                    dx[x[t.q + t.t0 + i]] = z;
                }
            }
            Sy.barrier();
            if (tid == 0) Sy.release(&done[pb], stamp);
        }

        /// Each row's remaining entries (all inside rows r0..r1's panel)
        /// into `sh.blk`, flagged in `sh.mask`; the barrier after it is the
        /// caller's first step.
        inline fn loadBlock(x: P(u32), val: P(f64), ptr: u32, col: u32, slot: u32, r0: u32, r1: u32, sh: anytype, tid: u32, nt: u32) void {
            var i = r0 + tid;
            while (i < r1) : (i += nt) {
                var m: u64 = 0;
                var e = sh.e[i - r0];
                const e1 = x[ptr + i + 1];
                while (e < e1) : (e += 1) {
                    const c = x[col + e] - r0;
                    sh.blk[i - r0][c] = val[x[slot + e]];
                    m |= @as(u64, 1) << @intCast(c);
                }
                sh.mask[i - r0] = m;
            }
        }

        /// `loadBlock` from each row's first in-panel entry `x[in + i]`, so
        /// it needs no gather first; eight entries' loads go out before
        /// their stores.
        inline fn blockAt(x: P(u32), val: P(f64), in: u32, ptr: u32, col: u32, slot: u32, r0: u32, r1: u32, sh: anytype, tid: u32, nt: u32) void {
            const U = 8;
            var i = r0 + tid;
            while (i < r1) : (i += nt) {
                var m: u64 = 0;
                var e = x[in + i];
                const e1 = x[ptr + i + 1];
                while (e + U <= e1) : (e += U) {
                    var cv: [U]u32 = undefined;
                    var lv: [U]f64 = undefined;
                    inline for (0..U) |u| {
                        cv[u] = x[col + e + u] - r0;
                        lv[u] = val[x[slot + e + u]];
                    }
                    inline for (0..U) |u| {
                        sh.blk[i - r0][cv[u]] = lv[u];
                        m |= @as(u64, 1) << @intCast(cv[u]);
                    }
                }
                while (e < e1) : (e += 1) {
                    const c = x[col + e] - r0;
                    sh.blk[i - r0][c] = val[x[slot + e]];
                    m |= @as(u64, 1) << @intCast(c);
                }
                sh.mask[i - r0] = m;
            }
        }

        const Ga = struct { acc: f64, e: u32 };

        /// `acc` minus val[slot[e]] * yt[col[e]] from entry e on while the
        /// column is on the near side of `bound`: col[e] < bound with the
        /// columns ascending (`below`), col[e] >= bound with them
        /// descending. Skips yt == 0; eight entries' loads go out before
        /// their subtractions.
        inline fn gatherUntil(comptime below: bool, acc0: f64, x: P(u32), val: P(f64), yt: P(f64), col: u32, slot: u32, e0: u32, e1: u32, bound: u32) Ga {
            const S = struct {
                inline fn in(c: u32, b: u32) bool {
                    return if (below) c < b else c >= b;
                }
            };
            const U = 8;
            var acc = acc0;
            var e = e0;
            while (e + U <= e1 and S.in(x[col + e + U - 1], bound)) : (e += U) {
                var yv: [U]f64 = undefined;
                var lv: [U]f64 = undefined;
                inline for (0..U) |u| {
                    yv[u] = yt[x[col + e + u]];
                    lv[u] = val[x[slot + e + u]];
                }
                inline for (0..U) |u| acc = if (yv[u] != 0) acc - lv[u] * yv[u] else acc;
            }
            while (e < e1 and S.in(x[col + e], bound)) : (e += 1) {
                const yk = yt[x[col + e]];
                if (yk != 0) acc -= val[x[slot + e]] * yk;
            }
            return .{ .acc = acc, .e = e };
        }
    };
}
