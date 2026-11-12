//! The `ZP_LU_STATS` census lines that decide C1 stage 2, N1 and N9: per
//! full factor, how many replay pairs lie in the dense tail, and how many
//! lie in the subtree plan's independent subtrees. Supernode tiles are not
//! counted: an exact tile needs adjacent columns whose U lists agree in
//! stored order, which real factors never had (0.0% on every deck
//! measured, 2026-11), so C1 stage 2 closed on that count. Prints only; changes no value.
//! In: a factored `SparseLu` and its pattern. Out: the `lu-runs:` and
//! `lu-subtree-census:` lines on stderr.
//! Cites: docs/perf_research/04-levers-cpu.md ("C1", step 5);
//! 09-after-the-levers.md ("N1", "N9").
//!
//! Contents:
//! - `pub const tail_orders = [_]u32{ 256, 512, 1024 }`
//! - `pub const census_lanes = 8`
//! - `pub const Counts = struct`
//! - `pub fn count(lu: *const SparseLu, gpa: Allocator, tails: [tail_orders.len]u32) Allocator.Error!Counts`
//! - `pub fn pairsBelow(lu: *const SparseLu, cut: u32) u64`
//! - `pub fn print(lu: *const SparseLu, gpa: Allocator, col_ptr: []const u32) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const SparseLu = @import("sparse_lu.zig").SparseLu;
const lu_runs = @import("lu_runs.zig");
const subtree = @import("subtree.zig");
const testing = std.testing;

/// Orders T of the trailing block [n - T, n) the tail census prices.
pub const tail_orders = [_]u32{ 256, 512, 1024 };

/// Lanes the subtree census plans for: the transient's lane count.
pub const census_lanes = 8;

/// One factor's run census, as raw pair counts (`count`).
pub const Counts = struct {
    /// Pairs: per U entry, its source step's L column length (the
    /// replay's multiply-subtracts).
    pairs: u64,
    /// Pairs inside runs of at least `lu_runs.run_min` steps: C1's
    /// admission share (`lu_runs.share`).
    runs: u64,
    /// Per tail order T: pairs whose source step lies in [n - T, n), and
    /// so whose target column does too.
    tail: [tail_orders.len]u64,
    /// Steps in the last supernode chain.
    last_sn: u32,
};

/// The run census of `lu`'s current factor for the tail orders `tails`.
/// O(nnz(L + U)). Asserts that `lu` is factored
/// with n > 0.
pub fn count(lu: *const SparseLu, gpa: Allocator, tails: [tail_orders.len]u32) Allocator.Error!Counts {
    assert(lu.factored);
    assert(lu.n > 0);
    const n = lu.n;
    const lp = lu.lp;
    const up = lu.up;
    const ui = lu.ui.items;
    const scratch = try gpa.alloc(u32, 2 * @as(usize, n));
    defer gpa.free(scratch);
    const sn = scratch[0..n];
    lu_runs.chainHeads(lu, scratch[n..], sn);

    var c: Counts = .{ .pairs = 0, .runs = lu_runs.share(lu, sn).runs, .tail = @splat(0), .last_sn = 0 };
    for (0..n) |k| for (ui[up[k]..up[k + 1]]) |i| {
        const f: u64 = lp[i + 1] - lp[i];
        c.pairs += f;
        for (tails, &c.tail) |t, *acc| {
            if (i >= n - @min(t, n)) acc.* += f; // i < k: k is in the tail too
        }
    };

    var last_first = n - 1;
    while (last_first > 0 and sn[last_first - 1] == sn[n - 1]) last_first -= 1;
    c.last_sn = n - last_first;
    return c;
}

/// Pairs of the columns below `cut`: the subtree census's numerator.
/// Asserts that `lu` is factored and `cut` <= n.
pub fn pairsBelow(lu: *const SparseLu, cut: u32) u64 {
    assert(lu.factored);
    assert(cut <= lu.n);
    var below: u64 = 0;
    for (0..cut) |k| for (lu.ui.items[lu.up[k]..lu.up[k + 1]]) |i| {
        below += lu.lp[i + 1] - lu.lp[i];
    };
    return below;
}

/// Prints `count` for `tail_orders` as the `lu-runs:` line (shares of
/// all pairs), then `lu-subtree-census:` with `pairsBelow` the cut of the
/// subtree plan for `census_lanes` lanes (admission off), or `declined`
/// when there is none (a tape factor). Asserts that `lu` is factored.
pub fn print(lu: *const SparseLu, gpa: Allocator, col_ptr: []const u32) Allocator.Error!void {
    assert(lu.factored);
    assert(col_ptr.len == @as(usize, lu.n) + 1);
    if (lu.n == 0) return;
    const c = try count(lu, gpa, tail_orders);
    std.debug.print("lu-runs: pairs={d} runs={d:.1}% ({s} at {d:.0}%) tail_T256/512/1024={d:.1}/{d:.1}/{d:.1}% last_sn={d}\n", .{
        c.pairs,                                                                                     pct(c.runs, c.pairs),
        if (lu_runs.Share.admitted(.{ .runs = c.runs, .all = c.pairs })) "admitted" else "declined", 100 * lu_runs.admit_share,
        pct(c.tail[0], c.pairs),                                                                     pct(c.tail[1], c.pairs),
        pct(c.tail[2], c.pairs),                                                                     c.last_sn,
    });
    var plan = (try subtree.Plan.init(gpa, lu, col_ptr, census_lanes, .{ .min_speedup = 0 })) orelse {
        std.debug.print("lu-subtree-census: declined\n", .{});
        return;
    };
    defer plan.deinit(gpa);
    std.debug.print("lu-subtree-census: lanes={d} phases={d} cut={d} in_subtrees={d:.1}% of pairs\n", .{
        plan.width, plan.phases(), plan.cut, pct(pairsBelow(lu, plan.cut), c.pairs),
    });
}

// ---- private ----

fn pct(a: u64, b: u64) f64 {
    return 100 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}

/// The hand-counted factor of the census tests: n = 9, diagonal pivots,
/// identity order, a symmetric pattern of a source block S = {0, 1}, a
/// target block T = {2..7}, both dense and fully coupled, and step 8
/// coupled to T only. Diagonal 20 against off-diagonals 1 keeps every
/// pivot on the diagonal, so L is the structural fill:
///   L[:,0] = {1..7} (7), L[:,1] = {2..7} (6), L[:,t] = {t+1..8} for
///   t = 2..7 (8 - t: 6, 5, 4, 3, 2, 1), L[:,8] = {}.
/// U is its transpose: U[:,1] = {0}, U[:,t] = {0..t-1} for t = 2..7,
/// U[:,8] = {2..7}, each list ascending (each step depends on the one
/// before it, so the topological order is forced).
/// Chains: {0, 1} (L0 = {1} ∪ L1) and {2..8} (L1 has 6 rows, L2 has 6:
/// no join; L[:,t] = {t+1} ∪ L[:,t+1] for t = 2..7).
fn handFactor(gpa: Allocator) !SparseLu {
    const n = 9;
    var col_ptr: [n + 1]u32 = undefined;
    var row_idx: [n * n]u32 = undefined;
    var vals: [n * n]f64 = undefined;
    const block = struct {
        fn of(i: usize) u8 {
            return if (i < 2) 0 else if (i < 8) 1 else 2;
        }
    }.of;
    var nnz: u32 = 0;
    for (0..n) |j| {
        col_ptr[j] = nnz;
        for (0..n) |i| {
            const a = block(i);
            const b = block(j);
            // S-S, S-T, T-T and T-8 couple; S-8 does not.
            const keep = i == j or (a != 2 and b != 2) or (a == 1 and b == 2) or (a == 2 and b == 1);
            if (!keep) continue;
            row_idx[nnz] = @intCast(i);
            vals[nnz] = if (i == j) 20 else 1;
            nnz += 1;
        }
    }
    col_ptr[n] = nnz;
    const q = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    var lu = try SparseLu.init(gpa, n, &col_ptr, &q);
    errdefer lu.deinit(gpa);
    try lu.factor(gpa, &col_ptr, row_idx[0..nnz], vals[0..nnz], 1e-3);
    for (lu.pinv, 0..) |s, r| assert(s == r);
    return lu;
}

test "lu-runs census: tail and chain counts match a hand count" {
    // Oracle: the hand count on `handFactor`'s pattern.
    // pairs: k = 1: 7; k = t in 2..7: 7 + 6 + sum_{i=2}^{t-1} (8 - i) =
    // 13, 19, 24, 28, 31, 33 (148); k = 8: 6+5+4+3+2+1 = 21. Total 176.
    // Tails T = 3, 6, 9: source i >= n - T appears in 8 - i lists with
    // 8 - i pairs each: T = 3 (i = 6, 7): 4 + 1 = 5; T = 6 (i = 3..7):
    // 25 + 16 + 9 + 4 + 1 = 55; T = 9: all 176. Last chain {2..8}: 7.
    // Runs of >= 4 steps (U lists ascending, chains {0, 1} and {2..8}):
    // column 6's steps 2..5 (6 + 5 + 4 + 3 = 18), column 7's 2..6 (20),
    // column 8's 2..7 (21): 59.
    const gpa = testing.allocator;
    var lu = try handFactor(gpa);
    defer lu.deinit(gpa);
    const c = try count(&lu, gpa, .{ 3, 6, 9 });
    try testing.expectEqual(@as(u64, 176), c.pairs);
    try testing.expectEqual(@as(u64, 59), c.runs);
    try testing.expectEqual([tail_orders.len]u64{ 5, 55, 176 }, c.tail);
    try testing.expectEqual(@as(u32, 7), c.last_sn);
}

test "lu-subtree-census: pairs below a cut match a hand count" {
    // Oracle: the hand count of `handFactor` (see the lu-runs test):
    // columns 0, 1 hold 0 + 7 pairs; columns 0..7 hold 7 + 148 = 155; all
    // nine 176.
    const gpa = testing.allocator;
    var lu = try handFactor(gpa);
    defer lu.deinit(gpa);
    try testing.expectEqual(@as(u64, 0), pairsBelow(&lu, 0));
    try testing.expectEqual(@as(u64, 7), pairsBelow(&lu, 2));
    try testing.expectEqual(@as(u64, 155), pairsBelow(&lu, 8));
    try testing.expectEqual(@as(u64, 176), pairsBelow(&lu, 9));
}
