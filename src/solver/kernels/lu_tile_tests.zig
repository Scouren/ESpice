//! Tests of lever N1 (`Options.tile`, `lu_tile.zig`): the tiled tail's
//! factor and solution against `SparseLu.refactorColumns` plus `solve`,
//! bitwise, on one and four host threads and on blocks of lane threads,
//! with late sources (stored after a source of a later segment) inside the
//! tail and growth failures in and before it.
//! Cites: docs/perf_research/09-after-the-levers.md (N1).
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const K = @import("lu.zig");
const tile = @import("lu_tile.zig");
const SparseLu = @import("../sparse_lu.zig").SparseLu;

const Sys = struct {
    n: u32,
    col_ptr: []u32,
    row_idx: []u32,
    q: []u32,
    fn deinit(s: Sys, gpa: std.mem.Allocator) void {
        gpa.free(s.col_ptr);
        gpa.free(s.row_idx);
        gpa.free(s.q);
    }
};

const Runner = enum { one, threads, blocks };

// ---- private ----

// Blocks of `bs` rows with random couplings (density `p`), then `nb` border
// rows and columns coupled to everything at density `p`: the border fills
// into a dense-ish tail. Identity order; `bs = n, p = 1` is dense.
fn system(gpa: std.mem.Allocator, r: std.Random, blocks: u32, bs: u32, nb: u32, p: f64) !Sys {
    const n = blocks * bs + nb;
    var ri: std.ArrayList(u32) = .empty;
    errdefer ri.deinit(gpa);
    const cp = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(cp);
    cp[0] = 0;
    for (0..n) |j| {
        for (0..n) |i| {
            const border = i >= blocks * bs or j >= blocks * bs;
            const keep = i == j or ((border or i / bs == j / bs) and r.float(f64) < p);
            if (keep) try ri.append(gpa, @intCast(i));
        }
        cp[j + 1] = @intCast(ri.items.len);
    }
    const q = try gpa.alloc(u32, n);
    errdefer gpa.free(q);
    for (q, 0..) |*o, i| o.* = @intCast(i);
    return .{ .n = n, .col_ptr = cp, .row_idx = try ri.toOwnedSlice(gpa), .q = q };
}

fn values(s: Sys, r: std.Random, vals: []f64) void {
    for (0..s.n) |j| for (s.col_ptr[j]..s.col_ptr[j + 1]) |p| {
        vals[p] = if (s.row_idx[p] == j) 6 + r.float(f64) else r.float(f64) - 0.5;
    };
}

// Scales by 1e20 the A entries below the pivot of the first step from
// `from` on that has one: that step fails the growth limit.
fn growBelowPivot(s: Sys, lu: *const SparseLu, vals: []f64, from: u32) void {
    var k = from;
    while (k < s.n) : (k += 1) {
        var hit = false;
        for (s.col_ptr[s.q[k]]..s.col_ptr[s.q[k] + 1]) |p| if (lu.prow[p] > k) {
            vals[p] *= 1e20;
            hit = true;
        };
        if (hit) return;
    }
    unreachable;
}

// Tail columns (from `t0` on) whose sources do not come in segment order:
// the definition, written out (outside the tail, then panels ascending).
fn lateCols(lu: *const SparseLu, t0: u32) u32 {
    var count: u32 = 0;
    for (t0..lu.n) |k| {
        var hi: u32 = 0;
        for (lu.ui.items[lu.up[k]..lu.up[k + 1]]) |i| {
            const s = if (i < t0) 0 else 1 + (i - t0) / tile.tile_w;
            if (s < hi) {
                count += 1;
                break;
            }
            hi = s;
        }
    }
    return count;
}

// The tiled run of tail order `order` against the oracle: the same
// failing step, every step below it bitwise, and on success dx bitwise.
fn expectTile(gpa: std.mem.Allocator, comptime how: Runner, lu: *SparseLu, s: Sys, order: u32, vals: []const f64, rhs: []const f64, stamp: *u32) !bool {
    // Oracle: the host column loop and its solve (dx = -A^-1 rhs).
    const ok = if (SparseLu.test_access.refactorColumns(lu, s.col_ptr, vals, 1e-12)) |_| true else |_| false;
    const n = s.n;
    const buf = try gpa.alloc(f64, 4 * @as(usize, n));
    defer gpa.free(buf);
    const neg = buf[0..n];
    const ref_dx = buf[n..][0..n];
    const dx = buf[2 * n ..][0..n];
    const y = buf[3 * n ..][0..n];
    for (neg, rhs) |*o, b| o.* = -b;
    if (ok) lu.solve(neg, ref_dx);
    var tb = try K.build(gpa, lu, s.col_ptr, 1e-12, .{ .tile = true, .tile_order = order });
    defer tb.deinit(gpa);
    const t = tb.tab;
    try testing.expectEqual(order > 0, t.levers & K.lever_tile != 0);
    try testing.expectEqual(n - order, t.tile0);
    const val = try gpa.alloc(f64, t.n_val);
    defer gpa.free(val);
    const sync = try gpa.alloc(u32, t.syncLen());
    defer gpa.free(sync);
    @memset(sync, 0);
    @memset(dx, 0);
    stamp.* += 1;
    const bufs: K.HostBufs = .{ .idx = tb.idx, .val = val, .a = vals, .rhs = rhs, .y = y, .dx = dx, .sync = sync };
    const fail = try switch (how) {
        .one => K.test_access.runHostCap(K.col_max, t, bufs, stamp.*, 1),
        .threads => K.test_access.runHostCap(K.col_max, t, bufs, stamp.*, 4),
        .blocks => K.test_access.runBlocks(K.col_max, 4, t, bufs, stamp.*, 2),
    };
    try testing.expectEqual(ok, fail == null);
    for (0..fail orelse n) |k| {
        const base = tb.idx[t.coff + k];
        const nuk = lu.up[k + 1] - lu.up[k];
        const nlk = lu.lp[k + 1] - lu.lp[k];
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(lu.ux.items[lu.up[k]..lu.up[k + 1]]), std.mem.sliceAsBytes(val[base..][0..nuk]));
        try testing.expectEqual(@as(u64, @bitCast(lu.udiag[k])), @as(u64, @bitCast(val[base + nuk])));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(lu.lx.items[lu.lp[k]..lu.lp[k + 1]]), std.mem.sliceAsBytes(val[base + nuk + 1 ..][0..nlk]));
    }
    if (ok) try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ref_dx), std.mem.sliceAsBytes(dx));
    return ok;
}

test "lu tile: n1's tail is bitwise refactorColumns + solve on 1 and 4 threads and blocks, late sources and failures included" {
    // Oracle: SparseLu.refactorColumns + solve, bitwise. Tail orders: none,
    // a partial last panel (37), half, the whole factor. A sparse bordered
    // system (late sources inside some tail, their columns counted by the definition
    // above) and a dense one. Round 1 fails a growth test inside the tail,
    // round 2 before it.
    const gpa = testing.allocator;
    var rng = std.Random.DefaultPrng.init(0x7113);
    const r = rng.random();
    var stamp: u32 = 0;
    var lates: u32 = 0;
    var failed: u32 = 0;
    for ([_]bool{ false, true }) |is_dense| {
        const s = if (is_dense) try system(gpa, r, 1, 90, 0, 1) else try system(gpa, r, 5, 24, 20, 0.15);
        defer s.deinit(gpa);
        const vals = try gpa.alloc(f64, s.col_ptr[s.n]);
        defer gpa.free(vals);
        const rhs = try gpa.alloc(f64, s.n);
        defer gpa.free(rhs);
        var lu = try SparseLu.init(gpa, s.n, s.col_ptr, s.q);
        defer lu.deinit(gpa);
        values(s, r, vals);
        try lu.factor(gpa, s.col_ptr, s.row_idx, vals, 1e-3);
        for ([_]u32{ 0, 37, s.n / 2, s.n }) |order| {
            const lc = lateCols(&lu, s.n - order);
            lates += lc;
            if (order > 0) try testing.expectEqual(lc, tile.evaluate(&lu, order).late_cols);
            for (0..3) |round| {
                values(s, r, vals);
                for (rhs) |*x| x.* = r.float(f64) - 0.5;
                if (round == 1) growBelowPivot(s, &lu, vals, if (order > 0) s.n - order + order / 4 else s.n / 2);
                if (round == 2) growBelowPivot(s, &lu, vals, 0);
                inline for (.{ Runner.one, .threads, .blocks }) |how| {
                    if (!try expectTile(gpa, how, &lu, s, order, vals, rhs, &stamp)) failed += 1;
                }
            }
        }
    }
    // Two failing rounds per order and system, on each of the three runners.
    try testing.expectEqual(@as(u32, 2 * 4 * 2 * 3), failed);
    if (lates == 0) std.debug.print("lu tile: no late source in any tail\n", .{});
    try testing.expect(lates > 0);
}

test "lu tile: the rule leaves a thin or small tail on today's path" {
    // Oracle: hand counts. A diagonal 300 has no pairs, so its one
    // candidate (256) cannot pay for 16 hand-offs. A dense 300 (sources
    // ascending, none late) puts 8.69e6 of its 9e6 pairs in the 256-step
    // tail, against a chain of 2.50e5 in-panel pairs, 1.79e5 in the
    // longest update ticket before each panel (summed) and 16 hand-offs (16 times
    // that is 7.1e6) and 560 tickets (2.9e5 at 512 a ticket): admitted.
    const gpa = testing.allocator;
    var rng = std.Random.DefaultPrng.init(0x7114);
    const r = rng.random();
    for ([_]bool{ false, true }) |is_dense| {
        const s = if (is_dense) try system(gpa, r, 1, 300, 0, 1) else try system(gpa, r, 300, 1, 0, 0);
        defer s.deinit(gpa);
        const vals = try gpa.alloc(f64, s.col_ptr[s.n]);
        defer gpa.free(vals);
        values(s, r, vals);
        var lu = try SparseLu.init(gpa, s.n, s.col_ptr, s.q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, s.col_ptr, s.row_idx, vals, 1e-3);
        const pick = tile.choose(&lu, false);
        try testing.expectEqual(@as(u32, if (is_dense) 256 else 0), pick.order);
        var tb = try K.build(gpa, &lu, s.col_ptr, 1e-12, .{ .tile = true });
        defer tb.deinit(gpa);
        try testing.expectEqual(s.n - pick.order, tb.tab.tile0);
    }
}
