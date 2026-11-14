//! Lever C8: reorder on pivot drift, kept only when it wins. A full
//! factor whose threshold pivots left the diagonal fills for a column order
//! chosen for the diagonal. When its fill passes `drift_bound` times the
//! diagonal fill, order the matrix again with the chosen pivots moved onto
//! its diagonal (rule `drift`). When the pivots of a later full factor have
//! come back toward the diagonal, try the original order again (rule
//! `back`), and once after the owner adopts an order its query's
//! dependency kept (rule `reset`: a reset owner starts on that order). Each trial factors once preferring the current pivots
//! and is kept only when the judge (`Shape.cost`: work over
//! `judge_lanes` plus the span of the column DAG, the way the threaded
//! refactor runs it) prices it lower; otherwise the order before it is
//! factored again preferring the same pivots. Tolerance class: a new
//! elimination order changes the factor's rounding.
//! In: a factored `SparseLu`, its owner's column order (rewritten in
//! place), the pattern and values. Out: the same `SparseLu` on the order
//! that won.
//! Cites: docs/perf_research/04-levers-cpu.md ("C8", change 1);
//! 06-open-issues.md finding 13; static pivoting before ordering as in
//! SuperLU_DIST (Li and Demmel, ACM TOMS 29(2), 2003).
//!
//! Contents:
//! - `pub const drift_bound = 1.3`
//! - `pub const reorder_max = 4`
//! - `pub const trial_cap = 2`
//! - `pub const judge_lanes = lu_runs_census.census_lanes`
//! - `pub const Rule = enum { drift, back, reset }`
//! - `pub const Decision = struct`
//! - `pub const Shape = struct`
//!   - `pub fn cost(s: Shape) u64`
//! - `pub const State = struct`
//!   - `pub fn deinit(self: *State, gpa: Allocator) void`
//!   - `pub fn onReset(self: *State, q: []u32) void`
//!   - `pub fn kept(self: *const State, q: []const u32) ?[]const u32`
//!   - `pub fn adopt(self: *State, gpa: Allocator, q: []u32, kept_q: []const u32) Allocator.Error!void`
//! - `pub fn decide(st: *State, lu: *SparseLu, gpa: Allocator, q: []u32, col_ptr: []const u32, row_idx: []const u32, vals: []const f64, pivot_tol: f64) SparseLu.FactorError!?Decision`
//! - `pub fn shape(lu: *const SparseLu, gpa: Allocator) Allocator.Error!Shape`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sparse_lu = @import("sparse_lu.zig");
const SparseLu = sparse_lu.SparseLu;
const order = @import("order.zig");
const lu_factor = @import("lu_factor.zig");
const lu_runs = @import("lu_runs.zig");
const lu_runs_census = @import("lu_runs_census.zig");
const testing = std.testing;
const Shuffled = @import("lu_reorder_tests.zig").Shuffled;

/// A full factor with more than this many times `SparseLu.diag_fill` L plus
/// U entries is reordered. ponytail: provisional; fit it on
/// logic_bsim4_10k's 20 operating-point pivot epochs (C8 step 2).
pub const drift_bound = 1.3;

/// Losing `drift` and `back` trials one `State` makes before those two
/// rules stop. Only losses count: a loss costs two factors and buys
/// nothing, while a win lowers every replay of its pivot epoch, and pivot
/// epochs differ widely (chain_bsim4_10k's operating point: 14 full
/// factors whose pairs swing 1x to 36x with 0.1 to 3% of the pivots off
/// the diagonal, at about 140 ms per factor against 1.4 ms per refactor).
/// Counted from the owner's start or last reset, so a pattern that loses
/// keeps losing nothing more. Trials are at most one per full factor in
/// any case. ponytail: provisional; fit it on the `lu-c8` lines.
pub const reorder_max = 4;

/// A trial factor stops past this many times the L plus U entries of the
/// factor it would replace and counts as a loss. Bounds a hopeless
/// trial's cost; pairs, not entries, decide every other case.
pub const trial_cap = 2;

/// The nominal lane count the judge prices a factor for, never the run's
/// actual one, so 1 lane and N lanes decide alike. The cost model is the
/// subtree refactor's: lanes share the work, the dependency chain does
/// not. If N1 puts the dense tail on every lane, the tail's share of the
/// span shrinks by its lane count and `Shape.cost` changes with it.
pub const judge_lanes = lu_runs_census.census_lanes;

/// What started a trial: the current pivots drifted off the diagonal
/// (`drift`), came back toward it after a reorder (`back`), or the owner
/// adopted an order (`reset`, the original order tried against it on the
/// first full factor after the adoption).
pub const Rule = enum { drift, back, reset };

/// One trial: its rule, and whether its order won (`q` holds the trial
/// order: the new one for `drift`, the original for `back` and `reset`)
/// or lost (`q` holds the order before it).
pub const Decision = struct {
    rule: Rule,
    kept: bool,
};

/// What the judge reads of one factor. Steps form a DAG: column k's
/// replay needs every step i in U[:, k]; its work is the sum of those
/// steps' L column lengths.
pub const Shape = struct {
    /// Multiply-subtract pairs of one refactor: the work.
    pairs: u64,
    /// The heaviest path through the DAG, weighted by each column's work.
    span: u64,
    /// The longest path in columns (printed, not judged).
    levels: u32,
    /// Columns of the last supernode chain (printed, not judged).
    last_sn: u32,

    /// Work shared over `judge_lanes` plus the span no lane can share.
    pub fn cost(s: Shape) u64 {
        assert(s.span <= s.pairs);
        return s.pairs / judge_lanes + s.span;
    }
};

/// The reorder history of one owner's column order. Starts empty; the
/// owner frees it with `deinit`, calls `onReset` when it resets and
/// `adopt` to start on another owner's kept order.
pub const State = struct {
    /// The order before the first reorder; empty until then.
    q_orig: []u32 = &.{},
    /// Columns pivoted off their own row when the last trial ran: a `back`
    /// trial needs fewer than half of them.
    off_at: u32 = 0,
    /// Losing `drift` and `back` trials since the start or the last reset,
    /// at most `reorder_max`.
    reorders: u8 = 0,
    /// An order was adopted since the last full factor: the next one runs
    /// the `reset` trial when `q` is not `q_orig`.
    fresh: bool = false,

    /// Frees `q_orig`.
    pub fn deinit(self: *State, gpa: Allocator) void {
        assert(self.reorders <= reorder_max);
        gpa.free(self.q_orig);
    }

    /// Writes the original order back into `q` and forgets the history,
    /// keeping `q_orig`'s storage: the next factor is a fresh owner's, so
    /// a pooled owner carries nothing from one query to the next. A kept
    /// order travels with the query instead (`adopt`).
    pub fn onReset(self: *State, q: []u32) void {
        assert(self.reorders <= reorder_max);
        assert(self.q_orig.len == 0 or self.q_orig.len == q.len);
        // Lever off: one test, no store.
        if (self.q_orig.len == 0) return;
        @memcpy(q, self.q_orig);
        self.off_at = 0;
        self.reorders = 0;
        self.fresh = false;
    }

    /// `q` when it is not the original order (a reorder was kept), else
    /// null; null with the lever off, after one length test.
    pub fn kept(self: *const State, q: []const u32) ?[]const u32 {
        assert(self.reorders <= reorder_max);
        if (self.q_orig.len == 0) return null;
        assert(q.len == self.q_orig.len);
        return if (std.mem.eql(u32, q, self.q_orig)) null else q;
    }

    /// Starts a fresh or just-reset owner (`q` its original order) on
    /// `kept_q`, the order a dependency's owner kept, and arms one `reset`
    /// trial of the original order against it on the next full factor;
    /// the original wins ties. A no-op, allocating nothing, when `kept_q`
    /// is `q`. OutOfMemory leaves `q` and the state as they were.
    pub fn adopt(self: *State, gpa: Allocator, q: []u32, kept_q: []const u32) Allocator.Error!void {
        assert(kept_q.len == q.len);
        assert(self.q_orig.len == 0 or std.mem.eql(u32, q, self.q_orig));
        if (std.mem.eql(u32, kept_q, q)) return;
        if (self.q_orig.len == 0) self.q_orig = try gpa.dupe(u32, q);
        @memcpy(q, kept_q);
        self.fresh = true;
    }
};

/// Runs at most one trial after a full factor of `lu` on `q` (the slice
/// `lu.q` borrows): `reset` on the first full factor after `adopt` when
/// `q` is not the original order, else `back` when `q` was reordered and fewer than half the
/// columns pivoted off their row at the last trial still do, else `drift`
/// when the fill passed `drift_bound * diag_fill`; neither once
/// `reorder_max` trials have lost. A trial costs one factor, plus one more
/// when it loses. Bound: one trial per full factor; `reorder_max` losing
/// `drift` and `back` trials per `State`; between two drift trials at most
/// floor(log2 n) + 1 back trials, since each halves `off_at`; one reset
/// trial per `adopt`. Every input is a matrix the run factored, so 1 lane and N
/// lanes decide alike. Prints one line per trial when `lu.stats`.
/// Null, `lu` untouched, when no rule fires, the ordering runs out of
/// workspace, or the drift order comes out the same. OutOfMemory leaves
/// `q` as it was; the caller treats `lu` as unfactored, as after a failed
/// `factor`. Asserts that `lu` is factored on `q`.
pub fn decide(
    st: *State,
    lu: *SparseLu,
    gpa: Allocator,
    q: []u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    vals: []const f64,
    pivot_tol: f64,
) SparseLu.FactorError!?Decision {
    assert(lu.factored);
    assert(q.len == lu.n and q.ptr == lu.q.ptr);
    assert(st.reorders <= reorder_max);
    const n = lu.n;
    if (st.fresh) {
        st.fresh = false;
        if (!std.mem.eql(u32, q, st.q_orig))
            return .{ .rule = .reset, .kept = try trial(lu, gpa, q, st.q_orig, .reset, col_ptr, row_idx, vals, pivot_tol) };
    }
    const off = offDiagonal(lu);
    if (st.reorders == reorder_max) return null;
    if (st.q_orig.len != 0 and 2 * @as(u64, off) < st.off_at and !std.mem.eql(u32, q, st.q_orig)) {
        st.off_at = off;
        return tally(st, .{ .rule = .back, .kept = try trial(lu, gpa, q, st.q_orig, .back, col_ptr, row_idx, vals, pivot_tol) });
    }
    if (lu.diag_fill == 0) return null;
    const fill = lu.li.items.len + lu.ui.items.len;
    if (@as(f64, @floatFromInt(fill)) <= drift_bound * @as(f64, @floatFromInt(lu.diag_fill))) return null;
    const nnz: usize = col_ptr[n];
    const nb_max = nnz + n;
    const ws_len = order.wsSize(n, nb_max);
    // One slab: B's column pointers and rows, the new order, and the
    // ordering's workspace.
    const slab = try gpa.alloc(u32, (@as(usize, n) + 1) + nb_max + n + ws_len);
    defer gpa.free(slab);
    const bp = slab[0 .. n + 1];
    const bi = slab[n + 1 ..][0..nb_max];
    const q_new = slab[n + 1 + nb_max ..][0..n];
    var ws = order.Ws.init(slab[2 * n + 1 + nb_max ..][0..ws_len]);

    // B[q[prow[p]]][c] for each A entry p in column c: prow[p] is its row's
    // pivot step, q of that step the column the row pivots. Plus the
    // diagonal when the pivot came from fill.
    var nb: u32 = 0;
    for (0..n) |c| {
        bp[c] = nb;
        var diag = false;
        for (col_ptr[c]..col_ptr[c + 1]) |p| {
            const r = q[lu.prow[p]];
            diag = diag or r == c;
            bi[nb] = r;
            nb += 1;
        }
        if (!diag) {
            bi[nb] = @intCast(c);
            nb += 1;
        }
    }
    bp[n] = nb;
    assert(nb <= nb_max);
    order.order(n, bp, bi[0..nb], q_new, &ws) catch return null;
    if (std.mem.eql(u32, q_new, q)) return null;
    if (st.q_orig.len == 0) st.q_orig = try gpa.dupe(u32, q);
    st.off_at = off;
    return tally(st, .{ .rule = .drift, .kept = try trial(lu, gpa, q, q_new, .drift, col_ptr, row_idx, vals, pivot_tol) });
}

/// The judge's view of `lu`'s factor. O(nnz(L + U)), two scratch
/// allocations. Asserts that `lu` is factored with n > 0.
pub fn shape(lu: *const SparseLu, gpa: Allocator) Allocator.Error!Shape {
    assert(lu.factored);
    assert(lu.n > 0);
    const n = lu.n;
    const work = try gpa.alloc(u64, n);
    defer gpa.free(work);
    const scratch = try gpa.alloc(u32, 3 * @as(usize, n));
    defer gpa.free(scratch);
    var s = spanOf(lu.lp, lu.up, lu.ui.items, work, scratch[0..n]);
    const sn = scratch[n .. 2 * n];
    lu_runs.chainHeads(lu, scratch[2 * n ..], sn);
    var first = n - 1;
    while (first > 0 and sn[first - 1] == sn[n - 1]) first -= 1;
    s.last_sn = n - first;
    return s;
}

// ---- private ----

/// Counts a losing `drift` or `back` trial against `reorder_max`.
fn tally(st: *State, d: Decision) Decision {
    assert(d.rule != .reset);
    assert(st.reorders < reorder_max);
    st.reorders += @intFromBool(!d.kept);
    return d;
}

/// Columns of `lu`'s factor pivoted off their own row.
fn offDiagonal(lu: *const SparseLu) u32 {
    assert(lu.factored);
    assert(lu.pinv.len == lu.n);
    var off: u32 = 0;
    for (lu.pinv, 0..) |step, r| off += @intFromBool(lu.q[step] != r);
    return off;
}

/// Factors on `q_try` preferring `lu`'s current pivots and keeps it when
/// the judge prices it lower (no higher, for `back` and `reset`: the
/// original order wins a tie);
/// otherwise writes the old order back and factors it again preferring the
/// same pivots. Returns whether `q_try` was kept.
fn trial(
    lu: *SparseLu,
    gpa: Allocator,
    q: []u32,
    q_try: []const u32,
    rule: Rule,
    col_ptr: []const u32,
    row_idx: []const u32,
    vals: []const f64,
    pivot_tol: f64,
) SparseLu.FactorError!bool {
    assert(lu.factored);
    assert(q_try.len == q.len and !std.mem.eql(u32, q_try, q));
    const fill = lu.li.items.len + lu.ui.items.len;
    const old = try shape(lu, gpa);
    const q_old = try gpa.dupe(u32, q);
    defer gpa.free(q_old);
    // prev[c]: the row column c pivoted on; independent of the order.
    for (lu.pinv, 0..) |step, r| lu.prev[q[step]] = @intCast(r);
    @memcpy(q, q_try);
    errdefer @memcpy(q, q_old);
    try lu_factor.holdScratch(lu, gpa);
    defer lu_factor.dropScratch(lu, gpa);
    lu.want_prev = true;
    defer lu.want_prev = false;
    const over = lu_factor.factorPass(lu, gpa, col_ptr, row_idx, vals, pivot_tol, trial_cap * fill, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SingularMatrix => true,
    };
    const fill_try = if (over) 0 else lu.li.items.len + lu.ui.items.len;
    const new: Shape = if (over) .{ .pairs = 0, .span = 0, .levels = 0, .last_sn = 0 } else try shape(lu, gpa);
    const kept = !over and (new.cost() < old.cost() or (rule != .drift and new.cost() == old.cost()));
    if (!kept) {
        @memcpy(q, q_old);
        const capped = try lu_factor.factorPass(lu, gpa, col_ptr, row_idx, vals, pivot_tol, std.math.maxInt(usize), false);
        assert(!capped);
    }
    if (lu.runs_on) lu_runs.build(lu, gpa) catch |err| {
        lu.factored = false;
        return err;
    };
    // `over` prints 0 for the trial: it stopped past `trial_cap * fill`.
    if (lu.stats) std.debug.print("lu-c8: rule={s} entries={d}->{d} pairs={d}->{d} span={d}->{d} levels={d}->{d} last_sn={d}->{d} cost={d}->{d} lanes={d} {s}\n", .{
        @tagName(rule),                   fill,       fill_try,    old.pairs,   new.pairs,  old.span,   new.span,
        old.levels,                       new.levels, old.last_sn, new.last_sn, old.cost(), new.cost(), judge_lanes,
        if (kept) "kept" else "restored",
    });
    assert(lu.factored);
    return kept;
}

/// Pairs, span and levels of the factor with column pointers `lp` (L) and
/// `up`, `ui` (U, steps): path[k] is the heaviest work path ending at
/// column k, depth[k] the longest in columns, left in the scratch. Sources are earlier
/// steps (i < k), so one ascending pass is a topological order.
fn spanOf(lp: []const u32, up: []const u32, ui: []const u32, path: []u64, depth: []u32) Shape {
    const n = path.len;
    assert(lp.len == n + 1 and up.len == n + 1 and depth.len == n);
    assert(ui.len == up[n]);
    var s: Shape = .{ .pairs = 0, .span = 0, .levels = 0, .last_sn = 0 };
    for (0..n) |k| {
        var own: u64 = 0;
        var before: u64 = 0;
        var lvl: u32 = 0;
        for (ui[up[k]..up[k + 1]]) |i| {
            own += lp[i + 1] - lp[i];
            if (i >= k) continue;
            before = @max(before, path[i]);
            lvl = @max(lvl, depth[i]);
        }
        s.pairs += own;
        path[k] = before + own;
        depth[k] = lvl + 1;
        s.span = @max(s.span, path[k]);
        s.levels = @max(s.levels, depth[k]);
    }
    return s;
}

/// ||A x - b|| / (||A|| ||x|| n eps), max norms, A in CSC.
fn scaledResidual(col_ptr: []const u32, row_idx: []const u32, vals: []const f64, x: []const f64, b: []const f64, r: []f64) f64 {
    assert(r.len == b.len and x.len == b.len);
    @memcpy(r, b);
    var amax: f64 = 0;
    for (0..x.len) |j| for (col_ptr[j]..col_ptr[j + 1]) |p| {
        r[row_idx[p]] -= vals[p] * x[j];
        amax = @max(amax, @abs(vals[p]));
    };
    var rmax: f64 = 0;
    var xmax: f64 = 0;
    for (r, x) |ri, xi| {
        rmax = @max(rmax, @abs(ri));
        xmax = @max(xmax, @abs(xi));
    }
    const nf: f64 = @floatFromInt(x.len);
    return rmax / (nf * amax * xmax * nf * std.math.floatEps(f64));
}

test "C8 reorder: pivots off the diagonal reorder to fewer pairs, kept, and solve within the residual bound" {
    // Oracle: the pairs of the factor the reorder replaces (the keep must
    // lower them), the scaled LU residual of each factor, and the
    // lever-off solve, which the reordered one must match within the
    // forward error that residual allows (T is diagonally dominant:
    // condition below 3).
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc8);
    const rnd = prng.random();
    const n: u32 = 400;
    for ([_]bool{ true, false }) |shuffle| {
        const a = try Shuffled.init(gpa, rnd, n, shuffle);
        defer a.deinit(gpa, n);
        const ws_buf = try gpa.alloc(u32, order.wsSize(n, a.col_ptr[n]));
        defer gpa.free(ws_buf);
        var ws = order.Ws.init(ws_buf);
        const q_off = try gpa.alloc(u32, n);
        defer gpa.free(q_off);
        try order.order(n, a.col_ptr, a.row_idx, q_off, &ws);
        // The trigger is the test's: nnz(A) as the diagonal fill. The
        // shuffled factor fills far past 1.3x it, the tridiagonal one (no
        // fill under its natural order) stays under.
        const diag_fill: u64 = a.col_ptr[n];
        const q_on = try gpa.dupe(u32, q_off);
        defer gpa.free(q_on);

        var off = try SparseLu.init(gpa, n, a.col_ptr, q_off);
        defer off.deinit(gpa);
        var on = try SparseLu.init(gpa, n, a.col_ptr, q_on);
        defer on.deinit(gpa);
        off.diag_fill = diag_fill;
        on.diag_fill = diag_fill;
        try off.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
        try on.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
        var st: State = .{};
        defer st.deinit(gpa);
        const before = try shape(&on, gpa);
        const got = try decide(&st, &on, gpa, q_on, a.col_ptr, a.row_idx, a.vals, 1e-3);
        // The unshuffled T pivots on the diagonal: no drift, nothing moves.
        if (shuffle) {
            try testing.expectEqual(Decision{ .rule = .drift, .kept = true }, got.?);
            try testing.expect((try shape(&on, gpa)).pairs < before.pairs);
            try testing.expect(!std.mem.eql(u32, q_off, q_on));
        } else {
            try testing.expect(got == null);
            try testing.expectEqualSlices(u32, q_off, q_on);
        }

        const buf = try gpa.alloc(f64, 4 * @as(usize, n));
        defer gpa.free(buf);
        const b = buf[0..n];
        const x_off = buf[n .. 2 * n];
        const x_on = buf[2 * n .. 3 * n];
        const r = buf[3 * n ..];
        for (b) |*v| v.* = 2 * rnd.float(f64) - 1;
        // The factor, then a replay of new values on the new order.
        for (0..2) |round| {
            if (round == 1) {
                for (a.vals) |*v| v.* *= 0.9 + 0.2 * rnd.float(f64);
                try off.refactor(a.col_ptr, a.vals, 1e-12);
                try on.refactor(a.col_ptr, a.vals, 1e-12);
            }
            off.solve(b, x_off);
            on.solve(b, x_on);
            const res_off = scaledResidual(a.col_ptr, a.row_idx, a.vals, x_off, b, r);
            const res_on = scaledResidual(a.col_ptr, a.row_idx, a.vals, x_on, b, r);
            try testing.expect(res_off <= 30 and res_on <= 30);
            // |x_on - x_off| <= cond * (res_on + res_off) * n * eps * |x|.
            const xmax = std.mem.max(f64, x_off);
            const xmin = std.mem.min(f64, x_off);
            const scale = @max(xmax, -xmin);
            const nf: f64 = @floatFromInt(n);
            const tol = 3 * (res_on + res_off + 1) * nf * nf * std.math.floatEps(f64) * scale;
            for (x_on, x_off) |u, v| try testing.expect(@abs(u - v) <= tol);
        }
    }
}

test "C8 reorder: pivots back on the diagonal restore the original order, bitwise the lever-off factor from there on" {
    // Oracle: the lever-off LU, factored and refactored on the same values
    // in the original order. Once the back trial restores that order and
    // its pivots (all diagonal), every array of the factor, every
    // refactor and every solve is bitwise the lever-off one.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc82);
    const rnd = prng.random();
    const n: u32 = 400;
    const a = try Shuffled.init(gpa, rnd, n, true);
    defer a.deinit(gpa, n);
    const ws_buf = try gpa.alloc(u32, order.wsSize(n, a.col_ptr[n]));
    defer gpa.free(ws_buf);
    var ws = order.Ws.init(ws_buf);
    const q_off = try gpa.alloc(u32, n);
    defer gpa.free(q_off);
    try order.order(n, a.col_ptr, a.row_idx, q_off, &ws);
    const q_on = try gpa.dupe(u32, q_off);
    defer gpa.free(q_on);
    var off = try SparseLu.init(gpa, n, a.col_ptr, q_off);
    defer off.deinit(gpa);
    var on = try SparseLu.init(gpa, n, a.col_ptr, q_on);
    defer on.deinit(gpa);
    off.diag_fill = a.col_ptr[n];
    on.diag_fill = a.col_ptr[n];
    var st: State = .{};
    defer st.deinit(gpa);

    // Shuffled T: the pivots drift and the reorder is kept.
    try off.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    try on.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    try testing.expectEqual(Decision{ .rule = .drift, .kept = true }, (try decide(&st, &on, gpa, q_on, a.col_ptr, a.row_idx, a.vals, 1e-3)).?);
    try testing.expect(!std.mem.eql(u32, q_off, q_on));

    // A's diagonal set to 100 against at most three other entries of at
    // most 4 per column: column diagonally dominant, so threshold pivoting
    // takes the diagonal under any order and elimination keeps it so.
    for (0..n) |c| for (a.col_ptr[c]..a.col_ptr[c + 1]) |p| {
        if (a.row_idx[p] == c) a.vals[p] = 100;
    };
    try off.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    try on.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    try testing.expectEqual(@as(u32, 0), offDiagonal(&on));
    try testing.expectEqual(Decision{ .rule = .back, .kept = true }, (try decide(&st, &on, gpa, q_on, a.col_ptr, a.row_idx, a.vals, 1e-3)).?);
    try testing.expectEqualSlices(u32, q_off, q_on);
    // No second trial: the order is the original one again.
    try testing.expect(try decide(&st, &on, gpa, q_on, a.col_ptr, a.row_idx, a.vals, 1e-3) == null);

    const buf = try gpa.alloc(f64, 3 * @as(usize, n));
    defer gpa.free(buf);
    const b = buf[0..n];
    const x_off = buf[n .. 2 * n];
    const x_on = buf[2 * n ..];
    for (b) |*v| v.* = 2 * rnd.float(f64) - 1;
    for (0..2) |round| {
        if (round == 1) {
            for (a.vals) |*v| v.* *= 0.9 + 0.2 * rnd.float(f64);
            try off.refactor(a.col_ptr, a.vals, 1e-12);
            try on.refactor(a.col_ptr, a.vals, 1e-12);
        }
        try testing.expectEqualSlices(u32, off.pinv, on.pinv);
        try testing.expectEqualSlices(u32, off.lp, on.lp);
        try testing.expectEqualSlices(u32, off.up, on.up);
        try testing.expectEqualSlices(u32, off.li.items, on.li.items);
        try testing.expectEqualSlices(u32, off.ui.items, on.ui.items);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(off.lx.items), std.mem.sliceAsBytes(on.lx.items));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(off.ux.items), std.mem.sliceAsBytes(on.ux.items));
        off.solve(b, x_off);
        on.solve(b, x_on);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(x_off), std.mem.sliceAsBytes(x_on));
    }
}

test "C8 reorder: an adopted order meets the original in one reset trial and wins on the values it was chosen for" {
    // Oracle: the order A's drift trial kept. B, fresh on the same
    // pattern, adopts it; on the same shuffled values its reset trial pits
    // the original order, which drifts (A's first factor, past 1.3x the
    // trigger), against the order chosen for those pivots, so the adopted
    // order must stay.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc83);
    const n: u32 = 400;
    const a = try Shuffled.init(gpa, prng.random(), n, true);
    defer a.deinit(gpa, n);
    const ws_buf = try gpa.alloc(u32, order.wsSize(n, a.col_ptr[n]));
    defer gpa.free(ws_buf);
    var ws = order.Ws.init(ws_buf);
    const qa = try gpa.alloc(u32, n);
    defer gpa.free(qa);
    try order.order(n, a.col_ptr, a.row_idx, qa, &ws);
    const qb = try gpa.dupe(u32, qa);
    defer gpa.free(qb);
    var lua = try SparseLu.init(gpa, n, a.col_ptr, qa);
    defer lua.deinit(gpa);
    var lub = try SparseLu.init(gpa, n, a.col_ptr, qb);
    defer lub.deinit(gpa);
    lua.diag_fill = a.col_ptr[n];
    lub.diag_fill = a.col_ptr[n];
    var sa: State = .{};
    defer sa.deinit(gpa);
    var sb: State = .{};
    defer sb.deinit(gpa);
    try lua.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    try testing.expectEqual(Decision{ .rule = .drift, .kept = true }, (try decide(&sa, &lua, gpa, qa, a.col_ptr, a.row_idx, a.vals, 1e-3)).?);

    try sb.adopt(gpa, qb, qa);
    try testing.expectEqualSlices(u32, qa, qb);
    try lub.factor(gpa, a.col_ptr, a.row_idx, a.vals, 1e-3);
    try testing.expectEqual(Decision{ .rule = .reset, .kept = false }, (try decide(&sb, &lub, gpa, qb, a.col_ptr, a.row_idx, a.vals, 1e-3)).?);
    try testing.expectEqualSlices(u32, qa, qb);
    // One reset trial per adoption.
    if (try decide(&sb, &lub, gpa, qb, a.col_ptr, a.row_idx, a.vals, 1e-3)) |d| try testing.expect(d.rule != .reset);
}

test "C8 judge: equal pairs, a chain prices above a star" {
    // Oracle: hand counts on two 4-column factors, one L entry per source
    // step, three U entries each. Chain: column k reads step k - 1, so the
    // path is 1 + 1 + 1 = 3 over 4 levels. Star: columns 1..3 read step 0
    // only, path 1 over 2 levels.
    const up = [_]u32{ 0, 0, 1, 2, 3 };
    var path: [4]u64 = undefined;
    var depth: [4]u32 = undefined;
    const chain = spanOf(&.{ 0, 1, 2, 3, 3 }, &up, &.{ 0, 1, 2 }, &path, &depth);
    const star = spanOf(&.{ 0, 1, 1, 1, 1 }, &up, &.{ 0, 0, 0 }, &path, &depth);
    try testing.expectEqual(Shape{ .pairs = 3, .span = 3, .levels = 4, .last_sn = 0 }, chain);
    try testing.expectEqual(Shape{ .pairs = 3, .span = 1, .levels = 2, .last_sn = 0 }, star);
    try testing.expect(star.cost() < chain.cost());
}

test "C8 reorder: releases storage and restores the order on every allocation failure" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc81);
    const n: u32 = 120;
    const a = try Shuffled.init(gpa, prng.random(), n, true);
    defer a.deinit(gpa, n);
    const life = struct {
        fn f(al: Allocator, s: Shuffled) !void {
            const ws_buf = try al.alloc(u32, order.wsSize(n, s.col_ptr[n]));
            defer al.free(ws_buf);
            var ws = order.Ws.init(ws_buf);
            const q = try al.alloc(u32, n);
            defer al.free(q);
            try order.order(n, s.col_ptr, s.row_idx, q, &ws);
            const q0 = try al.dupe(u32, q);
            defer al.free(q0);
            var lu = try SparseLu.init(al, n, s.col_ptr, q);
            defer lu.deinit(al);
            lu.runs_on = true;
            lu.diag_fill = s.col_ptr[n];
            var st: State = .{};
            defer st.deinit(al);
            try lu.factor(al, s.col_ptr, s.row_idx, s.vals, 1e-3);
            _ = decide(&st, &lu, al, q, s.col_ptr, s.row_idx, s.vals, 1e-3) catch |err| {
                try testing.expectEqualSlices(u32, q0, q);
                return err;
            };
        }
    }.f;
    try life(gpa, a);
    try testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, life, .{a});
}
