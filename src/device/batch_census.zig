//! N6's census (docs/perf_research/09-after-the-levers.md, "N6 Latency for
//! the charge and limit passes"): per batch, how many instances see their
//! gathered unknowns bitwise unchanged since the previous pass of the same
//! kind. A charge pass is any serial host pass that computes charges (a
//! Newton eval of a charge batch, `eval_q`, `accept_q`), compared with the
//! previous charge pass. A limit pass is counted where `limitRange` reads
//! its inputs: the unknowns `limit` reads, compared with their values at
//! the last accepted point (`accept`). Stats only (`Hooks.census`): a batch
//! without a census pays one null test per call.
//!
//! Contents:
//! - `pub const Census = struct` (`create`, `destroy`, `observe`,
//!   `observeLimit`, `accept`, `counts`)

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("device_abi");
const staging_gpa = @import("proto_store.zig").staging_gpa;

/// One batch's snapshots and counters, `count * n_u` each or empty for a
/// batch without that pass kind: `snap_q` holds the last charge pass's
/// gathered x, `snap_lim` the gathered x at the last accepted point.
pub const Census = struct {
    n_u: u32,
    snap_q: []u64,
    snap_lim: []u64,
    tally: abi.CensusCounts = .{},

    /// Bits no gathered x holds before the first pass of its kind (a NaN
    /// payload the arithmetic never produces), so a first pass counts as
    /// changed. ponytail: a sentinel, not a per-instance primed flag.
    const unseen: u64 = 0x7ff4_c0de_c0de_c0de;

    /// A census over `count` instances of `n_u` unknowns; null when the
    /// snapshots cannot be allocated (stats only: the caller runs without).
    pub fn create(count: u32, n_u: u32, has_q: bool, has_limit: bool) ?*Census {
        const len = @as(usize, count) * n_u;
        const c = staging_gpa.create(Census) catch return null;
        c.* = .{ .n_u = n_u, .snap_q = &.{}, .snap_lim = &.{} };
        if (has_q) c.snap_q = staging_gpa.alloc(u64, len) catch return c.destroyNull();
        if (has_limit) c.snap_lim = staging_gpa.alloc(u64, len) catch return c.destroyNull();
        @memset(c.snap_q, unseen);
        @memset(c.snap_lim, unseen);
        assert(c.snap_q.len == if (has_q) len else 0);
        assert(c.snap_lim.len == if (has_limit) len else 0);
        return c;
    }

    /// Frees `c`.
    pub fn destroy(c: *Census) void {
        staging_gpa.free(c.snap_q);
        staging_gpa.free(c.snap_lim);
        staging_gpa.destroy(c);
    }

    /// Records instances `[first, last)`'s gathered x for a charge pass.
    pub fn observe(c: *Census, x: []const f64, gath: []const u32, first: u32, last: u32) void {
        assert(first <= last);
        assert(@as(usize, last) * c.n_u <= gath.len);
        if (c.snap_q.len == 0) return;
        c.tally.charge_pairs += last - first;
        c.tally.charge_same += record(c.snap_q, c.n_u, x, gath, first, last);
    }

    /// Counts instances `[first, last)` of a limit pass whose `reads`
    /// unknowns (one flag per unknown) all hold their bits from the last
    /// accepted point. Stores nothing: the reference moves only at `accept`.
    pub fn observeLimit(c: *Census, x: []const f64, gath: []const u32, reads: []const bool, first: u32, last: u32) void {
        assert(first <= last);
        assert(reads.len == c.n_u);
        if (c.snap_lim.len == 0) return;
        var same: u64 = 0;
        for (first..last) |id| {
            const at = id * c.n_u;
            var all = true;
            for (c.snap_lim[at..][0..c.n_u], gath[at..][0..c.n_u], reads) |s, g, r| {
                all = all and (!r or s == @as(u64, @bitCast(x[g])));
            }
            same += @intFromBool(all);
        }
        c.tally.limit_pairs += last - first;
        c.tally.limit_same += same;
    }

    /// The accepted point `x`: every instance's gathered bits become the
    /// limit passes' reference.
    pub fn accept(c: *Census, x: []const f64, gath: []const u32) void {
        if (c.snap_lim.len == 0) return;
        assert(c.snap_lim.len == gath.len);
        _ = record(c.snap_lim, c.n_u, x, gath, 0, @intCast(gath.len / c.n_u));
        assert(c.tally.limit_same <= c.tally.limit_pairs);
    }

    /// The counters since `create`.
    pub fn counts(c: *const Census) abi.CensusCounts {
        assert(c.tally.charge_same <= c.tally.charge_pairs);
        assert(c.tally.limit_same <= c.tally.limit_pairs);
        return c.tally;
    }

    // ---- private ----

    fn destroyNull(c: *Census) ?*Census {
        c.destroy();
        return null;
    }

    /// Stores each instance's gathered bits into `snap`; returns how many
    /// instances matched it bit for bit.
    fn record(snap: []u64, n_u: u32, x: []const f64, gath: []const u32, first: u32, last: u32) u64 {
        assert(snap.len == gath.len);
        var same: u64 = 0;
        for (first..last) |id| {
            var all = true;
            const at = id * n_u;
            for (snap[at..][0..n_u], gath[at..][0..n_u]) |*s, g| {
                const bits: u64 = @bitCast(x[g]);
                all = all and s.* == bits;
                s.* = bits;
            }
            same += @intFromBool(all);
        }
        assert(same <= last - first);
        return same;
    }
};
