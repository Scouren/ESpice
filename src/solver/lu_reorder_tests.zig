//! Lever C8's fixture and its owner-level tests: the shuffled tridiagonal
//! matrix the `lu_reorder` tests drift on, and the `direct.Solver` entries
//! (`reset`, `keptOrder`, `adoptOrder`) that keep a kept order with the
//! query instead of the pooled solver. Test code only.
//! In: nothing. Out: test verdicts.
//! Cites: docs/perf_research/04-levers-cpu.md ("C8").
//!
//! Contents:
//! - `pub const Shuffled = struct`
//!   - `pub fn init(gpa: Allocator, rnd: std.Random, n: u32, shuffle: bool) !Shuffled`
//!   - `pub fn deinit(self: Shuffled, gpa: Allocator, n: u32) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const direct = @import("direct.zig");
const order = @import("order.zig");
const SparseLu = @import("sparse_lu.zig").SparseLu;
const testing = std.testing;

/// A = P T: T tridiagonal (4 on the diagonal, off-diagonals in [-1, 1]),
/// its rows shuffled by a random P, plus a structural zero on A's diagonal
/// where T puts none. T is diagonally dominant in columns, so threshold
/// pivoting takes T's diagonal under any column order: off A's diagonal
/// when shuffled, and the order chosen for A's pattern is unrelated to the
/// graph actually eliminated.
pub const Shuffled = struct {
    col_ptr: []u32,
    row_idx: []u32,
    vals: []f64,

    /// Builds A for order n; `shuffle` false leaves P the identity.
    pub fn init(gpa: Allocator, rnd: std.Random, n: u32, shuffle: bool) !Shuffled {
        const perm = try gpa.alloc(u32, n);
        defer gpa.free(perm);
        for (perm, 0..) |*v, i| v.* = @intCast(i);
        if (shuffle) rnd.shuffle(u32, perm);
        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, 4 * @as(usize, n));
        errdefer gpa.free(row_idx);
        const vals = try gpa.alloc(f64, 4 * @as(usize, n));
        var nnz: u32 = 0;
        for (0..n) |c| {
            col_ptr[c] = nnz;
            var diag = false;
            for ([_]i64{ -1, 0, 1 }) |d| {
                const i = @as(i64, @intCast(c)) + d;
                if (i < 0 or i >= n) continue;
                const r = perm[@intCast(i)];
                diag = diag or r == c;
                row_idx[nnz] = r;
                vals[nnz] = if (d == 0) 4 else 2 * rnd.float(f64) - 1;
                nnz += 1;
            }
            if (!diag) {
                row_idx[nnz] = @intCast(c);
                vals[nnz] = 0;
                nnz += 1;
            }
        }
        col_ptr[n] = nnz;
        return .{ .col_ptr = col_ptr, .row_idx = row_idx[0..nnz], .vals = vals[0..nnz] };
    }

    /// Frees what `init` allocated for order n.
    pub fn deinit(self: Shuffled, gpa: Allocator, n: u32) void {
        gpa.free(self.col_ptr);
        gpa.free(self.row_idx.ptr[0 .. 4 * @as(usize, n)]);
        gpa.free(self.vals.ptr[0 .. 4 * @as(usize, n)]);
    }
};

/// Order of every test system here.
const sys_n: u32 = 400;

// ---- private ----

/// A c8 solver on `a`'s pattern (the general LU: the pattern is neither
/// tridiagonal nor BBD) with `trigger` as its drift trigger's diagonal
/// fill; 0 turns the drift rule and the fresh-factor cap off.
fn solverOn(gpa: Allocator, a: Shuffled, trigger: u64) !direct.Solver {
    assert(a.col_ptr.len == sys_n + 1);
    var s = try direct.Solver.init(gpa, sys_n, a.col_ptr, a.row_idx, null, .{ .no_bbd = true, .perf = .{ .c8 = true } });
    errdefer s.deinit();
    s.sparse().?.diag_fill = trigger;
    assert(s.engine == .lu);
    return s;
}

/// Half the L plus U entries `a`'s values reach on its own order under
/// threshold pivoting: a trigger the drifted factor passes 1.3x of while
/// staying under the 3x fresh-factor cap.
fn halfFill(gpa: Allocator, a: Shuffled) !u64 {
    assert(a.col_ptr.len == sys_n + 1);
    const ws_buf = try gpa.alloc(u32, order.wsSize(sys_n, a.col_ptr[sys_n]));
    defer gpa.free(ws_buf);
    var ws = order.Ws.init(ws_buf);
    var q: [sys_n]u32 = undefined;
    try order.order(sys_n, a.col_ptr, a.row_idx, &q, &ws);
    var lu = try SparseLu.init(gpa, sys_n, a.col_ptr, &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    const fill = lu.li.items.len + lu.ui.items.len;
    assert(fill > 0);
    return fill / 2;
}

/// Sets A's diagonal to 100 against at most three other entries of at
/// most 4 per column: column diagonally dominant, so threshold pivoting
/// takes the diagonal under any order.
fn dominate(a: Shuffled) void {
    assert(a.col_ptr.len == sys_n + 1);
    for (0..sys_n) |c| for (a.col_ptr[c]..a.col_ptr[c + 1]) |p| {
        if (a.row_idx[p] == c) a.vals[p] = 100;
    };
}

/// Every factor array and a solve of `x` and `y` are bitwise equal.
fn expectSame(x: *direct.Solver, y: *direct.Solver, rnd: std.Random) !void {
    try testing.expectEqualSlices(u32, y.q, x.q);
    const lx = x.sparse().?;
    const ly = y.sparse().?;
    try testing.expectEqualSlices(u32, ly.pinv, lx.pinv);
    try testing.expectEqualSlices(u32, ly.li.items, lx.li.items);
    try testing.expectEqualSlices(u32, ly.ui.items, lx.ui.items);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ly.lx.items), std.mem.sliceAsBytes(lx.lx.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ly.ux.items), std.mem.sliceAsBytes(lx.ux.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ly.udiag), std.mem.sliceAsBytes(lx.udiag));
    var b: [sys_n]f64 = undefined;
    var sx: [sys_n]f64 = undefined;
    var sy: [sys_n]f64 = undefined;
    for (&b) |*v| v.* = 2 * rnd.float(f64) - 1;
    x.solve(&b, &sx);
    y.solve(&b, &sy);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&sy), std.mem.sliceAsBytes(&sx));
}

test "C8 solver: a reset solver drops its kept order and factors bitwise as a fresh one" {
    // Oracle: a fresh c8 solver on the same values. The reset must leave
    // nothing of A's reorder behind (the pool hands A to any query).
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc84);
    const rnd = prng.random();
    const a = try Shuffled.init(gpa, rnd, sys_n, true);
    defer a.deinit(gpa, sys_n);
    var sa = try solverOn(gpa, a, try halfFill(gpa, a));
    defer sa.deinit();
    try sa.factor(a.vals, .{});
    try testing.expect(sa.keptOrder() != null);
    try sa.reset(null);
    try testing.expect(sa.keptOrder() == null);
    sa.sparse().?.diag_fill = 0;
    var fresh = try solverOn(gpa, a, 0);
    defer fresh.deinit();
    dominate(a);
    try sa.factor(a.vals, .{});
    try fresh.factor(a.vals, .{});
    try expectSame(&sa, &fresh, rnd);
}

test "C8 solver: an adopted order is tried against the original on the first factor, which wins on diagonal pivots" {
    // Oracle: a fresh c8 solver C on the same values. B adopts A's kept
    // order; on diagonally dominant values its reset trial must go back
    // to the original order, preferring the diagonal pivots, which is
    // C's factor bitwise. Drift is off on B and C (trigger 0), so only
    // the armed trial can bring B back.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc85);
    const rnd = prng.random();
    const a = try Shuffled.init(gpa, rnd, sys_n, true);
    defer a.deinit(gpa, sys_n);
    var sa = try solverOn(gpa, a, try halfFill(gpa, a));
    defer sa.deinit();
    try sa.factor(a.vals, .{});
    const kept = sa.keptOrder() orelse return error.TestUnexpectedResult;
    var sb = try solverOn(gpa, a, 0);
    defer sb.deinit();
    var sc = try solverOn(gpa, a, 0);
    defer sc.deinit();
    try sb.adoptOrder(kept);
    try testing.expectEqualSlices(u32, kept, sb.keptOrder().?);
    dominate(a);
    try sb.factor(a.vals, .{});
    try sc.factor(a.vals, .{});
    try testing.expect(sb.keptOrder() == null);
    try expectSame(&sb, &sc, rnd);
}

test "C8 solver: adopting the original order is a no-op" {
    // Oracle: the empty state: no copy of the order, no armed trial.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc86);
    const a = try Shuffled.init(gpa, prng.random(), sys_n, true);
    defer a.deinit(gpa, sys_n);
    var s = try solverOn(gpa, a, 0);
    defer s.deinit();
    const same = try gpa.dupe(u32, s.q);
    defer gpa.free(same);
    try s.adoptOrder(same);
    try testing.expectEqual(@as(usize, 0), s.c8.q_orig.len);
    try testing.expect(!s.c8.fresh);
    try testing.expect(s.keptOrder() == null);
}
