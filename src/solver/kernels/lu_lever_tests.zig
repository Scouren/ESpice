//! Tests of the device LU's exact levers G2 part 1 (`Options.g2`), G2 part
//! 2 stage A (`Options.runs`) and G7 stage 1 (`Options.g7`): every lever
//! combination's factor and solution
//! against `SparseLu.refactorColumns` plus `solve` and against the
//! lever-off run, bitwise, on the one-lane host twin (`runHostCap`) and on
//! blocks of four lane threads (`runBlocks`); and the G7 tables against
//! the definition of an in-panel level.
//! Cites: docs/perf_research/05-levers-gpu.md (G2, G7),
//! docs/perf_research/10-device-lu-chain.md (M2, M3).
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const K = @import("lu.zig");
const SparseLu = @import("../sparse_lu.zig").SparseLu;
const order = @import("../order.zig");
const lu_runs = @import("../lu_runs.zig");

const Case = struct {
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    q: []const u32,
    fn deinit(c: *Case, gpa: std.mem.Allocator) void {
        gpa.free(c.col_ptr);
        gpa.free(c.row_idx);
        gpa.free(c.q);
    }
};

/// The lever settings, lever-off first: the reference run.
const combos = [_]struct { g2: bool, g7: bool, runs: bool = false }{
    .{ .g2 = false, .g7 = false },               .{ .g2 = true, .g7 = false },
    .{ .g2 = false, .g7 = true },                .{ .g2 = true, .g7 = true },
    .{ .g2 = false, .g7 = false, .runs = true }, .{ .g2 = true, .g7 = true, .runs = true },
};

/// The runs one lever setting is checked on.
const Runner = enum { one, threads, in_val, blocks, blocks_small_cap };

// ---- private ----

// tests.zig's `LuKernelTests.circuit`, copied (it is private there): random
// couplings in clusters of 6, a rail coupled to most unknowns (a wide U
// column), a branch row with a zero diagonal, a void unknown; AMD order.
fn circuit(gpa: std.mem.Allocator, n: u32, seed: u64) !Case {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const v = n - 1;
    const rail = n - 2;
    const br = 5;
    const dense_p = try gpa.alloc(bool, n * n);
    defer gpa.free(dense_p);
    @memset(dense_p, false);
    for (0..n - 1) |j| {
        dense_p[j * n + j] = true;
        for (0..2) |_| {
            const i = @min(@as(u32, @intCast(j / 6 * 6)) + r.uintLessThan(u32, 6), n - 3);
            dense_p[i * n + j] = true;
            dense_p[j * n + i] = true;
        }
        if (j % 3 != 0) {
            dense_p[rail * n + j] = true;
            dense_p[j * n + rail] = true;
        }
    }
    dense_p[v * n + v] = true;
    dense_p[3 * n + v] = true;
    dense_p[v * n + 3] = true;
    dense_p[br * n + 2] = true;
    dense_p[2 * n + br] = true;
    var rows: std.ArrayList(u32) = .empty;
    errdefer rows.deinit(gpa);
    const col_ptr = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(col_ptr);
    col_ptr[0] = 0;
    for (0..n) |j| {
        for (0..n) |i| if (dense_p[i * n + j]) try rows.append(gpa, @intCast(i));
        col_ptr[j + 1] = @intCast(rows.items.len);
    }
    const q = try gpa.alloc(u32, n);
    errdefer gpa.free(q);
    const ws_buf = try gpa.alloc(u32, order.wsSize(n, col_ptr[n]));
    defer gpa.free(ws_buf);
    var ws = order.Ws.init(ws_buf);
    const row_idx = try rows.toOwnedSlice(gpa);
    errdefer gpa.free(row_idx);
    try order.order(n, col_ptr, row_idx, q, &ws);
    return .{ .n = n, .col_ptr = col_ptr, .row_idx = row_idx, .q = q };
}

// A full m x m pattern in natural order: one supernode of every column,
// each column m slots wide (U k, pivot, L m - 1 - k), every tail panel's
// block a full triangle (64 in-panel levels).
fn dense(gpa: std.mem.Allocator, m: u32) !Case {
    const col_ptr = try gpa.alloc(u32, m + 1);
    errdefer gpa.free(col_ptr);
    const row_idx = try gpa.alloc(u32, m * m);
    errdefer gpa.free(row_idx);
    const q = try gpa.alloc(u32, m);
    for (0..m + 1) |j| col_ptr[j] = @intCast(j * m);
    for (row_idx, 0..) |*i, p| i.* = @intCast(p % m);
    for (q, 0..) |*o, j| o.* = @intCast(j);
    return .{ .n = m, .col_ptr = col_ptr, .row_idx = row_idx, .q = q };
}

// `circuit`'s values (tests.zig's `values`); a dense case gets a dominant
// diagonal.
fn values(c: Case, is_dense: bool, r: std.Random, vals: []f64) void {
    const v = c.n - 1;
    const br = 5;
    for (0..c.n) |j| for (c.col_ptr[j]..c.col_ptr[j + 1]) |p| {
        const i = c.row_idx[p];
        vals[p] = if (is_dense)
            (if (i == j) @as(f64, @floatFromInt(c.n)) + r.float(f64) else r.float(f64) - 0.5)
        else if (i == v or j == v) 0 else if (i == br or j == br) (if (i < j) 1 else if (i > j) -1 else 0) else if (i == j) 4 + r.float(f64) else r.float(f64) - 0.5;
    };
}

// tests.zig's `growBelowPivot`: scales by 1e20 the A entries below the
// pivot of the first step from `from` on that has one, so that step fails
// the growth limit.
fn growBelowPivot(c: Case, lu: *const SparseLu, vals: []f64, from: u32) void {
    var k = from;
    while (k < c.n) : (k += 1) {
        var hit = false;
        for (c.col_ptr[c.q[k]]..c.col_ptr[c.q[k] + 1]) |p| if (lu.prow[p] > k) {
            vals[p] *= 1e20;
            hit = true;
        };
        if (hit) return;
    }
    unreachable;
}

/// Runs the kernels with `tb` and checks them against the oracle: the
/// same failing step, every step below it the oracle's factor bitwise,
/// and on success the oracle's dx bitwise. Returns the run's factor
/// values (the discard slot zeroed: void flops race there) and dx.
fn runChecked(gpa: std.mem.Allocator, comptime how: Runner, lu: *const SparseLu, tb: K.Tables, vals: []const f64, rhs: []const f64, ok: bool, ref_dx: []const f64, stamp: *u32) !struct { val: []f64, dx: []f64 } {
    const n = lu.n;
    const t = tb.tab;
    const val = try gpa.alloc(f64, t.n_val);
    errdefer gpa.free(val);
    const dx = try gpa.alloc(f64, n);
    errdefer gpa.free(dx);
    const y = try gpa.alloc(f64, n);
    defer gpa.free(y);
    const sync = try gpa.alloc(u32, t.syncLen());
    defer gpa.free(sync);
    @memset(sync, 0);
    @memset(dx, 0);
    stamp.* += 1;
    const bufs: K.HostBufs = .{ .idx = tb.idx, .val = val, .a = vals, .rhs = rhs, .y = y, .dx = dx, .sync = sync };
    const ta = K.test_access;
    const fail = try switch (how) {
        .one => ta.runHostCap(K.col_max, t, bufs, stamp.*, 1),
        .threads => ta.runHostCap(K.col_max, t, bufs, stamp.*, 4),
        .in_val => ta.runHostCap(0, t, bufs, stamp.*, 4),
        .blocks => ta.runBlocks(K.col_max, 4, t, bufs, stamp.*, 2),
        // A 64-slot scratch: a dense 64/65 case sits on its boundary.
        .blocks_small_cap => ta.runBlocks(64, 4, t, bufs, stamp.*, 2),
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
    val[t.discard] = 0;
    return .{ .val = val, .dx = dx };
}

/// For each lever setting, runs `how` and checks it against the oracle
/// (`runChecked`) and against the lever-off run of the same runner.
/// Returns whether the oracle succeeded.
fn expectLevers(gpa: std.mem.Allocator, comptime how: Runner, lu: *SparseLu, c: Case, tail: ?u32, vals: []const f64, rhs: []const f64, stamp: *u32) !bool {
    // Oracle: the host column loop and its solve.
    const ok = if (SparseLu.test_access.refactorColumns(lu, c.col_ptr, vals, 1e-12)) |_| true else |_| false;
    const neg = try gpa.alloc(f64, c.n);
    defer gpa.free(neg);
    for (neg, rhs) |*o, b| o.* = -b;
    const ref_dx = try gpa.alloc(f64, c.n);
    defer gpa.free(ref_dx);
    if (ok) lu.solve(neg, ref_dx);
    var off_val: []f64 = &.{};
    defer gpa.free(off_val);
    for (combos, 0..) |lv, i| {
        var tb = try K.build(gpa, lu, c.col_ptr, 1e-12, .{ .tail = tail, .g2 = lv.g2, .g7 = lv.g7, .runs = lv.runs });
        defer tb.deinit(gpa);
        const got = try runChecked(gpa, how, lu, tb, vals, rhs, ok, ref_dx, stamp);
        defer gpa.free(got.dx);
        if (i == 0) {
            off_val = got.val;
            continue;
        }
        defer gpa.free(got.val);
        // Oracle: the lever-off run; on a failure only the slots of steps
        // below it are defined, which `runChecked` compared. `runs` adds
        // its panels after the discard slot.
        if (ok) try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(off_val), std.mem.sliceAsBytes(got.val[0..off_val.len]));
    }
    return ok;
}

/// Factors `c` with C1's tables and checks every lever setting on `vals`
/// (perturbed per round, round 2 grown past a pivot) on four runners.
/// Returns the failing rounds.
fn checkRuns(gpa: std.mem.Allocator, c: Case, vals0: []const f64, r: std.Random, stamp: *u32) !u32 {
    var lu = try SparseLu.init(gpa, c.n, c.col_ptr, c.q);
    defer lu.deinit(gpa);
    lu.runs_on = true;
    try lu.factor(gpa, c.col_ptr, c.row_idx, vals0, 1e-3);
    const vals = try gpa.alloc(f64, vals0.len);
    defer gpa.free(vals);
    const rhs = try gpa.alloc(f64, c.n);
    defer gpa.free(rhs);
    var failed: u32 = 0;
    for (0..3) |round| {
        for (vals, vals0) |*o, v| o.* = v * (0.9 + 0.2 * r.float(f64));
        for (rhs) |*x| x.* = r.float(f64) - 0.5;
        if (round == 2) growBelowPivot(c, &lu, vals, 0);
        inline for (.{ Runner.one, .threads, .in_val, .blocks }) |how| {
            if (!try expectLevers(gpa, how, &lu, c, null, vals, rhs, stamp)) failed += 1;
        }
    }
    return failed;
}

/// Panel steps of a column's U list taken one at a time (outside every
/// run): a supernode broken by the stored order, or a run too short.
fn singlePanelSteps(lu: *const SparseLu) u32 {
    const v = lu.runs.view();
    if (v.run_ptr.len == 0) return 0;
    var count: u32 = 0;
    for (0..lu.n) |k| {
        var ri = v.run_ptr[k];
        for (lu.up[k]..lu.up[k + 1]) |p| {
            if (ri < v.run_ptr[k + 1] and p >= v.run_at[ri]) {
                if (p + 1 == v.run_at[ri] + v.run_len[ri]) ri += 1;
                continue;
            }
            count += @intFromBool(v.sn[lu.ui.items[p]] != std.math.maxInt(u32));
        }
    }
    return count;
}

test "lu levers: g2 and g7 are bitwise refactorColumns + solve on host lanes, failures included" {
    // Oracle: SparseLu.refactorColumns + solve, and the lever-off run, both
    // bitwise; four lane threads per block for the device's interleaving.
    const gpa = testing.allocator;
    var c = try circuit(gpa, 300, 0x11C0);
    defer c.deinit(gpa);
    const vals = try gpa.alloc(f64, c.col_ptr[c.n]);
    defer gpa.free(vals);
    const rhs = try gpa.alloc(f64, c.n);
    defer gpa.free(rhs);
    var rng = std.Random.DefaultPrng.init(0x6276);
    const r = rng.random();
    var lu = try SparseLu.init(gpa, c.n, c.col_ptr, c.q);
    defer lu.deinit(gpa);
    values(c, false, r, vals);
    lu.runs_on = true;
    try lu.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
    var stamp: u32 = 0;
    var failed: u32 = 0;
    // Solves all head (the cost model's pick), half tail, all tail.
    for ([_]?u32{ null, c.n / 2, 0 }) |tail| for (0..3) |round| {
        values(c, false, r, vals);
        for (rhs, 0..) |*x, i| x.* = switch (i % 5) {
            0 => 0,
            1 => -0.0,
            else => r.float(f64) - 0.5,
        };
        if (round == 2) growBelowPivot(c, &lu, vals, 40);
        inline for (.{ Runner.one, .threads, .in_val, .blocks }) |how| {
            if (!try expectLevers(gpa, how, &lu, c, tail, vals, rhs, &stamp)) failed += 1;
        }
    };
    // One failing round per tail, on each of the four runners.
    try testing.expectEqual(3 * 4, failed);
}

test "lu levers: dense columns at the col_max boundary and wide supernodes stay bitwise" {
    // Oracle: as above. Dense 256 works in shared memory (width = col_max),
    // 257 in `val`; on four-lane blocks with a 64-slot scratch, 64 and 65
    // sit on that boundary. Tail 0 makes every panel a full triangle.
    const gpa = testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xD3E5);
    const r = rng.random();
    var stamp: u32 = 0;
    inline for (.{ .{ 256, Runner.one }, .{ 257, Runner.threads }, .{ 64, Runner.blocks_small_cap }, .{ 65, Runner.blocks_small_cap } }) |cfg| {
        var c = try dense(gpa, cfg[0]);
        defer c.deinit(gpa);
        const vals = try gpa.alloc(f64, c.col_ptr[c.n]);
        defer gpa.free(vals);
        const rhs = try gpa.alloc(f64, c.n);
        defer gpa.free(rhs);
        var lu = try SparseLu.init(gpa, c.n, c.col_ptr, c.q);
        defer lu.deinit(gpa);
        values(c, true, r, vals);
        lu.runs_on = true;
        try lu.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
        var tb = try K.build(gpa, &lu, c.col_ptr, 1e-12, .{ .tail = 0, .runs = true });
        // One supernode: every column's U list is one run.
        try testing.expect(tb.tab.levers & K.lever_runs != 0);
        defer tb.deinit(gpa);
        var widest: u32 = 0;
        for (0..c.n) |k| widest = @max(widest, tb.idx[tb.tab.coff + k + 1] - tb.idx[tb.tab.coff + k]);
        try testing.expectEqual(@as(u32, cfg[0]), widest);
        for ([_]?u32{ null, 0 }) |tail| {
            values(c, true, r, vals);
            for (rhs) |*x| x.* = r.float(f64) - 0.5;
            try testing.expect(try expectLevers(gpa, cfg[1], &lu, c, tail, vals, rhs, &stamp));
        }
    }
}

test "lu levers: lever-off tables are today's and g7's levels certify their panels" {
    // Oracle: `idx` without levers is a prefix of `idx` with them (g2 adds
    // nothing); and the definition of an in-panel level: every in-panel
    // entry of a row names a row of a strictly lower level of its panel,
    // every entry before `tl_in`/`tu_in` lies outside the panel.
    const gpa = testing.allocator;
    var c = try circuit(gpa, 300, 0x11C1);
    defer c.deinit(gpa);
    const vals = try gpa.alloc(f64, c.col_ptr[c.n]);
    defer gpa.free(vals);
    var rng = std.Random.DefaultPrng.init(0x11C2);
    values(c, false, rng.random(), vals);
    var lu = try SparseLu.init(gpa, c.n, c.col_ptr, c.q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
    var off = try K.build(gpa, &lu, c.col_ptr, 1e-12, .{ .tail = 0 });
    defer off.deinit(gpa);
    var on2 = try K.build(gpa, &lu, c.col_ptr, 1e-12, .{ .tail = 0, .g2 = true });
    defer on2.deinit(gpa);
    var on = try K.build(gpa, &lu, c.col_ptr, 1e-12, .{ .tail = 0, .g7 = true });
    defer on.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), off.tab.levers);
    try testing.expectEqual(K.lever_g2, on2.tab.levers);
    try testing.expectEqual(K.lever_g7, on.tab.levers);
    try testing.expectEqualSlices(u32, off.idx, on2.idx);
    try testing.expectEqualSlices(u32, off.idx, on.idx[0..off.idx.len]);

    const t = on.tab;
    const x = on.idx;
    const tn = t.n - t.t0;
    const np = t.panels();
    try testing.expect(np > 1);
    var short = false;
    for (0..np) |p| {
        const r0: u32 = @intCast(p * K.panel);
        const r1 = @min(r0 + K.panel, tn);
        const nlf = x[t.t_nlv + p];
        const nlb = x[t.t_nlv + np + p];
        try testing.expect(nlf >= 1 and nlf <= r1 - r0 and nlb >= 1 and nlb <= r1 - r0);
        short = short or nlf < r1 - r0;
        for (r0..r1) |i| {
            const lvf = x[t.tl_lv + i];
            const lvb = x[t.tu_lv + i];
            try testing.expect(lvf < nlf and lvb < nlb);
            for (x[t.tl_ptr + i]..x[t.tl_ptr + i + 1]) |e| {
                const col = x[t.tl_col + e];
                if (e < x[t.tl_in + i]) {
                    try testing.expect(col < r0);
                } else {
                    try testing.expect(col >= r0 and col < i);
                    try testing.expect(x[t.tl_lv + col] < lvf);
                }
            }
            for (x[t.tu_ptr + i]..x[t.tu_ptr + i + 1]) |e| {
                const col = x[t.tu_col + e];
                if (e < x[t.tu_in + i]) {
                    try testing.expect(col >= r1);
                } else {
                    try testing.expect(col > i and col < r1);
                    try testing.expect(x[t.tu_lv + col] < lvb);
                }
            }
        }
    }
    // Some panel sweeps in fewer steps than rows: the lever has work to do.
    try testing.expect(short);
}

test "lu levers: build with g7 releases storage on every allocation failure" {
    const gpa = testing.allocator;
    var c = try circuit(gpa, 120, 0x11C3);
    defer c.deinit(gpa);
    const vals = try gpa.alloc(f64, c.col_ptr[c.n]);
    defer gpa.free(vals);
    var rng = std.Random.DefaultPrng.init(0x11C4);
    values(c, false, rng.random(), vals);
    var lu = try SparseLu.init(gpa, c.n, c.col_ptr, c.q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
    try testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, struct {
        fn run(a: std.mem.Allocator, f: *const SparseLu, cp: []const u32) !void {
            var tb = try K.build(a, f, cp, 1e-12, .{ .tail = f.n - 16, .g2 = true, .g7 = true });
            tb.deinit(a);
        }
    }.run, .{ &lu, c.col_ptr });
}

test "lu levers: runs are bitwise across broken runs, the run_min boundary and a growth failure" {
    // Oracle: SparseLu.refactorColumns + solve, and the lever-off run, both
    // bitwise, on 1 and 4 threads, in-`val` columns and 2 x 4 lane threads.
    const gpa = testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xC1C2);
    const r = rng.random();
    var stamp: u32 = 0;
    var failed: u32 = 0;

    // A dense block of run_min + 1 steps beside a chain past the tape: the
    // block's last column takes one run of exactly run_min steps, the one
    // before it run_min - 1 steps one at a time.
    {
        const nb = lu_runs.run_min + 1;
        const n: u32 = nb + 3000;
        var cp: std.ArrayList(u32) = .empty;
        defer cp.deinit(gpa);
        var ri: std.ArrayList(u32) = .empty;
        defer ri.deinit(gpa);
        var vl: std.ArrayList(f64) = .empty;
        defer vl.deinit(gpa);
        for (0..n) |j| {
            try cp.append(gpa, @intCast(ri.items.len));
            const lo: usize = if (j < nb) 0 else @max(j, nb + 1) - 1;
            const hi: usize = if (j < nb) nb else @min(j + 2, n);
            for (lo..hi) |i| {
                try ri.append(gpa, @intCast(i));
                try vl.append(gpa, if (i == j) 10 else r.float(f64) - 0.5);
            }
        }
        try cp.append(gpa, @intCast(ri.items.len));
        const q = try gpa.alloc(u32, n);
        defer gpa.free(q);
        for (q, 0..) |*o, j| o.* = @intCast(j);
        const c: Case = .{ .n = n, .col_ptr = cp.items, .row_idx = ri.items, .q = q };
        var probe = try SparseLu.init(gpa, n, c.col_ptr, c.q);
        defer probe.deinit(gpa);
        probe.runs_on = true;
        try probe.factor(gpa, c.col_ptr, c.row_idx, vl.items, 1e-3);
        try testing.expectEqual(@as(usize, 1), probe.runs.run_len.items.len);
        try testing.expectEqual(@as(u32, lu_runs.run_min), probe.runs.run_len.items[0]);
        try testing.expect(singlePanelSteps(&probe) >= lu_runs.run_min - 1);
        failed += try checkRuns(gpa, c, vl.items, r, &stamp);
    }

    // Random dense-ish systems in shuffled orders (lu_runs' own test
    // input): supernodes where the fill closes, runs broken by the stored
    // order elsewhere.
    var broken: u32 = 0;
    var with_runs: u32 = 0;
    for (0..8) |_| {
        const n: u32 = r.intRangeAtMost(u32, 48, 64);
        const sys = try SparseLu.test_access.TestSystem.init(gpa, r, n, 0.3 + 0.4 * r.float(f64));
        defer sys.deinit(gpa);
        const q = try gpa.alloc(u32, n);
        defer gpa.free(q);
        for (q, 0..) |*o, i| o.* = @intCast(i);
        r.shuffle(u32, q);
        var probe = try SparseLu.init(gpa, n, sys.col_ptr, q);
        defer probe.deinit(gpa);
        probe.runs_on = true;
        // A singular draw or a taped factor has nothing to compare.
        probe.factor(gpa, sys.col_ptr, sys.row_idx, sys.vals, 1e-3) catch continue;
        if (probe.runs.run_ptr.items.len == 0) continue;
        with_runs += 1;
        broken += singlePanelSteps(&probe);
        const c: Case = .{ .n = n, .col_ptr = sys.col_ptr, .row_idx = sys.row_idx, .q = q };
        failed += try checkRuns(gpa, c, sys.vals, r, &stamp);
    }
    try testing.expect(with_runs > 0 and broken > 0);
    try testing.expect(failed > 0);
}

test {
    _ = @import("lu_chunks.zig");
    _ = @import("lu_tile_tests.zig");
}
