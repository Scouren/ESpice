//! ParEval's lane tables and waits, beside `par_eval.zig`: its chunk and
//! gather tables, the lane-affine claim order (lever N8), the barrier that
//! parks its waiters (lever C6), the spinning wait and the P-core pin.
//! C7 step 2's census of cells one chunk fills alone is here too.
//! Neither lever moves a bit: N8 changes only which lane stamps a chunk or reduces
//! a block, never the tape order of a cell's sum; C6 changes only how a lane
//! waits.
//!
//! N8. Lane l's home is a contiguous run of stamp chunks, and each reduce
//! block's home is the lane whose home chunks stage most of the block's
//! positions, so the lane that sums and resets a staging line mostly wrote
//! it. A lane claims its own chunks and blocks first and steals from the
//! other lanes' in ring order once its own are gone.
//! In: the chunks' staging spans, the gathers and the block cuts. Out: the
//! affinity tables, built once in `ParEval.init`.
//! Cites docs/perf_research/09-after-the-levers.md (N8),
//! 04-levers-cpu.md (C6); the parked barrier is `perf/pareval-idle`
//! (ad27f430).
//!
//! Contents:
//! - `pub const Counter = struct`
//! - `pub const Arrivals = struct` (`zero`, `arrive`, `wait`)
//! - `pub const Span = struct`
//! - `pub const EvalTask = struct`
//! - `pub const Gather = struct` (`build`, `deinit`)
//! - `pub const Affinity = struct` (`build`, `deinit`, `reset`, `claimTask`, `claimBlock`)
//! - `pub const Census = struct`, `pub const StampCensus = struct`
//! - `pub const park_spins_short: u32`
//! - `pub const chunks_per_lane`, `pub const block_align`
//! - `pub fn instanceWeight(b: Batch) u64`
//! - `pub fn chunkTasks(gpa, batches, n_lanes) ![]EvalTask`
//! - `pub fn cutBlocks(gpa, slot_seg, row_seg, n_lanes) ![]u32`
//! - `pub fn buildAffinity(...) !Affinity`
//! - `pub fn singleTaskCensus(gather: Gather, starts: []const u32) Census`
//! - `pub fn stampCensus(gpa, batches, tasks, slot_base, row_base, n_slot, slots, rows) !StampCensus`
//! - `pub fn pinToPerformanceCores() void`
//! - `pub fn waitCount(counter: *std.atomic.Value(u32), target: u32) void`

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Batch = @import("device").abi.Batch;

/// A u32 counter padded to a whole cache line: the struct's size rounds up
/// to its alignment, so no other field shares the line.
pub const Counter = struct {
    v: std.atomic.Value(u32) align(std.atomic.cache_line),
};

/// A barrier's arrival count with its parked waiters, on one line of its
/// own. Under C6 waiters spin `park_spins_short` pauses, then park on `v`
/// (`wait`); the arrival that reaches the target wakes them only when
/// `sleepers` is nonzero (`arrive`). With C6 off ParEval reads `v` alone,
/// as a plain spinning counter.
pub const Arrivals = struct {
    v: std.atomic.Value(u32) align(std.atomic.cache_line),
    sleepers: std.atomic.Value(u32),

    /// No arrivals, no sleepers.
    pub const zero: Arrivals = .{ .v = .init(0), .sleepers = .init(0) };

    /// Counts one arrival. The arrival that brings the count to `target`
    /// wakes the parked waiters, paying the syscall only when one is.
    /// Asserts that the count has not passed `target`.
    pub fn arrive(a: *Arrivals, io: std.Io, target: u32) void {
        assert(target > 0);
        // seq_cst pairs with the waiter's `sleepers` increment and recheck
        // (`wait`): either it sees `target` or this sees it parking.
        const v = a.v.fetchAdd(1, .seq_cst) + 1;
        assert(v <= target);
        if (v == target and a.sleepers.load(.seq_cst) != 0)
            io.futexWake(u32, &a.v.raw, std.math.maxInt(u32));
    }

    /// Spins `park_spins_short` pauses, then parks, until the count reaches
    /// `target`. A waiter woken short of `target` parks again. Asserts on
    /// exit that the count reached `target`.
    pub fn wait(a: *Arrivals, io: std.Io, target: u32) void {
        var spins: u32 = 0;
        var v = a.v.load(.acquire);
        while (v < target) : (v = a.v.load(.acquire)) {
            if (spins < park_spins_short) {
                std.atomic.spinLoopHint();
                spins += 1;
                continue;
            }
            _ = a.sleepers.fetchAdd(1, .seq_cst);
            const seen = a.v.load(.seq_cst);
            // The futex sleeps only while `v` still holds `seen`.
            if (seen < target) io.futexWaitUncancelable(u32, &a.v.raw, seen);
            _ = a.sleepers.fetchSub(1, .seq_cst);
        }
        assert(v >= target);
    }
};

comptime {
    assert(@sizeOf(Counter) == std.atomic.cache_line);
    assert(@sizeOf(Arrivals) == std.atomic.cache_line);
}

/// One stamp chunk's staging positions: slots `[slot_lo, slot_hi)` and rows
/// `[row_lo, row_hi)` (instance-major tapes, so a chunk's are contiguous).
pub const Span = struct {
    slot_lo: u32,
    slot_hi: u32,
    row_lo: u32,
    row_hi: u32,
};

/// A stamp chunk: instances [first, last) of batch `batch`.
pub const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

comptime {
    // Claimed one per `fetchAdd`; all three fields are read together.
    assert(@sizeOf(EvalTask) == 12);
}

/// Cell -> its staging positions in tape order, for one index space (slots
/// or rows). Cell i's positions are `src[seg[i]..seg[i + 1]]`; ground
/// entries are in no cell.
pub const Gather = struct {
    seg: []u32,
    src: []u32,

    /// Counting sort of `tapes` (each batch's tape, its positions starting
    /// at `base[b]`) by destination cell, stable, so each run keeps tape
    /// order. `trash` (ground) entries are dropped.
    pub fn build(gpa: std.mem.Allocator, tapes: []const []const u32, n_cells: usize, trash: u32) !Gather {
        const seg = try gpa.alloc(u32, n_cells + 1);
        errdefer gpa.free(seg);
        @memset(seg, 0);
        for (tapes) |tape| for (tape) |dest| {
            if (dest != trash) seg[dest + 1] += 1;
        };
        for (1..seg.len) |i| seg[i] += seg[i - 1];
        const src = try gpa.alloc(u32, seg[n_cells]);
        errdefer gpa.free(src);
        const cursor = try gpa.dupe(u32, seg[0..n_cells]);
        defer gpa.free(cursor);
        var pos: u32 = 0;
        for (tapes) |tape| for (tape) |dest| {
            if (dest != trash) {
                src[cursor[dest]] = pos;
                cursor[dest] += 1;
            }
            pos += 1;
        };
        return .{ .seg = seg, .src = src };
    }

    /// Frees both tables.
    pub fn deinit(self: Gather, gpa: std.mem.Allocator) void {
        gpa.free(self.seg);
        gpa.free(self.src);
    }
};

/// N8's claim tables. Lane l's home chunks are `[task_off[l], task_off[l +
/// 1])`, in chunk order; its home reduce blocks are
/// `block_order[block_off[l]..block_off[l + 1]]`. `task_next[l]` and
/// `block_next[l]` count the claims taken from lane l's home this pass.
pub const Affinity = struct {
    task_off: []u32,
    block_off: []u32,
    block_order: []u32,
    task_next: []Counter,
    block_next: []Counter,

    /// Splits the `spans.len` chunks into `n_lanes` contiguous home runs and
    /// gives each reduce block (`cuts`, over the slot-then-row cells) the
    /// home lane that staged most of its positions, ties to the lower lane.
    /// The gathers are `ParEval`'s (cell i's positions are
    /// `src[seg[i]..seg[i + 1]]`). `n_slot`/`n_row` are the staging lengths,
    /// which the spans must tile. Fails only on allocation.
    pub fn build(
        gpa: std.mem.Allocator,
        n_lanes: u32,
        spans: []const Span,
        n_slot: u32,
        n_row: u32,
        slot_seg: []const u32,
        slot_src: []const u32,
        row_seg: []const u32,
        row_src: []const u32,
        cuts: []const u32,
    ) !Affinity {
        assert(n_lanes >= 1);
        assert(cuts.len >= 1);
        const nnz: u32 = @intCast(slot_seg.len - 1);
        const n_blocks = cuts.len - 1;

        const task_off = try gpa.alloc(u32, n_lanes + 1);
        errdefer gpa.free(task_off);
        for (task_off, 0..) |*o, l| o.* = @intCast(@as(u64, spans.len) * l / n_lanes);

        // Position -> home lane of the chunk that stages it; init only.
        const slot_lane = try gpa.alloc(u32, n_slot);
        defer gpa.free(slot_lane);
        const row_lane = try gpa.alloc(u32, n_row);
        defer gpa.free(row_lane);
        @memset(slot_lane, 0);
        @memset(row_lane, 0);
        for (0..n_lanes) |l| for (spans[task_off[l]..task_off[l + 1]]) |s| {
            @memset(slot_lane[s.slot_lo..s.slot_hi], @intCast(l));
            @memset(row_lane[s.row_lo..s.row_hi], @intCast(l));
        };

        const home = try gpa.alloc(u32, n_blocks);
        defer gpa.free(home);
        const votes = try gpa.alloc(u32, n_lanes);
        defer gpa.free(votes);
        for (home, cuts[0..n_blocks], cuts[1..]) |*h, lo, hi| {
            @memset(votes, 0);
            if (lo < nnz) vote(votes, slot_seg, slot_src, slot_lane, lo, @min(hi, nnz));
            if (hi > nnz) vote(votes, row_seg, row_src, row_lane, @max(lo, nnz) - nnz, hi - nnz);
            var best: u32 = 0;
            for (votes, 0..) |v, l| {
                if (v > votes[best]) best = @intCast(l);
            }
            h.* = best;
        }

        // Counting sort of the blocks by home lane, stable.
        const block_off = try gpa.alloc(u32, n_lanes + 1);
        errdefer gpa.free(block_off);
        @memset(block_off, 0);
        for (home) |h| block_off[h + 1] += 1;
        for (1..block_off.len) |i| block_off[i] += block_off[i - 1];
        const block_order = try gpa.alloc(u32, n_blocks);
        errdefer gpa.free(block_order);
        const cursor = try gpa.dupe(u32, block_off[0..n_lanes]);
        defer gpa.free(cursor);
        for (home, 0..) |h, j| {
            block_order[cursor[h]] = @intCast(j);
            cursor[h] += 1;
        }
        assert(block_off[n_lanes] == n_blocks);

        const task_next = try gpa.alloc(Counter, n_lanes);
        errdefer gpa.free(task_next);
        const block_next = try gpa.alloc(Counter, n_lanes);
        errdefer gpa.free(block_next);
        const self: Affinity = .{
            .task_off = task_off,
            .block_off = block_off,
            .block_order = block_order,
            .task_next = task_next,
            .block_next = block_next,
        };
        self.reset();
        return self;
    }

    /// Frees every table.
    pub fn deinit(self: Affinity, gpa: std.mem.Allocator) void {
        gpa.free(self.task_off);
        gpa.free(self.block_off);
        gpa.free(self.block_order);
        gpa.free(self.task_next);
        gpa.free(self.block_next);
    }

    /// Zeroes every claim counter, before a pass is published.
    pub fn reset(self: Affinity) void {
        assert(self.task_next.len == self.block_next.len);
        for (self.task_next, self.block_next) |*a, *b| {
            a.v.store(0, .monotonic);
            b.v.store(0, .monotonic);
        }
    }

    /// The next stamp chunk for `lane`: its own home first, then the other
    /// lanes' in ring order; null once every chunk is claimed.
    pub fn claimTask(self: Affinity, lane: u32) ?u32 {
        return claim(self.task_next, self.task_off, lane);
    }

    /// The next reduce block (an index into the cuts) for `lane`, claimed
    /// as `claimTask` claims chunks.
    pub fn claimBlock(self: Affinity, lane: u32) ?u32 {
        const i = claim(self.block_next, self.block_off, lane) orelse return null;
        return self.block_order[i];
    }
};

/// C7 step 2's census over one index space, slots or rows: of `total`
/// stamps (staging positions in a cell), `single` sit in cells whose every
/// stamp one chunk stages, which that chunk could sum in place.
pub const Census = struct {
    single: u64 = 0,
    total: u64 = 0,
};

/// `Census` of a ParEval's slot and row stamps (`stampCensus`).
pub const StampCensus = struct {
    slots: Census,
    rows: Census,
};

/// Stamp chunks and reduce blocks per lane: enough that a lane on a core
/// half as fast takes about half as many, few enough that claiming costs
/// nothing next to an instance's eval.
pub const chunks_per_lane = 8;
/// Cells per reduce-block cut: 128 bytes of f64, `std.atomic.cache_line` on
/// x86_64 (adjacent-line prefetch pairs 64-byte lines).
pub const block_align = 16;

/// Pause-loop iterations a waiting lane spins under C6 before it parks on a
/// futex, on `epoch` and on the barriers alike, with no yields between.
/// ponytail: 256 is `perf/pareval-idle`'s value (ad27f430, about 15 us on
/// a Raptor Lake P-core); the lever's own runs refit it.
pub const park_spins_short: u32 = 256;

/// An instance's eval cost estimate: its stamp count `n_u^2`, times 16 for
/// a nonlinear model. With `n_u^2` alone, chain_psp103_10k's lane 0 got all
/// 64,244 capacitors and 241 ms of an eval pass that took the PSP103 lanes
/// 5-7 s: a PSP103 instance costs about 1,000 capacitors, not 36. Only the
/// chunk sizes depend on it, never the results.
pub fn instanceWeight(b: Batch) u64 {
    // At least 1: the chunking divides by it, and an instance with no
    // unknowns still costs a call.
    const stamps = @max(@as(u64, b.n_u) * b.n_u, 1);
    return if (b.has_const_jacobian) stamps else 16 * stamps;
}

/// Chunks of about `total / (8 * n_lanes)` instance weight, cut at instance
/// boundaries in ascending order. Caller frees.
pub fn chunkTasks(gpa: std.mem.Allocator, batches: []const Batch, n_lanes: u32) ![]EvalTask {
    var w_total: u64 = 0;
    for (batches) |b| w_total += @as(u64, b.count) * instanceWeight(b);
    const target = @max(w_total / (@as(u64, chunks_per_lane) * n_lanes), 1);
    var tasks: std.ArrayList(EvalTask) = .empty;
    errdefer tasks.deinit(gpa);
    for (batches, 0..) |b, bi| {
        const w = instanceWeight(b);
        const per: u32 = @intCast(@min(@max(target / w, 1), b.count));
        var pos: u32 = 0;
        while (pos < b.count) : (pos += per)
            try tasks.append(gpa, .{ .batch = @intCast(bi), .first = pos, .last = @min(pos + per, b.count) });
    }
    return tasks.toOwnedSlice(gpa);
}

/// Cut points over the combined slot-then-row cells (`[0, nnz + n)`): blocks
/// of about `total / (8 * n_lanes)` work, a cell weighing 1 plus its
/// positions, cut on 16-cell (128-byte) boundaries so no two blocks write
/// one cache line, with a cut at `nnz`. Caller frees.
pub fn cutBlocks(gpa: std.mem.Allocator, slot_seg: []const u32, row_seg: []const u32, n_lanes: u32) ![]u32 {
    const nnz: u32 = @intCast(slot_seg.len - 1);
    const n: u32 = @intCast(row_seg.len - 1);
    const total: u64 = @as(u64, nnz) + n + slot_seg[nnz] + row_seg[n];
    const target = @max(total / (@as(u64, chunks_per_lane) * n_lanes), 1);
    var cuts: std.ArrayList(u32) = .empty;
    errdefer cuts.deinit(gpa);
    try cuts.append(gpa, 0);
    for ([_][]const u32{ slot_seg, row_seg }, [_]u32{ 0, nnz }) |seg, off| {
        const len: u32 = @intCast(seg.len - 1);
        var lo: u32 = 0;
        while (lo < len) {
            var hi = lo;
            var w: u64 = 0;
            while (hi < len and w < target) {
                const step = @min(len - hi, block_align);
                w += step + seg[hi + step] - seg[hi];
                hi += step;
            }
            try cuts.append(gpa, off + hi);
            lo = hi;
        }
    }
    assert(cuts.last() == nnz + n);
    return cuts.toOwnedSlice(gpa);
}

/// N8's tables (`Affinity.build`) from each chunk's staging span
/// (`ParEval.init`). The spans are init scratch. Fails only on allocation.
pub fn buildAffinity(
    gpa: std.mem.Allocator,
    n_lanes: u32,
    batches: []const Batch,
    tasks: []const EvalTask,
    slot_base: []const u32,
    row_base: []const u32,
    slot_tapes: []const []const u32,
    slots: Gather,
    rows: Gather,
    cuts: []const u32,
    n_slot: u32,
    n_row: u32,
) !Affinity {
    assert(slot_base.len == batches.len);
    assert(slot_tapes.len == batches.len);
    const spans = try gpa.alloc(Span, tasks.len);
    defer gpa.free(spans);
    for (spans, tasks) |*s, task| {
        const b = batches[task.batch];
        // Instance-major tapes (`abi.ScatterTapes`): `k` slot and `n_u` row
        // positions per instance. A chunk is never empty, so `count > 0`.
        const k: u32 = @intCast(slot_tapes[task.batch].len / b.count);
        const sb = slot_base[task.batch];
        const rb = row_base[task.batch];
        s.* = .{
            .slot_lo = sb + task.first * k,
            .slot_hi = sb + task.last * k,
            .row_lo = rb + task.first * b.n_u,
            .row_hi = rb + task.last * b.n_u,
        };
    }
    return Affinity.build(gpa, n_lanes, spans, n_slot, n_row, slots.seg, slots.src, rows.seg, rows.src, cuts);
}

/// `Census` of `gather`'s cells, chunk i staging positions `[starts[i],
/// starts[i + 1])`, the last chunk to the end. `starts` ascends from 0; an
/// empty chunk repeats its successor's start. A cell's positions ascend
/// (tape order), so its first and last position decide.
pub fn singleTaskCensus(gather: Gather, starts: []const u32) Census {
    assert(gather.seg.len >= 1);
    assert(gather.src.len == 0 or (starts.len > 0 and starts[0] == 0));
    var c: Census = .{};
    for (gather.seg[0 .. gather.seg.len - 1], gather.seg[1..]) |a, b| {
        if (a == b) continue;
        c.total += b - a;
        if (chunkOf(starts, gather.src[a]) == chunkOf(starts, gather.src[b - 1])) c.single += b - a;
    }
    assert(c.single <= c.total);
    return c;
}

/// C7 step 2's census of ParEval's chunks (`singleTaskCensus` of its slot
/// and row gathers). Each chunk's first positions come from the tape
/// strides: a batch's slot positions split evenly over its instances
/// (instance-major tapes), `n_u` rows each. `n_slot` is the slot staging
/// length. Fails only on allocation; statistics only.
pub fn stampCensus(
    gpa: std.mem.Allocator,
    batches: []const Batch,
    tasks: []const EvalTask,
    slot_base: []const u32,
    row_base: []const u32,
    n_slot: u32,
    slots: Gather,
    rows: Gather,
) !StampCensus {
    assert(slot_base.len == batches.len and row_base.len == batches.len);
    const starts = try gpa.alloc(u32, 2 * tasks.len);
    defer gpa.free(starts);
    const ss = starts[0..tasks.len];
    const rs = starts[tasks.len..];
    for (tasks, ss, rs) |task, *s, *r| {
        const b = batches[task.batch];
        assert(task.first < task.last and task.last <= b.count);
        const end = if (task.batch + 1 < batches.len) slot_base[task.batch + 1] else n_slot;
        s.* = slot_base[task.batch] + task.first * ((end - slot_base[task.batch]) / b.count);
        r.* = row_base[task.batch] + task.first * b.n_u;
    }
    return .{ .slots = singleTaskCensus(slots, ss), .rows = singleTaskCensus(rows, rs) };
}

/// Moves the calling thread onto the performance cores of a hybrid CPU
/// (`/sys/devices/cpu_core/cpus`, Intel's P-core list), leaving it alone
/// elsewhere or on any failure. A worker lane on an E-core stamped PSP103
/// about 2x slower than one on a P-core, and four P-core lanes beat four
/// mixed ones by 1.35-1.38x (dev/devices/gpu-evaluation.md, "Eight host
/// threads"). The lane counts the thread pool hands out stay within the
/// P-core threads, so pinned lanes do not pile onto each other. Only the
/// P-cores the thread may already run on: replacing the mask moved the
/// workers of a run under `taskset -c 0-3` onto cores 0-15 (#248).
pub fn pinToPerformanceCores() void {
    if (comptime builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    const rc = linux.open("/sys/devices/cpu_core/cpus", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [256]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return;
    var set: linux.cpu_set_t = @splat(0);
    var ranges = std.mem.tokenizeAny(u8, buf[0..n], ",\n ");
    while (ranges.next()) |r| {
        var ends = std.mem.splitScalar(u8, r, '-');
        const lo = std.fmt.parseInt(usize, ends.first(), 10) catch return;
        const hi = if (ends.next()) |h| std.fmt.parseInt(usize, h, 10) catch return else lo;
        if (hi < lo or hi >= set.len * @bitSizeOf(usize)) return;
        for (lo..hi + 1) |c| set[c / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(c % @bitSizeOf(usize));
    }
    var allowed: linux.cpu_set_t = undefined;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &allowed)) != .SUCCESS) return;
    for (&set, allowed) |*cpus, a| cpus.* &= a;
    // No allowed P-core (none listed, or a mask of E-cores): stay put.
    if (std.mem.indexOfNone(usize, &set, &.{0}) != null) linux.sched_setaffinity(0, &set) catch {};
}

/// Spins, then yields, until `counter` reaches `target`. `pause` frees
/// issue slots for the SMT sibling that may be running the lane this waits
/// on.
pub fn waitCount(counter: *std.atomic.Value(u32), target: u32) void {
    var spins: u32 = 0;
    while (counter.load(.acquire) < target) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        // Single-threaded never waits here (wasm32-wasi has no sched_yield).
        if (!builtin.single_threaded and spins > 4096) std.Thread.yield() catch {};
    }
}

// ---- private ----

/// Adds one vote per staging position of cells `[lo, hi)` to the home lane
/// that stages it.
fn vote(votes: []u32, seg: []const u32, src: []const u32, lanes: []const u32, lo: usize, hi: usize) void {
    assert(lo <= hi);
    assert(hi < seg.len);
    for (seg[lo..hi], seg[lo + 1 .. hi + 1]) |a, b| for (src[a..b]) |p| {
        votes[lanes[p]] += 1;
    };
}

/// The chunk staging position `p`: the last i with `starts[i] <= p`, so an
/// empty chunk, which shares its successor's start, owns nothing.
fn chunkOf(starts: []const u32, p: u32) usize {
    assert(starts.len > 0 and starts[0] <= p);
    var lo: usize = 0;
    var hi: usize = starts.len;
    // Invariant: starts[lo] <= p, and hi == len or p < starts[hi].
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= p) lo = mid else hi = mid;
    }
    return lo;
}

/// Item `off[l] + next[l]++` for the first lane l, from `lane` in ring
/// order, whose home run is not used up. Each item is handed out once: a
/// counter only grows, and an index past its run is dropped. A lane reads a
/// counter before it increments it, so a used-up run costs a load, not a
/// line taken exclusive.
fn claim(next: []Counter, off: []const u32, lane: u32) ?u32 {
    const n: u32 = @intCast(next.len);
    assert(off.len == next.len + 1);
    assert(lane < n);
    for (0..n) |k| {
        const l = (lane + k) % n;
        const len = off[l + 1] - off[l];
        if (next[l].v.load(.monotonic) >= len) continue;
        const i = next[l].v.fetchAdd(1, .monotonic);
        if (i < len) return off[l] + i;
    }
    return null;
}

test "Gather lists each cell's positions in tape order, ground dropped" {
    const gpa = std.testing.allocator;
    // Two batches over 3 cells, trash = 3.
    const tapes = [_][]const u32{ &.{ 2, 0, 3, 2 }, &.{ 0, 2, 1 } };
    const g = try Gather.build(gpa, &tapes, 3, 3);
    defer g.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 6 }, g.seg);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 6, 0, 3, 5 }, g.src);
    // No cells, or only ground entries: every run is empty.
    for ([_][]const []const u32{ &.{}, &.{&.{ 0, 0 }} }) |only_ground| {
        const e = try Gather.build(gpa, only_ground, 0, 0);
        defer e.deinit(gpa);
        try std.testing.expectEqualSlices(u32, &.{0}, e.seg);
        try std.testing.expectEqual(@as(usize, 0), e.src.len);
    }
}

test "singleTaskCensus counts the stamps of cells one chunk fills" {
    // Oracle: a hand count. Positions 0..8 go to cells 0 1 0 1 2 3 4 3 and
    // ground (6). Chunks: {0,1,2} {3,4} {5,6,7,8}. Cell 0 {0,2}: one chunk,
    // 2 stamps. Cell 1 {1,3}: two chunks. Cell 2 {4}: 1. Cell 3 {5,7}: 2.
    // Cell 4 {6}: 1. Cell 5: none. Ground is no stamp. Single 6 of 8.
    const gpa = std.testing.allocator;
    const tapes = [_][]const u32{&.{ 0, 1, 0, 1, 2, 3, 4, 3, 6 }};
    const g = try Gather.build(gpa, &tapes, 6, 6);
    defer g.deinit(gpa);
    const want: Census = .{ .single = 6, .total = 8 };
    try std.testing.expectEqual(want, singleTaskCensus(g, &.{ 0, 3, 5 }));
    // An empty chunk (a batch with no slots) changes no owner.
    try std.testing.expectEqual(want, singleTaskCensus(g, &.{ 0, 3, 3, 5 }));
    // Position 3 sits exactly on chunk 1's first index, and no other chunk
    // edge compensates: chunks {0,1,2} {3..8}. Cell 0 {0,2}: 2. Cell 1
    // {1,3}: two chunks. Cell 2 {4}: 1. Cell 3 {5,7}: 2. Cell 4 {6}: 1.
    // Single 6 of 8; position 3 put in chunk 0 would make cell 1 single, 8.
    try std.testing.expectEqual(want, singleTaskCensus(g, &.{ 0, 3 }));
    // One chunk: every stamp is single; one chunk per position: only the
    // one-stamp cells 2 and 4.
    try std.testing.expectEqual(Census{ .single = 8, .total = 8 }, singleTaskCensus(g, &.{0}));
    try std.testing.expectEqual(Census{ .single = 2, .total = 8 }, singleTaskCensus(g, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }));
    // No cells.
    const e = try Gather.build(gpa, &.{}, 0, 0);
    defer e.deinit(gpa);
    try std.testing.expectEqual(Census{}, singleTaskCensus(e, &.{}));
}

test "stampCensus starts each chunk at its instance's tape stride" {
    // Oracle: a hand count. One batch, two instances, two slots and one row
    // each, one chunk per instance. Slot positions 0 1 | 2 3 go to cells
    // 0 1 | 1 2: cell 1 spans both chunks, so 2 of 4 are single. Both
    // instances stamp row 0: 0 of 2. A start without the stride (chunk 1 at
    // position 1) would make every slot cell single, 4 of 4.
    const gpa = std.testing.allocator;
    var b: Batch = undefined;
    b.count = 2;
    b.n_u = 1;
    const slot_tapes = [_][]const u32{&.{ 0, 1, 1, 2 }};
    const row_tapes = [_][]const u32{&.{ 0, 0 }};
    const slots = try Gather.build(gpa, &slot_tapes, 3, 3);
    defer slots.deinit(gpa);
    const rows = try Gather.build(gpa, &row_tapes, 1, 1);
    defer rows.deinit(gpa);
    const tasks = [_]EvalTask{ .{ .batch = 0, .first = 0, .last = 1 }, .{ .batch = 0, .first = 1, .last = 2 } };
    const c = try stampCensus(gpa, &.{b}, &tasks, &.{0}, &.{0}, 4, slots, rows);
    try std.testing.expectEqual(Census{ .single = 2, .total = 4 }, c.slots);
    try std.testing.expectEqual(Census{ .single = 0, .total = 2 }, c.rows);
}

test "cutBlocks tiles every cell, 16-aligned, with a cut at nnz" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xb10c);
    const rnd = prng.random();
    for ([_]u32{ 0, 1, 15, 16, 17, 200 }) |nnz| for ([_]u32{ 0, 3, 40 }) |n| for ([_]u32{ 1, 3, 24 }) |lanes| {
        const slot_seg = try gpa.alloc(u32, nnz + 1);
        defer gpa.free(slot_seg);
        const row_seg = try gpa.alloc(u32, n + 1);
        defer gpa.free(row_seg);
        for ([_][]u32{ slot_seg, row_seg }) |seg| {
            seg[0] = 0;
            for (1..seg.len) |i| seg[i] = seg[i - 1] + rnd.uintLessThan(u32, 50);
        }
        const cuts = try cutBlocks(gpa, slot_seg, row_seg, lanes);
        defer gpa.free(cuts);
        try std.testing.expectEqual(@as(u32, 0), cuts[0]);
        try std.testing.expectEqual(nnz + n, cuts[cuts.len - 1]);
        try std.testing.expect(std.mem.indexOfScalar(u32, cuts, nnz) != null);
        for (cuts[0 .. cuts.len - 1], cuts[1..]) |a, b| {
            try std.testing.expect(a < b);
            if (b != nnz and b != nnz + n) try std.testing.expectEqual(@as(u32, 0), (if (b < nnz) b else b - nnz) % block_align);
        }
    };
}

test "chunkTasks covers every instance once, in order" {
    const gpa = std.testing.allocator;
    var bs: [3]Batch = undefined;
    for (&bs, [_]u32{ 1000, 0, 7 }, [_]u32{ 2, 3, 12 }) |*b, count, n_u| {
        b.count = count;
        b.n_u = n_u;
        b.has_const_jacobian = n_u == 2;
    }
    for ([_]u32{ 1, 2, 8, 24 }) |lanes| {
        const tasks = try chunkTasks(gpa, &bs, lanes);
        defer gpa.free(tasks);
        var next = [_]u32{ 0, 0, 0 };
        for (tasks) |task| {
            try std.testing.expectEqual(next[task.batch], task.first);
            try std.testing.expect(task.last > task.first);
            next[task.batch] = task.last;
        }
        try std.testing.expectEqualSlices(u32, &.{ 1000, 0, 7 }, &next);
    }
}

test instanceWeight {
    // A zero-unknown batch still weighs 1, so the chunking never divides by 0.
    var b: Batch = undefined;
    b.n_u = 0;
    b.has_const_jacobian = true;
    try std.testing.expectEqual(@as(u64, 1), instanceWeight(b));
    b.n_u = 3;
    try std.testing.expectEqual(@as(u64, 9), instanceWeight(b));
    b.has_const_jacobian = false;
    try std.testing.expectEqual(@as(u64, 144), instanceWeight(b));
}

test "claim hands out every item once, own run first" {
    const off = [_]u32{ 0, 3, 3, 7 };
    var next: [3]Counter = undefined;
    for (&next) |*c| c.v = .init(0);
    // Lane 1 has no home run: it steals lane 2's first, then lane 0's.
    try std.testing.expectEqual(@as(?u32, 3), claim(&next, &off, 1));
    try std.testing.expectEqual(@as(?u32, 0), claim(&next, &off, 0));
    var seen: [7]bool = @splat(false);
    seen[3] = true;
    seen[0] = true;
    while (claim(&next, &off, 2)) |i| {
        try std.testing.expect(!seen[i]);
        seen[i] = true;
    }
    try std.testing.expectEqualSlices(bool, &@as([7]bool, @splat(true)), &seen);
    try std.testing.expectEqual(@as(?u32, null), claim(&next, &off, 0));
}

test "Affinity homes every block once, on the lane that staged most of it" {
    const gpa = std.testing.allocator;
    // Two chunks over 4 slot positions and 2 row positions; 2 cells of each.
    const spans = [_]Span{
        .{ .slot_lo = 0, .slot_hi = 3, .row_lo = 0, .row_hi = 1 },
        .{ .slot_lo = 3, .slot_hi = 4, .row_lo = 1, .row_hi = 2 },
    };
    // Slot cell 0 <- {0, 1}, cell 1 <- {2, 3}; row cell 0 <- {1}, cell 1 <- {0}.
    const slot_seg = [_]u32{ 0, 2, 4 };
    const slot_src = [_]u32{ 0, 1, 2, 3 };
    const row_seg = [_]u32{ 0, 1, 2 };
    const row_src = [_]u32{ 1, 0 };
    // Blocks: slot cell 0, slot cell 1, row cell 0, row cell 1.
    const cuts = [_]u32{ 0, 1, 2, 3, 4 };
    const a = try Affinity.build(gpa, 2, &spans, 4, 2, &slot_seg, &slot_src, &row_seg, &row_src, &cuts);
    defer a.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, a.task_off);
    // Block 1 ties 1-1 and goes to lane 0; block 2 (row 0 <- position 1) is lane 1's.
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 4 }, a.block_off);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 2 }, a.block_order);
    try std.testing.expectEqual(@as(?u32, 2), a.claimBlock(1));
    try std.testing.expectEqual(@as(?u32, 1), a.claimTask(1));
}
