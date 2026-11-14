//! The device LU's kernel bodies on host threads: the tables of one pivot
//! epoch and a factor's values in, the refactored factors and solutions
//! out, bitwise the GPU's and `SparseLu.refactor`'s. `runHost` runs the
//! refactor and both solves on `threads` threads (the kernels' ticket
//! schedule with a one-lane block); `HostRefactor` keeps one epoch's tables
//! and buffers for `direct`'s multicore refactor. For tests, `runBlocks`
//! runs every kernel with blocks of several lane threads between real
//! barriers, the schedule a device block runs.
//! Cites: dev/solvers/gpu-lu.md ("Multicore host refactor", option 3).
//!
//! Contents:
//! - `pub const HostBufs = struct`
//! - `pub const test_access = if (@import("builtin").is_test) .{ .runHostCap = runHostCap, .runBlocks = runBlocks } else {}`
//! - `pub const HostRefactor = struct`
//!   - `pub fn init(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64) !HostRefactor`
//!   - `pub const Init = struct`
//!   - `pub fn initWith(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64, runs: bool) !HostRefactor`
//!   - `pub fn initOpts(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64, opt: Init) !HostRefactor`
//!   - `pub fn deinit(self: *HostRefactor, gpa: std.mem.Allocator) void`
//!   - `pub fn run(self: *HostRefactor, lu: *SparseLu, vals: []const f64, io: std.Io, threads: u32) error{SingularMatrix}!void`
//!   - `pub fn P(comptime T: type) type`
//!   - `pub inline fn barrier() void {}`
//!   - `pub inline fn pause(spins: u32) void`
//!   - `pub inline fn acquire(p: *const u32) u32`
//!   - `pub inline fn release(p: *u32, v: u32) void`
//! - `pub fn runHost(t: klu.Tab, b: HostBufs, stamp: u32, threads: u32) !?u32`

const std = @import("std");
const assert = std.debug.assert;
const klu = @import("lu.zig");
const lu_tables = @import("lu_tables.zig");
const lu_tile = @import("lu_tile.zig");
const SparseLu = @import("../sparse_lu.zig").SparseLu;

/// Host buffers for one `runHost` call; `sync` must be zeroed once after
/// the tables are built, and `stamp` must grow by one per call.
pub const HostBufs = struct {
    /// The index buffer `build` returned (`lu_tables.Tables.idx`), `n_idx` words.
    idx: []const u32,
    /// Factor values, `n_val` slots laid out as `Tab.coff` says.
    val: []f64,
    /// A's values in CSC order.
    a: []const f64,
    /// The residual; the solve returns dx = -A^-1 rhs.
    rhs: []const f64,
    /// Solve scratch, n entries; holds z = U^-1 L^-1 P (-rhs) afterwards.
    y: []f64,
    /// The Newton step, n entries.
    dx: []f64,
    /// `Tab.syncLen()` words of tickets and done stamps.
    sync: []u32,
};

/// Private functions for tests.zig; void outside test builds.
pub const test_access = if (@import("builtin").is_test) .{ .runHostCap = runHostCap, .runBlocks = runBlocks } else {};

/// The refactor kernel body as a multicore host refactor (dev/solvers/
/// gpu-lu.md option 3): one pivot epoch's tables and buffers. Its factors
/// are bitwise `SparseLu.refactor`'s, so callers may pick it by speed.
pub const HostRefactor = struct {
    /// `SparseLu.pattern_epoch` the tables were built from.
    epoch: u32,
    tb: lu_tables.Tables,
    val: []f64,
    /// Line-aligned, so the header fills exactly the first line.
    sync: []align(64) u32,
    stamp: u32 = 0,

    /// `initOpts`' choices. `runs`: each supernode run of a column is one
    /// step (`lu_tables.Options.runs`; needs `lu`'s C1 tables). `tile`
    /// (lever N1): the tail `lu_tile.choose` admits runs as tiles.
    pub const Init = struct { runs: bool = false, tile: bool = false };

    /// Builds the tables for `lu`'s current factor (4 bytes per flop).
    /// Caller owns the result; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64) !HostRefactor {
        return initWith(gpa, lu, col_ptr, growth, false);
    }

    /// `init`, with `runs` taking each supernode run of a column as one
    /// step (`lu_tables.Options.runs`; needs `lu`'s C1 tables, else as
    /// `init`). Same factors, bitwise.
    pub fn initWith(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64, runs: bool) !HostRefactor {
        return initOpts(gpa, lu, col_ptr, growth, .{ .runs = runs });
    }

    /// `init` with the choices of `opt`. Same factors, bitwise.
    pub fn initOpts(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64, opt: Init) !HostRefactor {
        // No solve runs from these tables: skip the tail cut search.
        var tb = try lu_tables.build(gpa, lu, col_ptr, growth, .{ .tail = lu.n, .runs = opt.runs, .tile = opt.tile });
        errdefer tb.deinit(gpa);
        const val = try gpa.alloc(f64, tb.tab.n_val);
        errdefer gpa.free(val);
        const sync = try gpa.alignedAlloc(u32, .@"64", tb.tab.syncLen());
        @memset(sync, 0);
        assert(tb.idx.len == tb.tab.n_idx);
        return .{ .epoch = lu.pattern_epoch, .tb = tb, .val = val, .sync = sync };
    }

    /// Frees the tables and buffers; `lu` stays the caller's.
    pub fn deinit(self: *HostRefactor, gpa: std.mem.Allocator) void {
        self.tb.deinit(gpa);
        gpa.free(self.val);
        gpa.free(self.sync);
        self.* = undefined;
    }

    /// `lu.refactor(col_ptr, vals, growth)`, with the `growth` `init` got,
    /// on the caller plus `threads - 1` tasks of `io` (at most 15), then the
    /// factors copied into `lu`.
    /// Fails exactly when `refactor` would, and `lu`'s factors are then
    /// unusable, as after a failed `refactor`. Asserts that `lu` is factored
    /// on the epoch the tables were built from.
    pub fn run(self: *HostRefactor, lu: *SparseLu, vals: []const f64, io: std.Io, threads: u32) error{SingularMatrix}!void {
        assert(lu.factored);
        assert(lu.pattern_epoch == self.epoch);
        assert(self.sync.len == self.tb.tab.syncLen());
        assert(self.val.len == self.tb.tab.n_val);
        for (lu.void_slots.items) |p| {
            if (vals[p] != 0) return error.SingularMatrix;
        }
        const work = RefactorLoop(klu.col_max).work;
        self.stamp +%= 1;
        @memset(self.sync[0..klu.sync_header], 0);
        resetTile(self.tb.tab, self.sync);
        const args = .{ self.tb.tab, self.tb.idx.ptr, self.val.ptr, @constCast(vals.ptr), self.sync.ptr, self.stamp };
        var futures: [15]std.Io.Future(void) = undefined;
        const extra = @min(@max(threads, 1) - 1, futures.len);
        for (futures[0..extra]) |*f| f.* = io.async(work, args);
        @call(.auto, work, args);
        for (futures[0..extra]) |*f| f.await(io);
        const t = self.tb.tab;
        assert(self.sync[1] <= t.n);
        if (self.sync[1] != 0) return error.SingularMatrix;
        const x = self.tb.idx;
        for (0..t.n) |k| {
            const base = x[t.coff + k];
            const nuk = lu.up[k + 1] - lu.up[k];
            const nlk = lu.lp[k + 1] - lu.lp[k];
            @memcpy(lu.ux.items[lu.up[k]..][0..nuk], self.val[base..][0..nuk]);
            lu.udiag[k] = self.val[base + nuk];
            @memcpy(lu.lx.items[lu.lp[k]..][0..nlk], self.val[base + nuk + 1 ..][0..nlk]);
        }
    }
};

/// The host instance: plain pointers, a block of one lane.
const HostSy = struct {
    /// A plain many-item pointer: host memory has one address space.
    pub fn P(comptime T: type) type {
        return [*]T;
    }
    /// A no-op: a host block is one lane.
    pub inline fn barrier() void {}
    /// Spins briefly, then yields: on a loaded machine the thread holding
    /// the awaited column may be the one descheduled (chain_psp103_10k at
    /// load 98: 16.7 s of pure spinning became 149 s).
    pub inline fn pause(spins: u32) void {
        // Single-threaded never waits (wasm32-wasi has no sched_yield).
        if (spins < 256 or @import("builtin").single_threaded) std.atomic.spinLoopHint() else std.Thread.yield() catch |err| switch (err) {
            // A system that cannot yield keeps spinning.
            error.SystemCannotYield => std.atomic.spinLoopHint(),
        };
    }
    /// Reads a done stamp; pairs with `release`.
    pub inline fn acquire(p: *const u32) u32 {
        return @atomicLoad(u32, p, .acquire);
    }
    /// Publishes a done stamp after the column's stores.
    pub inline fn release(p: *u32, v: u32) void {
        @atomicStore(u32, p, v, .release);
    }
};

/// Lanes of one test block share its scratch and this barrier. A last
/// arriver resets the count, then bumps the generation (release); every
/// lane's earlier stores are visible to every lane leaving the barrier.
const LaneBarrier = struct {
    lanes: u32,
    count: std.atomic.Value(u32) = .init(0),
    gen: std.atomic.Value(u32) = .init(0),

    fn wait(b: *LaneBarrier) void {
        assert(b.lanes > 0);
        const g = b.gen.load(.acquire);
        if (b.count.fetchAdd(1, .acq_rel) + 1 == b.lanes) {
            b.count.store(0, .monotonic);
            b.gen.store(g +% 1, .release);
            return;
        }
        var spins: u32 = 0;
        while (b.gen.load(.acquire) == g) : (spins +%= 1) HostSy.pause(spins);
        assert(b.count.load(.monotonic) < b.lanes);
    }
};

/// The host instance of a block of several lanes, one thread each (tests):
/// `barrier` is the block's `LaneBarrier`, so the lanes of a step run at
/// once, as on the device.
const BlockSy = struct {
    /// This lane thread's block barrier, set before its first kernel call.
    threadlocal var bar: ?*LaneBarrier = null;
    /// A plain many-item pointer, as `HostSy.P`.
    pub fn P(comptime T: type) type {
        return [*]T;
    }
    /// Waits for every lane of the block.
    pub inline fn barrier() void {
        bar.?.wait();
    }
    /// `HostSy.pause`.
    pub inline fn pause(spins: u32) void {
        HostSy.pause(spins);
    }
    /// `HostSy.acquire`.
    pub inline fn acquire(p: *const u32) u32 {
        return HostSy.acquire(p);
    }
    /// `HostSy.release`.
    pub inline fn release(p: *u32, v: u32) void {
        HostSy.release(p, v);
    }
};

/// Refactors on `threads` host threads (at most 64) and solves on this one
/// with the kernel bodies: bitwise `refactorColumns` plus `solve` (dx =
/// -A^-1 rhs). Returns the lowest failing pivot step, or null; the solves
/// then leave `y` and `dx` untouched. One thread is the scalar oracle: it
/// takes every ticket in order, so no wait ever spins. A thread that fails
/// to spawn leaves its tickets to the others. Fails only when the solve
/// scratch (40 KB) cannot be allocated. Asserts that `b` holds the index,
/// value and sync lengths `t` names.
pub fn runHost(t: klu.Tab, b: HostBufs, stamp: u32, threads: u32) !?u32 {
    return runHostCap(klu.col_max, t, b, stamp, threads);
}

// ---- private ----

/// One host thread's refactor: takes tickets until they run out, with the
/// block scratch capped at `cap` slots (0 runs every column in `val`).
fn RefactorLoop(comptime cap: u32) type {
    return struct {
        fn work(t: klu.Tab, x: [*]u32, val: [*]f64, av: [*]f64, sy: [*]u32, stamp: u32) void {
            const H = klu.Kernels(HostSy, cap, 1);
            var sh: H.Shared = undefined;
            const T = lu_tile.Tile(HostSy);
            if (t.dmap16 != 0) {
                while (H.refactor(u16, t, x, val, av, sy, stamp, &sh, 0, 1)) {}
                T.work(u16, t, x, val, av, sy, stamp);
            } else {
                while (H.refactor(u32, t, x, val, av, sy, stamp, &sh, 0, 1)) {}
                T.work(u32, t, x, val, av, sy, stamp);
            }
        }
    };
}

/// Zeroes `lever_tile`'s per-run sync words (`Tab.tileWords`).
fn resetTile(t: klu.Tab, sync: []u32) void {
    assert(sync.len >= t.syncLen());
    assert(t.tile0 <= t.n);
    @memset(sync[t.tileSync()..][0..t.tileWords()], 0);
}

// `runHost` with the refactor's scratch capped at `cap` slots; 0 runs
// every column in `val`, the path the device takes past `col_max`.
fn runHostCap(comptime cap: u32, t: klu.Tab, b: HostBufs, stamp: u32, threads: u32) !?u32 {
    assert(b.idx.len >= t.n_idx);
    assert(b.val.len >= t.n_val);
    assert(b.sync.len >= t.syncLen());
    const H = klu.Kernels(HostSy, cap, 1);
    @memset(b.sync[0..klu.sync_header], 0);
    resetTile(t, b.sync);
    const x = @constCast(b.idx.ptr);
    const work = RefactorLoop(cap).work;
    const args = .{ t, x, b.val.ptr, @constCast(b.a.ptr), b.sync.ptr, stamp };
    var pool: [63]std.Thread = undefined;
    const extra = @min(@max(threads, 1) - 1, pool.len);
    // Returning on a failed spawn would free `b` under the running threads.
    var spawned: usize = 0;
    // Single-threaded (wasm) never names `spawn`: one thread, the oracle.
    if (!@import("builtin").single_threaded) {
        for (pool[0..extra]) |*th| {
            th.* = std.Thread.spawn(.{}, work, args) catch break;
            spawned += 1;
        }
    }
    @call(.auto, work, args);
    for (pool[0..spawned]) |th| th.join();
    var ssh: H.SolveShared = undefined;
    // 34 KB, too much for a worker thread's stack.
    const psh = try std.heap.page_allocator.create(H.PanelShared);
    defer std.heap.page_allocator.destroy(psh);
    // Forward, y = L^-1 P (-rhs): every head ticket, then every panel. Back,
    // z = U^-1 y: every panel, then every head ticket. Each does nothing
    // once the refactor failed.
    const val = b.val.ptr;
    const sy = b.sync.ptr;
    while (H.lhead(t, x, val, @constCast(b.rhs.ptr), b.y.ptr, sy, stamp, &ssh, 0, 1)) {}
    while (H.lpanel(t, x, val, b.y.ptr, sy, stamp, psh, 0, 1)) {}
    while (H.upanel(t, x, val, b.y.ptr, b.dx.ptr, sy, stamp, psh, 0, 1)) {}
    while (H.uhead(t, x, val, b.y.ptr, b.dx.ptr, sy, stamp, &ssh, 0, 1)) {}
    const f = b.sync[1];
    assert(f <= t.n);
    return if (f == 0) null else t.n - f;
}

// `runHostCap` with every kernel run by `blocks` blocks of `lanes` lane
// threads (at most 64 threads), each kernel a launch after the one before:
// the lanes of one block run a step at once between real barriers, the
// device's schedule, where `runHost`'s one-lane blocks run it in order.
// Test harness: a lane that fails to spawn panics, since its block would
// wait for it forever.
fn runBlocks(comptime cap: u32, comptime lanes: u32, t: klu.Tab, b: HostBufs, stamp: u32, blocks: u32) !?u32 {
    if (@import("builtin").single_threaded) return error.SingleThreaded else return BlockRun(cap, lanes).run(t, b, stamp, blocks);
}

fn BlockRun(comptime cap: u32, comptime lanes: u32) type {
    return struct {
        const H = klu.Kernels(BlockSy, cap, lanes);
        const Kernel = enum { refactor, tile, lhead, lpanel, upanel, uhead };
        // One block's scratch, what a device block keeps in shared memory.
        const Block = struct {
            bar: LaneBarrier = .{ .lanes = lanes },
            sh: H.Shared = undefined,
            ssh: H.SolveShared = undefined,
            psh: H.PanelShared = undefined,
        };

        fn Lane(comptime which: Kernel) type {
            return struct {
                // Tickets until they run out. The barrier after each ends
                // the block as a device block exits: no lane still reads
                // the old ticket when lane 0 takes the next.
                fn run(blk: *Block, t: klu.Tab, b: HostBufs, stamp: u32, tid: u32) void {
                    BlockSy.bar = &blk.bar;
                    const x = @constCast(b.idx.ptr);
                    const val = b.val.ptr;
                    const sy = b.sync.ptr;
                    // The tiles: every lane thread a worker of its own.
                    if (which == .tile) {
                        const T = lu_tile.Tile(BlockSy);
                        if (t.dmap16 != 0) T.work(u16, t, x, val, @constCast(b.a.ptr), sy, stamp) else T.work(u32, t, x, val, @constCast(b.a.ptr), sy, stamp);
                        return;
                    }
                    while (switch (which) {
                        .refactor => if (t.dmap16 != 0)
                            H.refactor(u16, t, x, val, @constCast(b.a.ptr), sy, stamp, &blk.sh, tid, lanes)
                        else
                            H.refactor(u32, t, x, val, @constCast(b.a.ptr), sy, stamp, &blk.sh, tid, lanes),
                        .lhead => H.lhead(t, x, val, @constCast(b.rhs.ptr), b.y.ptr, sy, stamp, &blk.ssh, tid, lanes),
                        .lpanel => H.lpanel(t, x, val, b.y.ptr, sy, stamp, &blk.psh, tid, lanes),
                        .upanel => H.upanel(t, x, val, b.y.ptr, b.dx.ptr, sy, stamp, &blk.psh, tid, lanes),
                        .uhead => H.uhead(t, x, val, b.y.ptr, b.dx.ptr, sy, stamp, &blk.ssh, tid, lanes),
                        .tile => false,
                    }) blk.bar.wait();
                }
            };
        }

        fn run(t: klu.Tab, b: HostBufs, stamp: u32, blocks: u32) !?u32 {
            assert(blocks >= 1 and blocks * lanes <= 64);
            assert(b.idx.len >= t.n_idx and b.val.len >= t.n_val);
            assert(b.sync.len >= t.syncLen());
            @memset(b.sync[0..klu.sync_header], 0);
            resetTile(t, b.sync);
            const blk = try std.heap.page_allocator.alloc(Block, blocks);
            defer std.heap.page_allocator.free(blk);
            inline for (.{ .refactor, .tile, .lhead, .lpanel, .upanel, .uhead }) |which| {
                for (blk) |*k| k.* = .{};
                var th: [64]std.Thread = undefined;
                var n: usize = 0;
                for (blk) |*k| for (0..lanes) |l| {
                    th[n] = std.Thread.spawn(.{}, Lane(which).run, .{ k, t, b, stamp, @as(u32, @intCast(l)) }) catch @panic("runBlocks: a lane thread failed to spawn");
                    n += 1;
                };
                for (th[0..n]) |h| h.join();
            }
            const f = b.sync[1];
            assert(f <= t.n);
            return if (f == 0) null else t.n - f;
        }
    };
}
