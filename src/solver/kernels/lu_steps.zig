//! The refactor's stored-order step loops for `kernels/lu.zig`'s `column`:
//! a column's values in its working slots `w` and the source columns' L
//! values in `val` in, the column's slots after every U entry's flops out.
//! Today's loop lives in `column`; these are its lever forms. `storedEarly`
//! (`lever_g2`, M3) moves the next step's first loads ahead of the step-end
//! barrier. `storedRuns` (`lever_runs`, G2 part 2 stage A) takes a run of
//! consecutive steps of one supernode as one step: one wait, then the
//! run's triangle on one lane and its rectangular rows on all lanes, each
//! slot receiving its subtractions in stored order, unfused, so the factor
//! stays bitwise `refactorColumns`'s. `copyPanel` keeps the panels the runs
//! read (C1's `pv`, placed in `val` after the discard slot).
//! std only: the kernel root compiles this file for NVPTX and AMDGCN.
//! Cites: docs/perf_research/10-device-lu-chain.md (M1, M3); `lu_runs.zig`.
//!
//! Contents:
//! - `pub fn Steps(comptime Sy: type) type`
//!   - `pub inline fn pollWindow(t: Tab, x: P(u32), done: P(u32), stamp: u32, sh: anytype, par: u1, p0: u32, up1: u32, tid: u32) void`
//!   - `pub inline fn slotAt(comptime D: type, x: P(u32), t: Tab, i: u32, base: u32) u32`
//!   - `pub inline fn storedEarly(...) void`
//!   - `pub inline fn storedRuns(...) void`
//!   - `pub inline fn copyPanel(t: Tab, x: P(u32), val: P(f64), w: anytype, o: u32, k: u32, nuk: u32, width: u32, tid: u32, nt: u32) void`

const std = @import("std");
const klu = @import("lu.zig");
const lu_tail = @import("lu_tail.zig");
const Tab = klu.Tab;
const narrow_discard = klu.narrow_discard;

/// `Tab.lpv` entry of an L slot whose column is no panel step.
const no_panel: u32 = std.math.maxInt(u32);

/// The loops over `Sy` (see `klu.Kernels`).
pub fn Steps(comptime Sy: type) type {
    return struct {
        const P = Sy.P;
        const Tl = lu_tail.Tail(Sy);

        /// Lane 0 waits for step p0's source; lane t > 0 checks step
        /// p0 + t's once and records the first unfinished one in
        /// `sh.first[par]`. After the caller's barrier, every source that
        /// read done is visible to the whole block.
        pub inline fn pollWindow(t: Tab, x: P(u32), done: P(u32), stamp: u32, sh: anytype, par: u1, p0: u32, up1: u32, tid: u32) void {
            const p = p0 + tid;
            if (p >= up1) return;
            const src = &done[x[t.ui + p]];
            if (tid == 0) {
                Tl.wait(src, stamp);
            } else if (Sy.acquire(src) != stamp) {
                _ = @atomicRmw(u32, &sh.first[par], .Min, p, .monotonic);
            }
        }

        /// Flop i's destination: an absolute value slot or `t.discard`.
        pub inline fn slotAt(comptime D: type, x: P(u32), t: Tab, i: u32, base: u32) u32 {
            if (D == u32) return x[t.dmap + i];
            // A narrow dmap starts the index buffer (`t.dmap` is 0).
            const rel = @as(P(u16), @ptrCast(x))[i];
            return if (rel == narrow_discard) t.discard else base + rel;
        }

        /// `column`'s stored-order loop under `lever_g2`: before each
        /// step-end barrier a lane loads the next step's first group of
        /// four destinations, and that group's L values too when the next
        /// source is already known done (no poll for it this step). The
        /// flops, and each slot's order of them, are the loop's; only loads
        /// move ahead of a barrier, never a load of `w`.
        pub inline fn storedEarly(comptime D: type, comptime S: type, w: anytype, o: u32, t: Tab, x: P(u32), val: P(f64), done: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32, k: u32, base: u32, width: u32) void {
            const U = 4;
            const up0 = x[t.up + k];
            const up1 = x[t.up + k + 1];
            var ready = up0;
            var par: u1 = 0;
            if (up0 < up1) pollWindow(t, x, done, stamp, sh, par, up0, up1, tid);
            Sy.barrier();
            if (up0 < up1) {
                ready = @max(@min(sh.first[par], up0 + nt), up0 + 1);
                par ^= 1;
            }
            var d = x[t.dcol + k];
            var p = up0;
            var l0 = if (up0 < up1) x[t.ul0 + up0] else 0;
            var len = if (up0 < up1) x[t.ulen + up0] else 0;
            // This step's first group (j = tid), if the step before loaded
            // its destinations, and its L values when `pre_l`.
            var pre = false;
            var pre_l = false;
            var pdst: [U]u32 = undefined;
            var plv: [U]f64 = undefined;
            while (p < up1) : (p += 1) {
                const u = w[o + p - up0];
                const more = p + 1 < up1;
                const nl0 = if (more) x[t.ul0 + p + 1] else 0;
                const nlen = if (more) x[t.ulen + p + 1] else 0;
                var j = tid;
                if (pre) {
                    if (!pre_l) {
                        inline for (0..U) |m| plv[m] = val[l0 + j + m * nt];
                    }
                    var pwv: [U]f64 = undefined;
                    inline for (0..U) |m| pwv[m] = w[pdst[m]];
                    inline for (0..U) |m| w[pdst[m]] = pwv[m] - plv[m] * u;
                    j += U * nt;
                }
                step(D, S, w, t, x, val, d, l0, len, u, j, nt, base, width);
                d += len;
                const poll = more and p + 1 >= ready;
                // A source before `ready` was seen done before an earlier
                // barrier, so its L values are visible to every lane now.
                pre = more and tid + (U - 1) * nt < nlen;
                pre_l = pre and !poll;
                if (pre) {
                    inline for (0..U) |m| pdst[m] = S.at(slotAt(D, x, t, d + tid + @as(u32, m) * nt, base), base, width);
                    if (pre_l) {
                        inline for (0..U) |m| plv[m] = val[nl0 + tid + m * nt];
                    }
                }
                if (poll) pollWindow(t, x, done, stamp, sh, par, p + 1, up1, tid);
                Sy.barrier();
                if (poll) {
                    ready = @max(@min(sh.first[par], p + 1 + nt), p + 2);
                    if (tid == 0) sh.first[par ^ 1] = ~@as(u32, 0);
                    par ^= 1;
                }
                l0 = nl0;
                len = nlen;
            }
        }

        /// `column`'s stored-order loop under `lever_runs`, for a column
        /// with runs (`t.rcol`). Items in stored U order: a U entry outside
        /// the runs is today's step (its flops in `dmap`); a run is one
        /// item. Before a run every lane waits directly on a share of its
        /// sources (all acquired, then one barrier); a single step's source
        /// goes through the poll windows as today.
        pub inline fn storedRuns(comptime D: type, comptime S: type, w: anytype, o: u32, t: Tab, x: P(u32), val: P(f64), done: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32, k: u32, base: u32, width: u32) void {
            const up0 = x[t.up + k];
            const up1 = x[t.up + k + 1];
            const re = x[t.rcol + k + 1];
            var ri = x[t.rcol + k];
            var ready = up0;
            var par: u1 = 0;
            var d = x[t.dcol + k];
            var p = up0;
            // The first item's sources, as an item's end does for the next.
            var poll = up0 < up1 and !isRun(t, x, ri, re, up0);
            if (poll) pollWindow(t, x, done, stamp, sh, par, up0, up1, tid);
            if (up0 < up1 and !poll) ready = waitRun(t, x, done, stamp, ready, ri, tid, nt);
            Sy.barrier();
            if (poll) {
                ready = @max(@min(sh.first[par], up0 + nt), up0 + 1);
                par ^= 1;
            }
            // Ends: each pass consumes at least one U entry.
            while (p < up1) {
                if (isRun(t, x, ri, re, p)) {
                    p += applyRun(S, w, o, t, x, val, ri, p - up0, tid, nt, base, width);
                    ri += 1;
                } else {
                    const u = w[o + p - up0];
                    const len = x[t.ulen + p];
                    step(D, S, w, t, x, val, d, x[t.ul0 + p], len, u, tid, nt, base, width);
                    d += len;
                    p += 1;
                }
                poll = p < up1 and p >= ready and !isRun(t, x, ri, re, p);
                if (poll) pollWindow(t, x, done, stamp, sh, par, p, up1, tid);
                if (p < up1 and isRun(t, x, ri, re, p)) ready = waitRun(t, x, done, stamp, ready, ri, tid, nt);
                Sy.barrier();
                if (poll) {
                    ready = @max(@min(sh.first[par], p + nt), p + 1);
                    if (tid == 0) sh.first[par ^ 1] = ~@as(u32, 0);
                    par ^= 1;
                }
            }
        }

        /// Copies column k's final L slots into the panels (`t.lpv`) when k
        /// is a panel step, before the column is published; `w[o + s]` is
        /// column slot s.
        pub inline fn copyPanel(t: Tab, x: P(u32), val: P(f64), w: anytype, o: u32, k: u32, nuk: u32, width: u32, tid: u32, nt: u32) void {
            const l0 = x[t.lp + k];
            var s = nuk + 1 + tid;
            while (s < width) : (s += nt) {
                const at = x[t.lpv + l0 + s - nuk - 1];
                if (at != no_panel) val[at] = w[o + s];
            }
        }

        // ---- private ----

        /// One U entry's flops: `len` L values from `l0` times `u` into the
        /// slots `dmap[d..]` names, from entry j on, four loads ahead of
        /// their stores (the destinations are distinct).
        inline fn step(comptime D: type, comptime S: type, w: anytype, t: Tab, x: P(u32), val: P(f64), d: u32, l0: u32, len: u32, u: f64, j0: u32, nt: u32, base: u32, width: u32) void {
            const U = 4;
            var j = j0;
            while (j + (U - 1) * nt < len) : (j += U * nt) {
                var dst: [U]u32 = undefined;
                var lv: [U]f64 = undefined;
                var wv: [U]f64 = undefined;
                inline for (0..U) |m| {
                    dst[m] = S.at(slotAt(D, x, t, d + j + @as(u32, m) * nt, base), base, width);
                    lv[m] = val[l0 + j + m * nt];
                }
                inline for (0..U) |m| wv[m] = w[dst[m]];
                inline for (0..U) |m| w[dst[m]] = wv[m] - lv[m] * u;
            }
            while (j < len) : (j += nt) {
                const dst = S.at(slotAt(D, x, t, d + j, base), base, width);
                w[dst] -= val[l0 + j] * u;
            }
        }

        /// Whether run ri (of the column's runs, which end at re) starts at
        /// U entry p.
        inline fn isRun(t: Tab, x: P(u32), ri: u32, re: u32, p: u32) bool {
            return ri < re and x[t.rinfo + 6 * ri] == p;
        }

        /// Every lane acquires the done stamps of a share of run ri's
        /// entries not yet known done; the caller's barrier then makes
        /// them visible to the block. Returns the new `ready`.
        inline fn waitRun(t: Tab, x: P(u32), done: P(u32), stamp: u32, ready: u32, ri: u32, tid: u32, nt: u32) u32 {
            const at = x[t.rinfo + 6 * ri];
            const end = at + x[t.rinfo + 6 * ri + 1];
            var p = @max(ready, at) + tid;
            while (p < end) : (p += nt) Tl.wait(&done[x[t.ui + p]], stamp);
            return @max(ready, end);
        }

        /// Run ri at the column's U slot u_at: `rinfo[6 ri..]` is its U
        /// position, length, the `val` index of its first step's panel
        /// column, the panel's rows, its first step's panel slot offset s0
        /// (step - first) and its `rmap` offset. Panel slot s of step j is
        /// `val[pb + j * nr + s]`. Lane 0 runs the triangle (the run's own
        /// rows, U slots u_at + 1..), row by row; then every lane takes
        /// rectangular rows (panel slots s0 + len - 1.., destinations in
        /// `rmap`), each subtracting the run's steps in order. Returns the
        /// run's length.
        inline fn applyRun(comptime S: type, w: anytype, o: u32, t: Tab, x: P(u32), val: P(f64), ri: u32, u_at: u32, tid: u32, nt: u32, base: u32, width: u32) u32 {
            const info = t.rinfo + 6 * ri;
            const len = x[info + 1];
            const pb = x[info + 2];
            const nr = x[info + 3];
            const s0 = x[info + 4];
            const m0 = x[info + 5];
            const ub = o + u_at;
            if (tid == 0) {
                var r: u32 = 1;
                while (r < len) : (r += 1) {
                    var acc = w[ub + r];
                    var j: u32 = 0;
                    while (j < r) : (j += 1) acc -= val[pb + j * nr + s0 + r - 1] * w[ub + j];
                    w[ub + r] = acc;
                }
            }
            // Every U value of the run is final.
            Sy.barrier();
            const r0 = s0 + len - 1;
            var i = tid;
            while (i < nr - r0) : (i += nt) {
                const dst = S.at(x[t.rmap + m0 + i], base, width);
                var acc = w[dst];
                var j: u32 = 0;
                while (j < len) : (j += 1) acc -= val[pb + j * nr + r0 + i] * w[ub + j];
                w[dst] = acc;
            }
            return len;
        }
    };
}
