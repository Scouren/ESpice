//! G1 stage 1 (docs/perf_research/05-levers-gpu.md): a lane group's
//! per-member host work spread over threads the executor borrows from the
//! Problem's `ThreadPool`. Each index runs exactly once and writes only its
//! own output row, so the result is the serial loop's at any thread count;
//! only the order the indices start in moves.
//! In: a count, a context and a per-index body. Out: the body's writes.
//! Cites: none.
//!
//! Contents:
//! - `pub fn each(pool, threads, count, ctx, comptime body) void`
//! - `pub const Lend = struct { pool, threads }`
//! - `pub threadlocal var lent: ?Lend`

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const worker = @import("worker.zig");
const ThreadPool = @import("exec_config.zig").ThreadPool;

/// The pool `each` borrows from and the threads that run its helpers.
pub const Lend = struct { pool: ?*ThreadPool, threads: ?*worker.Threads };

/// G1: the pool a GPU lane driver (`pss/mhb_gpu.zig`, `gpu/freq.zig`) fans
/// its per-member host work over. `executor_lanes.runGpuWave` sets it on
/// its own thread around the lane driver, only under the `g1` lever, and
/// clears it after; it is null everywhere else, helper threads included,
/// so a fan never nests. Null means the drivers run today's serial loops.
// ponytail: a thread-local instead of a `RunCtx` field, so the lever-off
// path keeps its shape; a field once the lever is accepted.
pub threadlocal var lent: ?Lend = null;

/// Most helper threads one fan borrows, in `ThreadPool.per_query` chunks:
/// a lane group stands for many queries, so it may take the whole pool.
// ponytail: 64 threads in all, the pool of a 128-thread machine (half the
// logical CPUs); size the slot arrays from the pool if a bigger one shows.
const helpers_max: u32 = 63;

/// Runs `body(ctx, i)` once for every i in 0..count: on this thread plus
/// up to `helpers_max` (63) helpers it borrows from `pool` in
/// `ThreadPool.per_query` chunks (none without a pool or in a
/// single-threaded build) and gives back before it returns. `threads` lends the helpers (null spawns them); a helper that
/// fails to start leaves its share to this thread. Indices are claimed
/// dynamically, so `body` must touch only index `i`'s state and whatever
/// is safe to share; its writes are visible to the caller on return.
pub fn each(
    pool: ?*ThreadPool,
    threads: ?*worker.Threads,
    count: usize,
    ctx: anytype,
    comptime body: fn (@TypeOf(ctx), usize) void,
) void {
    const Ctx = @TypeOf(ctx);
    const Shared = struct {
        ctx: Ctx,
        count: usize,
        next: std.atomic.Value(usize) = .init(0),

        fn drain(raw: *anyopaque) void {
            // SAFETY: `each` hands every task this `Shared`, alive until
            // the joins below.
            const s: *@This() = @ptrCast(@alignCast(raw));
            // Each pass claims a fresh index, so count + 1 passes bound it.
            for (0..s.count + 1) |_| {
                const i = s.next.fetchAdd(1, .monotonic);
                if (i >= s.count) return;
                body(s.ctx, i);
            }
            unreachable;
        }
    };
    var shared: Shared = .{ .ctx = ctx, .count = count };
    const want: u32 = if (builtin.single_threaded) 0 else @intCast(@min(count -| 1, helpers_max));
    const borrowed: u32 = if (pool) |p| borrow(p, want) else 0;
    defer if (pool) |p| giveBack(p, borrowed);
    assert(borrowed <= helpers_max);
    var pooled: [helpers_max]?*worker.Threads.Slot = @splat(null);
    var spawned: [helpers_max]?std.Thread = @splat(null);
    // A single-threaded build borrows none and never names a thread.
    if (!builtin.single_threaded) for (0..borrowed) |h| {
        if (threads) |t| {
            pooled[h] = t.spawn(.{ .run = Shared.drain, .ctx = &shared }) catch null;
            if (pooled[h] != null) continue;
        }
        spawned[h] = std.Thread.spawn(.{ .stack_size = worker.stack_size }, Shared.drain, .{@as(*anyopaque, &shared)}) catch null;
    };
    Shared.drain(&shared);
    if (!builtin.single_threaded) for (pooled[0..borrowed], spawned[0..borrowed]) |slot, th| {
        if (slot) |s| threads.?.join(s) else if (th) |t| t.join();
    };
    assert(shared.next.load(.monotonic) >= count);
}

// ---- private ----

/// Up to `want` threads from `pool`, at most `ThreadPool.per_query` per
/// `take` (the most one `give` returns), stopping when the pool is dry.
fn borrow(pool: *ThreadPool, want: u32) u32 {
    var got: u32 = 0;
    // Each pass takes at least one thread or stops: want + 1 passes bound it.
    for (0..@as(usize, want) + 1) |_| {
        if (got == want) break;
        const step = pool.take(@min(ThreadPool.per_query, want - got));
        if (step == 0) break;
        got += step;
    }
    assert(got <= want);
    return got;
}

/// Returns `n` threads `borrow` took, `ThreadPool.per_query` per `give`.
fn giveBack(pool: *ThreadPool, n: u32) void {
    var left = n;
    for (0..(n + ThreadPool.per_query - 1) / ThreadPool.per_query) |_| {
        const step = @min(left, ThreadPool.per_query);
        pool.give(step);
        left -= step;
    }
    assert(left == 0);
}

// Oracle: the same body in a plain serial loop. Every row compares bitwise
// (a float series whose rounding depends on its operand order, and an
// error for some members), at 1, 2, 33 and 64 threads (pools of 0, 1, 32
// and 128 free threads, the last two taken in `per_query` chunks), with
// pooled and spawned helpers. The pool's free count must come back whole.
test "each: every row bitwise the serial loop's, at 1 to 64 threads" {
    const Row = error{Failed}!f64;
    const Fan = struct {
        out: []Row,
        fn member(i: usize) Row {
            if (i % 7 == 3) return error.Failed;
            var sum: f64 = 0;
            for (0..200 + i % 13) |j| sum += 1.0 / @as(f64, @floatFromInt(j * 3 + i + 1));
            return sum;
        }
        fn run(f: @This(), i: usize) void {
            f.out[i] = member(i);
        }
    };
    const n = 257;
    var want: [n]Row = undefined;
    for (&want, 0..) |*w, i| w.* = Fan.member(i);
    var threads: worker.Threads = .init(std.testing.allocator, std.testing.io);
    defer threads.deinit();
    for ([_]usize{ 0, 2, 64, 256 }) |cpus| for ([_]?*worker.Threads{ null, &threads }) |lend| {
        var pool: ThreadPool = .init(cpus);
        const free = pool.free.load(.monotonic);
        var got: [n]Row = @splat(error.Failed);
        each(&pool, lend, n, Fan{ .out = &got }, Fan.run);
        try std.testing.expectEqual(free, pool.free.load(.monotonic));
        for (want, got) |w, g| {
            if (w) |a| {
                try std.testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(try g)));
            } else |e| try std.testing.expectError(e, g);
        }
    };
    // No pool: this thread alone.
    var got: [n]Row = @splat(error.Failed);
    each(null, null, n, Fan{ .out = &got }, Fan.run);
    for (want, got) |w, g| {
        if (w) |a| {
            try std.testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(try g)));
        } else |e| try std.testing.expectError(e, g);
    }
}
