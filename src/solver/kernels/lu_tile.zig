//! Lever N1 (`lever_tile`): the tail of a thick factor right-looking in
//! tiles on host lanes. The refactor's tickets stop at `Tab.tile0`; the
//! tail's columns then run by tile tickets: each column takes its sources
//! before the tail (`external`), then panel by panel of `tile_w` steps a
//! panel is finished on one lane (`finish`) while every later tail column
//! takes that panel's sources (`update`), groups of `tile_cols` columns
//! per ticket. A column's slots get exactly `refactorColumns`'
//! subtractions in its stored U order, unfused, when its sources come in
//! segment order: outside the tail, then panel by panel. A source stored
//! after one of a later segment (late) runs in that later segment (the
//! running maximum), so stored order holds and every source is final when
//! it runs. The tickets
//! are numbered in dependency order, so one lane taking them all never
//! waits. In: a factored `SparseLu` (tables) and `Tab` (run); out: the
//! tail's factor in `val`, bitwise `SparseLu.refactorColumns`'.
//! Cites: docs/perf_research/09-after-the-levers.md (N1).
//!
//! Contents:
//! - `pub const tile_w = 16`
//! - `pub const tile_cols = 4`
//! - `pub const ticket_word = 6`
//! - `pub const Choice = struct`
//!   - `pub fn print(c: Choice) void`
//! - `pub const Tables = struct`
//! - `pub fn evaluate(lu: *const SparseLu, order: u32) Choice`
//! - `pub fn choose(lu: *const SparseLu, print: bool) Choice`
//! - `pub fn tables(ar: std.mem.Allocator, lu: *const SparseLu, tile0: u32, dcol: []const u32) !Tables`
//! - `pub fn Tile(comptime Sy: type) type`
//!   - `pub fn work(comptime D: type, t: Tab, x: P(u32), val: P(f64), a: P(f64), sy: P(u32), stamp: u32) void`

const std = @import("std");
const assert = std.debug.assert;
const klu = @import("lu.zig");
const lu_steps = @import("lu_steps.zig");
const lu_tail = @import("lu_tail.zig");
const SparseLu = @import("../sparse_lu.zig").SparseLu;
const Tab = klu.Tab;

/// Steps per panel. The finish chain costs about T * tile_w / 2 times a
/// tail column's rows in pairs, the hand-offs T / tile_w; 16 keeps both
/// under a sixteenth of logic_bsim4_10k's tail pairs (09-after-the-levers
/// N1; the report's sizing).
pub const tile_w = 16;

/// Tail columns per update ticket.
pub const tile_cols = 4;

/// Sync header word of the tile tickets (words 0-5: refactor, fail,
/// solves).
pub const ticket_word = 6;

/// One candidate tail's census, in pairs (multiply-subtracts).
pub const Choice = struct {
    /// Tail order T; 0 for none.
    order: u32 = 0,
    /// Pairs of the tail's columns, all sources; those run in their own
    /// segment and the late ones (after a source of a later segment), and
    /// the columns with a late source.
    pairs: u64 = 0,
    tiled: u64 = 0,
    late: u64 = 0,
    late_cols: u32 = 0,
    panels: u32 = 0,
    tickets: u64 = 0,
    /// The serial part, per panel: its finish's pairs, the longest update
    /// ticket feeding it and `handoff_pairs`.
    chain: u64 = 0,
    /// Whether the rule admits it.
    ok: bool = false,

    /// Prints the census as one `lu-tile:` line.
    pub fn print(c: Choice) void {
        assert(c.tiled + c.late == c.pairs);
        assert(c.order == 0 or c.panels > 0);
        std.debug.print("lu-tile: T={d} pairs={d} tiled={d} late={d} late_cols={d} panels={d} tickets={d} chain={d} admit={}\n", .{ c.order, c.pairs, c.tiled, c.late, c.late_cols, c.panels, c.tickets, c.chain, c.ok });
    }
};

/// The tail's tables (`Tab.tseg`, `tdm`, `tpan`); empty without a tail.
pub const Tables = struct {
    /// Per tail column, `tile_np + 2` words: segment s (0 outside the tail,
    /// 1 + P panel P) is U positions `tseg[s]..tseg[s + 1]`, its first
    /// flop at `dmap` entry `tdm[s]`; a position's segment is the latest of
    /// its own and its predecessors' sources'.
    tseg: []const u32 = &.{},
    tdm: []const u32 = &.{},
    /// Panel P's first ticket; `tpan[np]` is the ticket count, `tpan[0]`
    /// the external tickets'.
    tpan: []const u32 = &.{},
};

/// Tail orders the rule tries, largest first.
const candidates = [_]u32{ 4096, 2048, 1024, 512, 256 };

/// Lanes the rule designs for: `direct`'s 8-lane runs.
const lanes_design = 8;

/// A hand-off (a release, an acquire on another core and the waiter's
/// wake-up) in pair units: about 1 us at about 1 ns a pair on host lanes.
const handoff_pairs = 1000;

/// Pairs an update ticket must average: its atomic and its waits are
/// tens of ns.
const min_ticket_pairs = 512;

/// The census of tail order `order` (1..n) of `lu`'s current factor,
/// O(nnz(U) of the tail). Admitted when the serial chain is at most half
/// of the pairs over `lanes_design` lanes and the update tickets average
/// `min_ticket_pairs`.
pub fn evaluate(lu: *const SparseLu, order: u32) Choice {
    const n = lu.n;
    assert(order > 0 and order <= n);
    const t0 = n - order;
    const np = (order + tile_w - 1) / tile_w;
    var c: Choice = .{ .order = order, .panels = np };
    const ui = lu.ui.items;
    // Per update ticket of the panel's columns, the pairs of the segment
    // just before the panel's.
    var leg: [tile_w / tile_cols]u64 = @splat(0);
    for (t0..n) |k| {
        const rel = k - t0;
        if (rel % tile_w == 0) {
            c.chain += std.mem.max(u64, &leg);
            leg = @splat(0);
        }
        const pk = 1 + rel / tile_w;
        var hi: u32 = 0;
        var late = false;
        for (ui[lu.up[k]..lu.up[k + 1]]) |i| {
            const len = lu.lp[i + 1] - lu.lp[i];
            const s = if (i < t0) 0 else 1 + (i - t0) / tile_w;
            late = late or s < hi;
            hi = @max(hi, s);
            c.pairs += len;
            if (s < hi) c.late += len else c.tiled += len;
            if (hi == pk) c.chain += len;
            if (hi + 1 == pk) leg[(rel % tile_w) / tile_cols] += len;
        }
        assert(hi <= pk);
        if (late) c.late_cols += 1;
    }
    c.chain += std.mem.max(u64, &leg) + @as(u64, np) * handoff_pairs;
    c.tickets = (order + tile_cols - 1) / tile_cols;
    for (0..np) |p| {
        const p1 = @min(t0 + (p + 1) * tile_w, n);
        c.tickets += 1 + (n - p1 + tile_cols - 1) / tile_cols;
    }
    c.ok = c.chain * 2 * lanes_design <= c.pairs and c.pairs >= c.tickets * min_ticket_pairs;
    assert(c.tiled + c.late == c.pairs);
    return c;
}

/// The largest admitted candidate (`order` 0 when none); with `print`,
/// every candidate's census is printed.
pub fn choose(lu: *const SparseLu, print: bool) Choice {
    assert(lu.factored);
    var pick: Choice = .{};
    for (candidates) |order| {
        if (order > lu.n) continue;
        const c = evaluate(lu, order);
        if (print) c.print();
        if (c.ok and pick.order == 0) {
            pick = c;
            if (!print) break;
        }
    }
    assert(pick.order == 0 or pick.ok);
    return pick;
}

/// The tables of the tail from step `tile0` on (< n), `dcol` the columns'
/// first `dmap` entries (every tail column in stored-order form).
pub fn tables(ar: std.mem.Allocator, lu: *const SparseLu, tile0: u32, dcol: []const u32) !Tables {
    const n = lu.n;
    assert(tile0 < n);
    assert(dcol.len == @as(usize, n) + 1);
    const order = n - tile0;
    const np = (order + tile_w - 1) / tile_w;
    const row = np + 2;
    const tseg = try ar.alloc(u32, @as(usize, order) * row);
    const tdm = try ar.alloc(u32, tseg.len);
    for (tile0..n) |k| {
        const r = (k - tile0) * row;
        const seg = tseg[r..][0..row];
        const dm = tdm[r..][0..row];
        const up0 = lu.up[k];
        const up1 = lu.up[k + 1];
        seg[0] = up0;
        dm[0] = dcol[k];
        var cur: u32 = 0;
        var d = dcol[k];
        for (up0..up1) |pp| {
            const p: u32 = @intCast(pp);
            const i = lu.ui.items[p];
            const s = if (i < tile0) 0 else 1 + (i - tile0) / tile_w;
            // A late source stays in segment `cur`.
            while (cur < s) {
                cur += 1;
                seg[cur] = p;
                dm[cur] = d;
            }
            d += lu.lp[i + 1] - lu.lp[i];
        }
        while (cur < row - 1) {
            cur += 1;
            seg[cur] = up1;
            dm[cur] = d;
        }
        assert(d == dcol[k + 1]);
    }
    const tpan = try ar.alloc(u32, np + 1);
    var tk: u32 = (order + tile_cols - 1) / tile_cols;
    for (0..np) |p| {
        tpan[p] = tk;
        const p1: u32 = @intCast(@min(tile0 + (p + 1) * tile_w, n));
        tk += 1 + (n - p1 + tile_cols - 1) / tile_cols;
    }
    tpan[np] = tk;
    return .{ .tseg = tseg, .tdm = tdm, .tpan = tpan };
}

/// The tile tickets over `Sy` (`HostSy` or a lane of `BlockSy`; one lane a
/// worker, no block barrier).
pub fn Tile(comptime Sy: type) type {
    return struct {
        const P = Sy.P;
        const St = lu_steps.Steps(Sy);
        const Tl = lu_tail.Tail(Sy);

        /// Takes tile tickets until they run out; nothing without
        /// `lever_tile`. `D` is the `dmap` entry type. A failing step
        /// raises the fail word as `refactor` does; every step still runs.
        pub fn work(comptime D: type, t: Tab, x: P(u32), val: P(f64), a: P(f64), sy: P(u32), stamp: u32) void {
            if (t.levers & klu.lever_tile == 0) return;
            assert(t.tile0 < t.n and t.tile_np > 0);
            const ext = x[t.tpan];
            var pan: u32 = 0;
            var guard: u32 = 0;
            while (true) : (guard += 1) {
                assert(guard <= t.tile_tickets);
                const tk = @atomicRmw(u32, &sy[ticket_word], .Add, 1, .monotonic);
                if (tk >= t.tile_tickets) return;
                if (tk < ext) {
                    const c0 = t.tile0 + tk * tile_cols;
                    for (c0..@min(c0 + tile_cols, t.n)) |k| external(D, t, x, val, a, sy, stamp, @intCast(k));
                    continue;
                }
                while (x[t.tpan + pan + 1] <= tk) pan += 1;
                const r = tk - x[t.tpan + pan];
                if (r == 0) {
                    finish(D, t, x, val, sy, pan);
                    continue;
                }
                const stage = sy + t.tileSync();
                Tl.wait(&stage[t.n - t.tile0 + pan], 1);
                const c0 = @min(t.tile0 + (pan + 1) * tile_w, t.n) + (r - 1) * tile_cols;
                for (c0..@min(c0 + tile_cols, t.n)) |k| update(D, t, x, val, sy, pan, @intCast(k));
            }
        }

        // ---- private ----

        /// Column k's start: its A column scattered on zeroed slots, its
        /// sources before the tail (late ones too) waited for, segment 0
        /// applied; stage 1.
        fn external(comptime D: type, t: Tab, x: P(u32), val: P(f64), a: P(f64), sy: P(u32), stamp: u32, k: u32) void {
            assert(k >= t.tile0 and k < t.n);
            const base = x[t.coff + k];
            const width = x[t.coff + k + 1] - base;
            for (base..base + width) |s| val[s] = 0;
            const c = x[t.q + k];
            for (x[t.col_ptr + c]..x[t.col_ptr + c + 1]) |e| val[x[t.amap + e]] = a[e];
            const done = sy + klu.sync_header;
            for (x[t.up + k]..x[t.up + k + 1]) |p| {
                const i = x[t.ui + p];
                if (i < t.tile0) Tl.wait(&done[i], stamp);
            }
            const r = (k - t.tile0) * (t.tile_np + 2);
            apply(D, t, x, val, k, x[t.up + k], x[t.tseg + r + 1], x[t.tdm + r]);
            const stage = sy + t.tileSync();
            Sy.release(&stage[k - t.tile0], 1);
        }

        /// Panel `pan`'s sources into column k (past the panel), after its
        /// earlier panels': stage pan + 1 to pan + 2.
        fn update(comptime D: type, t: Tab, x: P(u32), val: P(f64), sy: P(u32), pan: u32, k: u32) void {
            assert(k >= t.tile0 + (pan + 1) * tile_w);
            const stage = sy + t.tileSync();
            const rel = k - t.tile0;
            Tl.wait(&stage[rel], pan + 1);
            const r = rel * (t.tile_np + 2);
            apply(D, t, x, val, k, x[t.tseg + r + 1 + pan], x[t.tseg + r + 2 + pan], x[t.tdm + r + 1 + pan]);
            Sy.release(&stage[rel], pan + 2);
        }

        /// Panel `pan`'s columns in order: each its segment `pan + 1`, then
        /// `refactorColumns`' pivot tests.
        /// Publishes the panel.
        fn finish(comptime D: type, t: Tab, x: P(u32), val: P(f64), sy: P(u32), pan: u32) void {
            const stage = sy + t.tileSync();
            const p0 = t.tile0 + pan * tile_w;
            assert(pan < t.tile_np and p0 < t.n);
            for (p0..@min(p0 + tile_w, t.n)) |kk| {
                const k: u32 = @intCast(kk);
                const rel = k - t.tile0;
                Tl.wait(&stage[rel], pan + 1);
                const r = rel * (t.tile_np + 2);
                apply(D, t, x, val, k, x[t.tseg + r + 1 + pan], x[t.tseg + r + 2 + pan], x[t.tdm + r + 1 + pan]);
                if (pivot(t, x, val, k)) _ = @atomicRmw(u32, &sy[1], .Max, t.n - k, .monotonic);
            }
            Sy.release(&stage[t.n - t.tile0 + pan], 1);
        }

        /// U positions p0..p1 of column k in stored order, its flops from
        /// `dmap` entry d0: `column`'s loop on `val`.
        fn apply(comptime D: type, t: Tab, x: P(u32), val: P(f64), k: u32, p0: u32, p1: u32, d0: u32) void {
            const base = x[t.coff + k];
            const up0 = x[t.up + k];
            assert(up0 <= p0 and p0 <= p1 and p1 <= x[t.up + k + 1]);
            var d = d0;
            for (p0..p1) |p| {
                const u = val[base + p - up0];
                const l0 = x[t.ul0 + p];
                const len = x[t.ulen + p];
                for (0..len) |j| {
                    const dst = St.slotAt(D, x, t, d + @as(u32, @intCast(j)), base);
                    val[dst] -= val[l0 + j] * u;
                }
                d += len;
            }
        }

        /// `column`'s pivot tests on `val` for column k; true when the step
        /// fails or a slot is not finite.
        fn pivot(t: Tab, x: P(u32), val: P(f64), k: u32) bool {
            const base = x[t.coff + k];
            const end = x[t.coff + k + 1];
            const diag = base + x[t.up + k + 1] - x[t.up + k];
            assert(diag < end);
            const flags = x[t.flags + k];
            var bad = false;
            if (flags & klu.void_bit != 0) {
                val[diag] = 1;
                for (diag + 1..end) |l| val[l] = 0;
            } else {
                const dv = val[diag];
                if (dv == 0 or !std.math.isFinite(dv)) {
                    bad = true;
                } else {
                    var cm = @abs(dv);
                    for (diag + 1..end) |l| {
                        const v = val[l];
                        cm = @max(cm, @abs(v));
                        val[l] = v / dv;
                    }
                    if (t.growth > 0 and flags & klu.scaled_bit == 0) bad = @abs(dv) < t.growth * cm;
                }
            }
            var nonfinite = false;
            for (base..end) |s| nonfinite = nonfinite or !std.math.isFinite(val[s]);
            return bad or nonfinite;
        }
    };
}
