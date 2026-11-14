//! N7's LTE step bound on the evaluation's lanes (docs/perf_research/
//! 09-after-the-levers.md, "N7 Step bookkeeping"). `stepBound` costs about
//! 20 ns per charge state per attempt at every lane count: per state it
//! streams five histories (q0..q3, i_prev: 40 bytes) and runs eight
//! dependent IEEE divisions (the tolerance's /dt, the three or four
//! divided-difference quotients and the final del quotient), none of which
//! may become a reciprocal multiply without moving bits. The work is split
//! here into chunks of states, each chunk's min taken by the unchanged
//! `stepBoundMin` on a lane, and the chunk minima combined NaN first, which
//! is the serial loop's min: every state rounds alike in any chunk, a NaN
//! anywhere makes the whole bound NaN, and no del is -0.
//!
//! Contents:
//! - `pub const min_states: usize`
//! - `pub fn chunkOf(n: usize, lanes: usize) usize`
//! - `pub fn combineMin(mins: []const f64) f64`
//! - `pub fn boundLanes(pool: anytype, mins: []f64, chunk: usize, method: Method, cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64`

const std = @import("std");
const assert = std.debug.assert;
const integrator = @import("integrator.zig");
const Method = @import("types.zig").Method;
const Coeffs = integrator.Coeffs;
const LteIn = integrator.LteIn;

/// Fewer charge states than this keep the serial bound. A pass's wake and
/// join cost about 4 us, what 200 states cost serially at 20 ns each; on
/// L lanes the pass pays when n * 20 ns * (1 - 1/L) > 4 us, n > 400 at 2
/// lanes and n > 230 at 8. 1024 is 2.5x the 2-lane break-even and 4.4x the
/// 8-lane one (chain_bsim4_1k's ~2450 states take it).
/// ponytail: a fixed threshold from an estimated wake cost; price it per
/// machine (`price.zig`) if a deck near it matters.
pub const min_states: usize = 1024;

const W = std.simd.suggestVectorLength(f64) orelse 8;

/// The chunk length for `n` states over `lanes` lanes: about four chunks a
/// lane, a multiple of the vector width so no chunk splits a vector the
/// serial loop would take whole (not needed for the bits, only for the
/// tail count).
pub fn chunkOf(n: usize, lanes: usize) usize {
    assert(lanes >= 1);
    assert(n >= 1);
    const want = std.math.divCeil(usize, n, lanes * 4) catch unreachable;
    return std.mem.alignForward(usize, @max(want, W), W);
}

/// The min of the chunk minima, NaN first: any NaN chunk makes the bound
/// NaN, as one NaN state makes the serial loop's. Asserts at least one
/// chunk.
pub fn combineMin(mins: []const f64) f64 {
    assert(mins.len >= 1);
    var m = std.math.inf(f64);
    for (mins) |v| {
        if (std.math.isNan(v)) return v;
        m = @min(m, v);
    }
    assert(!std.math.isNan(m));
    return m;
}

/// `integrator.stepBound`'s bits with its states split into `mins.len`
/// chunks of `chunk` states (the last one shorter), each run as one task
/// of `pool.each(n_tasks, ctx, f)`, which calls `f(ctx, i)` once for every
/// i in any order and on any lane, and returns when all are done (ParEval's
/// `each`). Each task writes only `mins[i]`.
pub fn boundLanes(pool: anytype, mins: []f64, chunk: usize, method: Method, cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    const n = i_prev.len;
    assert(mins.len == std.math.divCeil(usize, n, chunk) catch unreachable);
    assert(chunk % W == 0);
    const Job = struct {
        q: [4][]const f64,
        i_prev: []const f64,
        c: Coeffs,
        lte: LteIn,
        method: Method,
        cur_method: Method,
        chunk: usize,
        mins: []f64,

        fn run(ctx: *anyopaque, i: u32) void {
            const j: *const @This() = @ptrCast(@alignCast(ctx));
            const lo = @as(usize, i) * j.chunk;
            const hi = @min(lo + j.chunk, j.i_prev.len);
            assert(lo < hi);
            const part: [4][]const f64 = .{ j.q[0][lo..hi], j.q[1][lo..hi], j.q[2][lo..hi], j.q[3][lo..hi] };
            j.mins[i] = integrator.stepBoundMin(W, j.method, j.cur_method, part, j.i_prev[lo..hi], j.c, j.lte);
        }
    };
    var job: Job = .{ .q = q, .i_prev = i_prev, .c = c, .lte = lte, .method = method, .cur_method = cur_method, .chunk = chunk, .mins = mins };
    pool.each(@intCast(mins.len), @ptrCast(&job), Job.run);
    return integrator.boundRoot(method, combineMin(mins));
}
