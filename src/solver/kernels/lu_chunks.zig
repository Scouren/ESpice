//! The chunk census of G2 step 4, which decides stage B (destination
//! chunks): per pivot epoch, the destination chunks (a supernode's
//! consecutive columns, `lu_runs.zig`'s chain rule), the critical path H
//! with chunks as nodes against S_r with columns as nodes, the chunk
//! sizes overall and along that path, and the columns whose in-chunk
//! sources come last in stored U order against those that need the
//! per-column fallback. Read-only over the factor's pattern; printed by
//! `lu_tables.build` under `ZP_LU_STATS`, it changes no value.
//! Cites: docs/perf_research/05-levers-gpu.md (G2 step 4);
//! docs/perf_research/10-device-lu-chain.md (M1).
//!
//! Contents:
//! - `pub const Pattern = struct`
//! - `pub const Census = struct`
//!   - `pub fn print(c: Census) void`
//! - `pub fn census(ar: std.mem.Allocator, p: Pattern) !Census`

const std = @import("std");
const assert = std.debug.assert;

/// A factor's L and U pattern, as `SparseLu` stores it: column k's L rows
/// `li[lp[k]..lp[k + 1]]` (below the pivot), its U steps
/// `ui[up[k]..up[k + 1]]` in stored order.
pub const Pattern = struct {
    lp: []const u32,
    li: []const u32,
    up: []const u32,
    ui: []const u32,
    void_col: []const bool,
};

/// One epoch's census. A bucket b of `size_log2`/`path_log2` counts the
/// chunks of floor(log2(size)) == b.
pub const Census = struct {
    chunks: u32 = 0,
    /// Chunks on the longest chain of chunk hand-offs (nodes, not edges).
    h: u32 = 0,
    /// Columns on the longest chain of column hand-offs: today's chain.
    s_r: u32 = 0,
    size_log2: [32]u32 = @splat(0),
    path_log2: [32]u32 = @splat(0),
    /// Columns whose in-chunk sources are a suffix of their U list, and
    /// those that are not; with the flops (pairs) of each.
    cols_last: u32 = 0,
    cols_fallback: u32 = 0,
    flops_last: u64 = 0,
    flops_fallback: u64 = 0,

    /// Prints the census as `lu-chunks:` lines.
    pub fn print(c: Census) void {
        assert(c.h <= c.chunks);
        assert(c.chunks <= c.cols_last + c.cols_fallback);
        std.debug.print("lu-chunks: chunks={d} H={d} S_r={d} cols_last={d} cols_fallback={d} F_last={d} F_fallback={d}\n", .{ c.chunks, c.h, c.s_r, c.cols_last, c.cols_fallback, c.flops_last, c.flops_fallback });
        for (c.size_log2, c.path_log2, 0..) |all, path, b| if (all != 0)
            std.debug.print("lu-chunks: size {d}..{d}: {d} chunks, {d} on the path\n", .{ @as(u64, 1) << @intCast(b), (@as(u64, 2) << @intCast(b)) - 1, all, path });
    }
};

const none: u32 = std.math.maxInt(u32);

/// The census of pattern `p`, O(nnz(L + U)), scratch from `ar`.
pub fn census(ar: std.mem.Allocator, p: Pattern) !Census {
    const n: u32 = @intCast(p.lp.len - 1);
    assert(p.up.len == p.lp.len);
    assert(p.void_col.len == n);
    var c: Census = .{};
    if (n == 0) return c;
    // Chunk ids per column; chunk heads ascend with their ids.
    const ck = try ar.alloc(u32, n);
    const head = try ar.alloc(u32, n);
    const mark = try ar.alloc(u32, n);
    @memset(mark, none);
    ck[0] = 0;
    head[0] = 0;
    c.chunks = 1;
    for (1..n) |s| {
        if (!joins(p, mark, @intCast(s - 1))) {
            head[c.chunks] = @intCast(s);
            c.chunks += 1;
        }
        ck[s] = c.chunks - 1;
    }
    // Per chunk: its path length and predecessor; per column: its level.
    const hl = try ar.alloc(u32, c.chunks);
    const pred = try ar.alloc(u32, c.chunks);
    const lv = try ar.alloc(u32, n);
    @memset(hl, 1);
    @memset(pred, none);
    for (0..n) |kk| {
        const k: u32 = @intCast(kk);
        const ch = ck[k];
        lv[k] = 1;
        var in_seen = false;
        var last = true;
        var flops: u64 = 0;
        for (p.ui[p.up[k]..p.up[k + 1]]) |i| {
            assert(i < k);
            lv[k] = @max(lv[k], lv[i] + 1);
            flops += p.lp[i + 1] - p.lp[i];
            if (ck[i] == ch) {
                in_seen = true;
            } else {
                last = last and !in_seen;
                if (hl[ck[i]] + 1 > hl[ch]) {
                    hl[ch] = hl[ck[i]] + 1;
                    pred[ch] = ck[i];
                }
            }
        }
        c.s_r = @max(c.s_r, lv[k]);
        if (last) {
            c.cols_last += 1;
            c.flops_last += flops;
        } else {
            c.cols_fallback += 1;
            c.flops_fallback += flops;
        }
    }
    var end: u32 = 0;
    for (0..c.chunks) |x| {
        const size = (if (x + 1 < c.chunks) head[x + 1] else n) - head[x];
        c.size_log2[std.math.log2_int(u32, size)] += 1;
        if (hl[x] > hl[end]) end = @intCast(x);
    }
    c.h = hl[end];
    var cx = end;
    var guard: u32 = 0;
    while (cx != none) : (cx = pred[cx]) {
        guard += 1;
        assert(guard <= c.h);
        const size = (if (cx + 1 < c.chunks) head[cx + 1] else n) - head[cx];
        c.path_log2[std.math.log2_int(u32, size)] += 1;
    }
    assert(guard == c.h);
    assert(c.cols_last + c.cols_fallback == n);
    return c;
}

// ---- private ----

/// `lu_runs.zig`'s chain rule: step s + 1 joins s's chunk when
/// L[:,s] = {s+1} ∪ L[:,s+1] and neither column is void.
fn joins(p: Pattern, mark: []u32, s: u32) bool {
    assert(s + 1 < p.void_col.len);
    assert(mark.len == p.void_col.len);
    if (p.void_col[s] or p.void_col[s + 1]) return false;
    const a = p.li[p.lp[s]..p.lp[s + 1]];
    const b = p.li[p.lp[s + 1]..p.lp[s + 2]];
    if (a.len != b.len + 1) return false;
    for (b) |r| mark[r] = s;
    for (a) |r| {
        if (r != s + 1 and mark[r] != s) return false;
    }
    return true;
}

test "lu chunks: census of hand-derived patterns" {
    // Oracle: each pattern's chunks, H, S_r and fallback columns derived
    // by hand from the definitions in the header.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const t = std.testing;

    // Diagonal, 4 columns: 4 chunks of 1, no hand-off.
    const diag = try census(ar, .{ .lp = &.{ 0, 0, 0, 0, 0 }, .li = &.{}, .up = &.{ 0, 0, 0, 0, 0 }, .ui = &.{}, .void_col = &.{ false, false, false, false } });
    try t.expectEqual(@as(u32, 4), diag.chunks);
    try t.expectEqual(@as(u32, 1), diag.h);
    try t.expectEqual(@as(u32, 1), diag.s_r);
    try t.expectEqual(@as(u32, 4), diag.size_log2[0]);
    try t.expectEqual(@as(u32, 1), diag.path_log2[0]);
    try t.expectEqual(@as(u32, 4), diag.cols_last);

    // Tridiagonal, 4 columns: L[:,s] = {s+1}, U[k] = {k-1}. Only the last
    // two join ({0},{1},{2,3}); the chain of chunks is 3 long, of columns 4.
    const tri = try census(ar, .{ .lp = &.{ 0, 1, 2, 3, 3 }, .li = &.{ 1, 2, 3 }, .up = &.{ 0, 0, 1, 2, 3 }, .ui = &.{ 0, 1, 2 }, .void_col = &.{ false, false, false, false } });
    try t.expectEqual(@as(u32, 3), tri.chunks);
    try t.expectEqual(@as(u32, 3), tri.h);
    try t.expectEqual(@as(u32, 4), tri.s_r);
    try t.expectEqual(@as(u32, 2), tri.size_log2[0]);
    try t.expectEqual(@as(u32, 1), tri.size_log2[1]);
    try t.expectEqual(@as(u32, 2), tri.path_log2[0]);
    try t.expectEqual(@as(u32, 1), tri.path_log2[1]);
    try t.expectEqual(@as(u32, 4), tri.cols_last);
    try t.expectEqual(@as(u64, 3), tri.flops_last);

    // Chunks {0},{1,2,3}: L[:,1] = {2,3}, L[:,2] = {3}. Column 3 stores
    // U = [1, 0, 2]: in-chunk 1 before external 0, the fallback (flops
    // |L1| + |L0| + |L2| = 3). Columns 1 and 2 store the external 0 first.
    var pat: Pattern = .{ .lp = &.{ 0, 0, 2, 3, 3 }, .li = &.{ 2, 3, 3 }, .up = &.{ 0, 0, 1, 3, 6 }, .ui = &.{ 0, 0, 1, 1, 0, 2 }, .void_col = &.{ false, false, false, false } };
    const fb = try census(ar, pat);
    try t.expectEqual(@as(u32, 2), fb.chunks);
    try t.expectEqual(@as(u32, 2), fb.h);
    try t.expectEqual(@as(u32, 4), fb.s_r);
    try t.expectEqual(@as(u32, 1), fb.size_log2[1]);
    try t.expectEqual(@as(u32, 1), fb.path_log2[1]);
    try t.expectEqual(@as(u32, 3), fb.cols_last);
    try t.expectEqual(@as(u32, 1), fb.cols_fallback);
    try t.expectEqual(@as(u64, 2), fb.flops_last);
    try t.expectEqual(@as(u64, 3), fb.flops_fallback);

    // A void column joins nothing: {0},{1},{2},{3}, column 3 then has no
    // in-chunk source and every column is last.
    pat.void_col = &.{ false, false, true, false };
    const vd = try census(ar, pat);
    try t.expectEqual(@as(u32, 4), vd.chunks);
    try t.expectEqual(@as(u32, 4), vd.h);
    try t.expectEqual(@as(u32, 0), vd.cols_fallback);
}
