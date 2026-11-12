//! The host device walks: the serial stamp (`stampRange`), the hook walks
//! (`limitBatches` and friends) and ParEval, the device stamp threaded over
//! persistent worker lanes, bit for bit the serial stamp at any lane count
//! (#137).
//!
//! A pass has two phases. Stamp: lanes claim chunks of instances and each
//! instance stores every stamp at its own position in a staging array
//! (`Hooks.stage`), so no two lanes write one cell. Reduce: lanes claim
//! blocks of plane cells and sum each cell's positions in tape order onto
//! its initial value (zero, or the constant baseline). Tape order is the
//! order the serial stamp adds them in, so every cell rounds as it does
//! serially, whatever the lane count or the chunk a lane happened to claim.
//!
//! Claiming is dynamic, so a slow lane (an E-core beside P-cores) takes fewer
//! chunks instead of holding up the pass. The previous design gave each lane
//! a whole-plane slab and a static instance range: sums regrouped with the
//! lane count (up to 24554 ulp), the slabs cost a plane copy per lane, and
//! the reduce walked every lane's slot window, which a shared rail stretches
//! to the whole plane (#138; dev/analysis/refactoring.md, "ParEval").
//! The serial walks are `host_walks.zig`, re-exported here.
//!
//! Three levers sit beside the shipped path, each read once in `init`
//! (`Levers`): C7 forms `A = G + alpha C` in the reduce, by the lane that
//! just summed the cell's g and c; N8 claims chunks and blocks lane-affine
//! (`par_lanes.Affinity`); C6 parks waiting lanes after a short spin
//! (`par_lanes.Arrivals`). None moves a bit of the planes. N3 tracks the
//! charges of a pass (`Hooks.stage_moved`): each chunk's verdict lands in
//! its own cell, and lane 0 folds them per batch after the pass.
//! In: batches, planes and an iterate. Out: the stamped planes, bitwise the
//! serial stamp.
//! Cites #137, #138, #172, #251, #253; dev/devices/gpu-evaluation.md;
//! docs/perf_research/04-levers-cpu.md (C6, C7), 09-after-the-levers.md (N8).
//!
//! Contents:
//! - `pub const Mode`, `stampRange`, `limitBatches`, `seedBatches`,
//!   `clearLimitBatches`, `updateBatches`, `stateCtlBatches`, `minReject`
//!   (re-exports of `host_walks.zig`)
//! - `pub const Levers = struct`, `pub const FormA = struct`
//! - `pub const ParEval = struct` (`Base`, `init`, `deinit`, `run`, `formsA`,
//!   `setTracking`, `chargesClean`, `census`, `printCensus`, `limit`, `update`,
//!   `each`)
//! - `pub const instanceWeight` (re-export of `par_lanes.zig`)

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const abi = @import("device").abi;
const host_walks = @import("host_walks.zig");
const Companion = @import("tran/integrator.zig").Companion;
const par_lanes = @import("par_lanes.zig");
const EvalTask = par_lanes.EvalTask;
const Gather = par_lanes.Gather;
const waitCount = par_lanes.waitCount;
const chunkTasks = par_lanes.chunkTasks;
const cutBlocks = par_lanes.cutBlocks;
const Batch = abi.Batch;
const Planes = abi.Planes;

/// Which planes a stamp writes (`host_walks.Mode`).
pub const Mode = host_walks.Mode;
/// The serial stamp of one batch's instance range.
pub const stampRange = host_walks.stampRange;
/// The serial hook walks (`host_walks.zig`).
pub const limitBatches = host_walks.limitBatches;
pub const seedBatches = host_walks.seedBatches;
pub const clearLimitBatches = host_walks.clearLimitBatches;
pub const updateBatches = host_walks.updateBatches;
pub const stateCtlBatches = host_walks.stateCtlBatches;
pub const minReject = host_walks.minReject;
/// An instance's eval cost estimate (`par_lanes.instanceWeight`).
pub const instanceWeight = par_lanes.instanceWeight;

/// The ParEval levers under evaluation (`core.perf.Levers`), as the
/// executor reads them off the knobs; all false is the shipped path.
pub const Levers = struct {
    /// Park waiting lanes after `par_lanes.park_spins_short` pauses,
    /// barriers included, with no yields.
    c6: bool = false,
    /// Form `A = G + alpha C` in the reduce (`run`'s `a_alpha`); only on a
    /// circuit with charge.
    c7: bool = false,
    /// Lane-affine claiming of chunks and blocks.
    n8: bool = false,
    /// N3: the per-chunk and per-batch verdict tables `setTracking` needs.
    n3: bool = false,
};

/// What lever C7 has the reduce form beside the planes (`ParEval.run`).
pub const FormA = struct {
    /// `a_vals = G + alpha C`.
    alpha: f64,
    /// The companion term of rows 1 and up; row 0 takes the ground pin
    /// first, so its caller adds it (`Circuit.stamp`). Charge only.
    comp: ?Companion = null,
};

/// Persistent-worker threaded stamp. Owned by the executor for one query;
/// the batch table it was built for must not change shape while it lives.
pub const ParEval = struct {
    gpa: std.mem.Allocator,
    /// Parks idle workers on `epoch` (futex) between passes.
    io: std.Io,
    n_lanes: u32,

    /// Staged stamps, one position per tape entry: every batch's slot
    /// entries back to back (g, c), and its row entries (rhs, q). Each
    /// position holds -0.0 between passes, the additive identity, so one a
    /// pass leaves unstamped adds nothing, not even a sign. c/q are empty
    /// without charge.
    g_stage: []f64,
    c_stage: []f64,
    rhs_stage: []f64,
    q_stage: []f64,
    /// Batch b's first slot and row position.
    slot_base: []u32,
    row_base: []u32,
    slots: Gather,
    rows: Gather,

    /// Stamp chunks, claimed in order through `next_task`.
    tasks: []EvalTask,
    /// Reduce blocks over the cells `[0, nnz + n)`, slots then rows: block j
    /// is `[cuts[j], cuts[j + 1])`, claimed through `next_block`.
    cuts: []u32,

    nnz: u32,
    n: u32,
    has_charge: bool,

    threads: []std.Thread,
    started: bool,
    /// Each counter a lane writes while others read sits alone on its line,
    /// apart from the read-only `job_*` arguments and from each other, so a
    /// claim or barrier increment invalidates only that counter's line (#172).
    wake: Wake,
    next_task: Counter,
    next_block: Counter,
    /// Lanes, lane 0 included, finished stamping the current pass.
    stamped: Arrivals,
    /// Workers finished with the current pass, reduce included.
    done: Arrivals,
    /// N8: the lane-affine claim tables; null claims through `next_task`
    /// and `next_block`.
    aff: ?par_lanes.Affinity,
    /// C6: barriers park (`Arrivals.wait`) and the doorbell parks after
    /// `spin_limit` pauses and `yield_limit` yields.
    park_fast: bool,
    spin_limit: u32,
    yield_limit: u32,
    /// C7: `G + alpha C` of every slot cell, written by the reduce when
    /// `run` gets a `FormA`; empty when the lever is off or there is no
    /// charge. Index `nnz` (trash) stays 0.
    a_vals: []f64,
    /// N3: chunk i's `stage_moved` verdict in the last tracked pass, and
    /// its fold per batch (`chargesClean`); empty without the lever.
    task_moved: []bool,
    batch_moved: []bool,
    /// N3: tracked passes on (`setTracking`), and whether the last pass was
    /// one, so `batch_moved` speaks for the planes and tapes.
    track: bool = false,
    tracked_pass: bool = false,
    job_tracked: bool = false,
    /// The current pass's arguments, published before `epoch` is bumped.
    job_batches: []const Batch,
    job_planes: Planes,
    job_base: Base,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,
    job_form: ?FormA = null,
    job_kind: Kind = .stamp,
    job_x_mut: []f64 = &.{},
    job_x_old: []const f64 = &.{},
    /// `each`'s task count, context and function.
    job_n: u32 = 0,
    job_ctx: *anyopaque = undefined,
    job_f: *const fn (*anyopaque, u32) void = undefined,
    /// The limit pass's OR and the state pass's earliest reject (as f64
    /// bits; reject times are finite, so `@min` order equals bit order
    /// only after the sign check `minBits` does).
    any_limited: std.atomic.Value(bool) = .init(false),
    reject_lock: std.atomic.Mutex = .unlocked,
    min_reject: ?f64 = null,

    /// What a pass runs: the stamp and reduce, or one per-instance walk.
    const Kind = enum { stamp, limit, update, each };

    const Counter = par_lanes.Counter;
    const Arrivals = par_lanes.Arrivals;

    /// The pass doorbell, on its own line. `epoch` is bumped once per pass;
    /// workers spin on it, then park on it. `sleepers` counts workers parked
    /// (or about to park) on `epoch`: `run` pays for the wake syscall only
    /// when it is nonzero. `quit` is read right after `epoch` changes. All
    /// three are written about once per pass, so they share one line.
    const Wake = struct {
        epoch: std.atomic.Value(u32) align(std.atomic.cache_line),
        sleepers: std.atomic.Value(u32),
        quit: std.atomic.Value(bool),
    };

    comptime {
        assert(@sizeOf(Wake) == std.atomic.cache_line);
    }

    /// Initial g and c of every cell: the constant baseline, or empty for
    /// zero.
    pub const Base = struct {
        g: []const f64 = &.{},
        c: []const f64 = &.{},
    };

    /// Builds the staging for `batches` and splits the instances into
    /// chunks of roughly equal `count * instanceWeight` work, about eight
    /// per lane, so a fast lane can take a slow lane's share. Threads start
    /// lazily on the first `run`. `batches` must outlive it; free it with
    /// `deinit`. Plane index `nnz` is the trash slot (`Circuit.trash_slot`),
    /// whose stamps are dropped. Fails with
    /// `error.OutOfMemory` on allocation or when the tapes hold more than
    /// 2^32 positions. A single-threaded build runs one lane. `levers`
    /// picks the paths (`Levers`); N8 builds its tables here, once.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        batches: []const Batch,
        nnz: u32,
        n: u32,
        has_charge: bool,
        n_lanes_req: u32,
        levers: Levers,
    ) !ParEval {
        // Single-threaded (wasm): one lane whatever `n_lanes_req` asks.
        const n_lanes: u32 = if (builtin.single_threaded) 1 else @max(n_lanes_req, 1);

        const slot_base = try gpa.alloc(u32, batches.len);
        errdefer gpa.free(slot_base);
        const row_base = try gpa.alloc(u32, batches.len);
        errdefer gpa.free(row_base);
        const slot_tapes = try gpa.alloc([]const u32, batches.len);
        defer gpa.free(slot_tapes);
        const row_tapes = try gpa.alloc([]const u32, batches.len);
        defer gpa.free(row_tapes);
        var n_slot: u64 = 0;
        var n_row: u64 = 0;
        for (batches, slot_base, row_base, slot_tapes, row_tapes) |b, *sb, *rb, *st, *rt| {
            const tapes = b.hooks.scatter_tapes(b.ctx);
            assert(tapes.rows.len == @as(usize, b.count) * b.n_u);
            st.* = tapes.slots;
            rt.* = tapes.rows;
            sb.* = std.math.cast(u32, n_slot) orelse return error.OutOfMemory;
            rb.* = std.math.cast(u32, n_row) orelse return error.OutOfMemory;
            n_slot += tapes.slots.len;
            n_row += tapes.rows.len;
        }
        // Positions are u32, like the tapes; past that the staging alone
        // would need 32 GB per plane.
        if (n_slot > std.math.maxInt(u32) or n_row > std.math.maxInt(u32)) return error.OutOfMemory;
        const slot_len: usize = @intCast(n_slot);
        const row_len: usize = @intCast(n_row);

        const slots = try Gather.build(gpa, slot_tapes, nnz, nnz);
        errdefer slots.deinit(gpa);
        const rows = try Gather.build(gpa, row_tapes, n, n);
        errdefer rows.deinit(gpa);

        const g_stage = try gpa.alloc(f64, slot_len);
        errdefer gpa.free(g_stage);
        const rhs_stage = try gpa.alloc(f64, row_len);
        errdefer gpa.free(rhs_stage);
        const c_stage = try gpa.alloc(f64, if (has_charge) slot_len else 0);
        errdefer gpa.free(c_stage);
        const q_stage = try gpa.alloc(f64, if (has_charge) row_len else 0);
        errdefer gpa.free(q_stage);
        for ([_][]f64{ g_stage, rhs_stage, c_stage, q_stage }) |st| @memset(st, -0.0);

        const tasks = try chunkTasks(gpa, batches, n_lanes);
        errdefer gpa.free(tasks);
        const cuts = try cutBlocks(gpa, slots.seg, rows.seg, n_lanes);
        errdefer gpa.free(cuts);

        const aff: ?par_lanes.Affinity = if (levers.n8 and n_lanes > 1)
            try par_lanes.buildAffinity(gpa, n_lanes, batches, tasks, slot_base, row_base, slot_tapes, slots, rows, cuts, @intCast(slot_len), @intCast(row_len))
        else
            null;
        errdefer if (aff) |a| a.deinit(gpa);
        const a_vals = try gpa.alloc(f64, if (levers.c7 and has_charge) @as(usize, nnz) + 1 else 0);
        errdefer gpa.free(a_vals);
        @memset(a_vals, 0);
        const task_moved = try gpa.alloc(bool, if (levers.n3) tasks.len else 0);
        errdefer gpa.free(task_moved);
        const batch_moved = try gpa.alloc(bool, if (levers.n3) batches.len else 0);
        errdefer gpa.free(batch_moved);
        @memset(task_moved, false);
        @memset(batch_moved, true);

        const threads = try gpa.alloc(std.Thread, n_lanes - 1);
        errdefer gpa.free(threads);

        return .{
            .gpa = gpa,
            .io = io,
            .n_lanes = n_lanes,
            .g_stage = g_stage,
            .c_stage = c_stage,
            .rhs_stage = rhs_stage,
            .q_stage = q_stage,
            .slot_base = slot_base,
            .row_base = row_base,
            .slots = slots,
            .rows = rows,
            .tasks = tasks,
            .cuts = cuts,
            .nnz = nnz,
            .n = n,
            .has_charge = has_charge,
            .threads = threads,
            .started = false,
            .wake = .{ .epoch = .init(0), .sleepers = .init(0), .quit = .init(false) },
            .next_task = .{ .v = .init(0) },
            .next_block = .{ .v = .init(0) },
            .stamped = .zero,
            .done = .zero,
            .aff = aff,
            .park_fast = levers.c6,
            .spin_limit = if (levers.c6) par_lanes.park_spins_short else park_spins,
            .yield_limit = if (levers.c6) 0 else park_yields,
            .a_vals = a_vals,
            .task_moved = task_moved,
            .batch_moved = batch_moved,
            .job_batches = batches,
            .job_planes = undefined,
            .job_base = .{},
            .job_x = &.{},
            .job_t = 0,
            .job_mode = .full,
        };
    }

    /// Stops and joins the workers, then frees every table.
    pub fn deinit(self: *ParEval) void {
        if (self.started) {
            self.wake.quit.store(true, .release);
            _ = self.wake.epoch.fetchAdd(1, .seq_cst);
            self.io.futexWake(u32, &self.wake.epoch.raw, std.math.maxInt(u32));
            for (self.threads) |th| th.join();
        }
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.free(self.g_stage);
        gpa.free(self.c_stage);
        gpa.free(self.rhs_stage);
        gpa.free(self.q_stage);
        gpa.free(self.slot_base);
        gpa.free(self.row_base);
        self.slots.deinit(gpa);
        self.rows.deinit(gpa);
        gpa.free(self.tasks);
        gpa.free(self.cuts);
        if (self.aff) |a| a.deinit(gpa);
        gpa.free(self.a_vals);
        gpa.free(self.task_moved);
        gpa.free(self.batch_moved);
        self.* = undefined;
    }

    /// Sets every cell of the planes `mode` writes to its value in `base`
    /// (`.newton` only; zero otherwise) plus every batch's stamps at `x`, and
    /// waits for all lanes. `planes` need no clearing first. Spawns the
    /// workers on first use; a failed spawn panics. `.charge` on a circuit
    /// without charge is a no-op: there is no q plane. Asserts that
    /// `batches` has as many batches as `init` saw and that `base` is empty
    /// outside `.newton`. With `form` (C7, `formsA` only, never `.charge`)
    /// the reduce also writes `a_vals[i] = g[i] + alpha * c[i]` for every
    /// slot cell, the expression `Circuit.combinePlanes` rounds, from the g
    /// and c it just wrote, and adds `form.comp` to rows 1 and up from the
    /// rhs and q it just wrote; a stamp the caller adds after `run` (the
    /// ground pin) is its to re-form. Under `setTracking` a `.full` or
    /// `.newton` pass records its charge verdict (`chargesClean`).
    pub fn run(self: *ParEval, batches: []const Batch, planes: Planes, base: Base, x: []const f64, t: f64, mode: Mode, form: ?FormA) void {
        if (mode == .charge and !self.has_charge) return;
        assert(batches.len == self.slot_base.len);
        assert(mode == .newton or (base.g.len == 0 and base.c.len == 0));
        if (form) |f| assert(self.formsA() and mode != .charge and (f.comp == null or self.has_charge));
        self.job_form = form;
        self.job_tracked = self.track and mode != .charge;
        self.job_batches = batches;
        self.job_planes = planes;
        self.job_base = base;
        self.job_x = x;
        self.job_t = t;
        self.job_mode = mode;
        self.job_kind = .stamp;
        self.next_task.v.store(0, .monotonic);
        self.next_block.v.store(0, .monotonic);
        self.stamped.v.store(0, .monotonic);
        self.done.v.store(0, .monotonic);
        if (self.aff) |a| a.reset();
        self.ring();
        self.pass(0);
        self.awaitDone();
        if (self.track) self.foldMoved();
        // The trash cells take no stamps here; give them their initial value.
        switch (mode) {
            .charge => planes.q_vec[self.n] = 0,
            inline else => |m| {
                planes.g_vals[self.nnz] = if (m == .newton and base.g.len > 0) base.g[self.nnz] else 0;
                planes.rhs[self.n] = 0;
                if (self.has_charge) {
                    planes.c_vals[self.nnz] = if (m == .newton and base.c.len > 0) base.c[self.nnz] else 0;
                    planes.q_vec[self.n] = 0;
                }
            },
        }
    }

    /// Whether C7 is armed: `run` may take a `FormA`.
    pub fn formsA(self: *const ParEval) bool {
        return self.a_vals.len > 0;
    }

    /// N3: turns tracked passes on or off, as `Hooks.track_charges` does
    /// per batch; the caller turns both on together. Asserts that `init`
    /// built the verdict tables (`Levers.n3`).
    pub fn setTracking(self: *ParEval, on: bool) void {
        assert(!on or self.task_moved.len == self.tasks.len);
        assert(self.batch_moved.len == self.slot_base.len or !on);
        self.track = on;
        self.tracked_pass = false;
    }

    /// N3: whether batch `bi`'s ranges in the last pass, tracked, all left
    /// `eval_q`'s charges in the planes and the tape: the conjunction of
    /// every chunk's `stage_moved` verdict, folded after the pass. False
    /// after an untracked or `.charge` pass. The batch's own `charges_clean`
    /// still has to agree (`circuit_devices.acceptStates`).
    pub fn chargesClean(self: *const ParEval, bi: usize) bool {
        assert(!self.tracked_pass or bi < self.batch_moved.len);
        return self.tracked_pass and !self.batch_moved[bi];
    }

    /// C7 step 2's census of this ParEval's chunks (`par_lanes.stampCensus`).
    /// Fails only on allocation.
    pub fn census(self: *const ParEval) !par_lanes.StampCensus {
        return par_lanes.stampCensus(self.gpa, self.job_batches, self.tasks, self.slot_base, self.row_base, @intCast(self.g_stage.len), self.slots, self.rows);
    }

    /// `census` as one `pareval-census:` line on stderr, under
    /// `ZP_TRAN_STATS` (the executor's call); nothing when its scratch
    /// cannot be allocated. Changes no value.
    pub fn printCensus(self: *const ParEval) void {
        const c = self.census() catch return;
        std.debug.print("pareval-census: lanes={d} chunks={d} single-task stamps slots={d}/{d} rows={d}/{d}\n", .{ self.n_lanes, self.tasks.len, c.slots.single, c.slots.total, c.rows.single, c.rows.total });
    }

    /// Folds the chunks' verdicts per batch, in chunk order, after a pass.
    fn foldMoved(self: *ParEval) void {
        assert(self.task_moved.len == self.tasks.len);
        self.tracked_pass = self.job_tracked;
        if (!self.job_tracked) return;
        @memset(self.batch_moved, false);
        for (self.tasks, self.task_moved) |task, m| {
            if (m) self.batch_moved[task.batch] = true;
        }
    }

    /// `limitBatches` over the lanes: each chunk limits its instances, a
    /// batch without `limit_range` runs whole in its first chunk, and every
    /// batch's limiting is armed once all chunks are done. Bitwise the
    /// serial walk: instances write only their own lim cells.
    pub fn limit(self: *ParEval, batches: []const Batch, x: []f64, x_old: []const f64) bool {
        self.job_batches = batches;
        self.job_x_mut = x;
        self.job_x_old = x_old;
        self.any_limited.store(false, .monotonic);
        self.walk(.limit);
        for (batches) |b| if (b.hooks.limit_range != null) if (b.hooks.arm_limits) |f| f(b.ctx);
        return self.any_limited.load(.monotonic);
    }

    /// `updateBatches` over the lanes; the earliest reject of any instance.
    pub fn update(self: *ParEval, batches: []const Batch, x: []const f64) ?f64 {
        self.job_batches = batches;
        self.job_x = x;
        self.min_reject = null;
        self.walk(.update);
        for (batches) |b| if (b.hooks.update_range != null) if (b.hooks.update_done) |f| f(b.ctx);
        return self.min_reject;
    }

    /// Calls `f(ctx, i)` once for every i below `n`, tasks claimed in order
    /// on any lane, and returns when all are done. `f` writes only what
    /// task i owns (N7's bound chunks, `tran/bound_lanes.zig`).
    pub fn each(self: *ParEval, n: u32, ctx: *anyopaque, f: *const fn (*anyopaque, u32) void) void {
        assert(n >= 1);
        self.job_n = n;
        self.job_ctx = ctx;
        self.job_f = f;
        self.walk(.each);
        assert(self.next_task.v.load(.monotonic) >= n);
    }

    fn walk(self: *ParEval, kind: Kind) void {
        self.job_kind = kind;
        self.next_task.v.store(0, .monotonic);
        self.done.v.store(0, .monotonic);
        self.ring();
        self.walkPass();
        self.awaitDone();
    }

    /// Lane 0 waits for every worker to finish the pass: parked under C6,
    /// spinning otherwise.
    fn awaitDone(self: *ParEval) void {
        if (self.park_fast) self.done.wait(self.io, self.n_lanes - 1) else waitCount(&self.done.v, self.n_lanes - 1);
    }

    /// Starts the workers on first use, then bumps `epoch` so they run the
    /// pass just published, paying for the wake only when one is parked.
    fn ring(self: *ParEval) void {
        // Comptime-false single-threaded, so `startWorkers` never compiles there.
        if (!builtin.single_threaded and self.n_lanes > 1) {
            if (!self.started) self.startWorkers();
            // seq_cst pairs with the worker's `sleepers` increment and epoch
            // re-check: either it sees the new epoch or this sees it parking.
            _ = self.wake.epoch.fetchAdd(1, .seq_cst);
            if (self.wake.sleepers.load(.seq_cst) != 0)
                self.io.futexWake(u32, &self.wake.epoch.raw, std.math.maxInt(u32));
        }
    }

    /// One lane's share of a limit or update pass.
    fn walkPass(self: *ParEval) void {
        if (self.job_kind == .each) {
            while (true) {
                const i = self.next_task.v.fetchAdd(1, .monotonic);
                if (i >= self.job_n) return;
                self.job_f(self.job_ctx, i);
            }
        }
        var limited = false;
        var reject: ?f64 = null;
        while (true) {
            const i = self.next_task.v.fetchAdd(1, .monotonic);
            if (i >= self.tasks.len) break;
            const task = self.tasks[i];
            const b = self.job_batches[task.batch];
            switch (self.job_kind) {
                .limit => if (b.hooks.limit_range) |f| {
                    if (f(b.ctx, self.job_x_mut, self.job_x_old, task.first, task.last)) limited = true;
                } else if (task.first == 0) if (b.hooks.apply_limits) |f| {
                    if (f(b.ctx, self.job_x_mut, self.job_x_old)) limited = true;
                },
                .update => {
                    const tr = if (b.hooks.update_range) |f|
                        f(b.ctx, self.job_x, task.first, task.last)
                    else if (task.first == 0) if (b.hooks.update_state) |f| f(b.ctx, self.job_x) else null else null;
                    if (tr) |t| reject = if (reject) |cur| @min(cur, t) else t;
                },
                .stamp, .each => unreachable,
            }
        }
        if (limited) self.any_limited.store(true, .monotonic);
        if (reject) |t| {
            while (!self.reject_lock.tryLock()) std.atomic.spinLoopHint();
            defer self.reject_lock.unlock();
            self.min_reject = if (self.min_reject) |cur| @min(cur, t) else t;
        }
    }

    fn startWorkers(self: *ParEval) void {
        const epoch0 = self.wake.epoch.load(.acquire);
        for (self.threads, 1..) |*th, lane| {
            th.* = std.Thread.spawn(.{ .stack_size = @import("worker.zig").stack_size }, workerMain, .{ self, epoch0, @as(u32, @intCast(lane)) }) catch
                @panic("ParEval: worker spawn failed");
        }
        self.started = true;
    }

    fn workerMain(self: *ParEval, epoch0: u32, lane: u32) void {
        par_lanes.pinToPerformanceCores();
        assert(lane >= 1 and lane < self.n_lanes);
        const spin_limit = self.spin_limit;
        const yield_limit = self.yield_limit;
        var last: u32 = epoch0;
        while (true) {
            var spins: u32 = 0;
            var e = self.wake.epoch.load(.acquire);
            while (e == last) {
                if (spins < spin_limit) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else if (spins < spin_limit + yield_limit) {
                    std.Thread.yield() catch {};
                    spins += 1;
                } else {
                    // Spinning (or `yield`, which returns at once on an idle
                    // core) through the host solve kept every worker at
                    // 100% CPU. The futex rechecks `epoch == last` itself.
                    _ = self.wake.sleepers.fetchAdd(1, .seq_cst);
                    if (self.wake.epoch.load(.seq_cst) == last)
                        self.io.futexWaitUncancelable(u32, &self.wake.epoch.raw, last);
                    _ = self.wake.sleepers.fetchSub(1, .seq_cst);
                }
                e = self.wake.epoch.load(.acquire);
            }
            last = e;
            if (self.wake.quit.load(.acquire)) return;
            if (self.job_kind == .stamp) self.pass(lane) else self.walkPass();
            if (self.park_fast) self.done.arrive(self.io, self.n_lanes - 1) else _ = self.done.v.fetchAdd(1, .release);
        }
    }

    /// One lane's share of a pass: claim stamp chunks until none are left,
    /// wait for every lane to finish stamping, then claim reduce blocks.
    /// `lane` is 0 for the caller of `run`, the worker's index otherwise.
    fn pass(self: *ParEval, lane: u32) void {
        assert(lane < self.n_lanes);
        const mode = self.job_mode;
        const tracked = self.job_tracked;
        while (self.claimTask(lane)) |i| {
            const task = self.tasks[i];
            const b = self.job_batches[task.batch];
            const sb = self.slot_base[task.batch];
            const rb = self.row_base[task.batch];
            const pl: Planes = .{
                .g_vals = self.g_stage[sb..],
                .c_vals = if (self.has_charge) self.c_stage[sb..] else &.{},
                .rhs = self.rhs_stage[rb..],
                .q_vec = if (self.has_charge) self.q_stage[rb..] else &.{},
            };
            // N3: each chunk's verdict in its own cell, no lane shares one.
            if (tracked) if (b.hooks.stage_moved) |f| {
                self.task_moved[i] = f(b.ctx, &pl, task.first, task.last, self.job_x, self.job_t, mode);
                continue;
            } else {
                self.task_moved[i] = false;
            };
            b.hooks.stage(b.ctx, &pl, task.first, task.last, self.job_x, self.job_t, mode);
        }
        if (self.park_fast) {
            self.stamped.arrive(self.io, self.n_lanes);
            self.stamped.wait(self.io, self.n_lanes);
        } else {
            _ = self.stamped.v.fetchAdd(1, .acq_rel);
            waitCount(&self.stamped.v, self.n_lanes);
        }
        while (self.claimBlock(lane)) |j| {
            const lo = self.cuts[j];
            const hi = self.cuts[j + 1];
            switch (mode) {
                inline else => |m| self.reduceBlock(lo, hi, m),
            }
        }
    }

    /// The next stamp chunk: lane-affine under N8, else the shared counter.
    fn claimTask(self: *ParEval, lane: u32) ?u32 {
        if (self.aff) |a| return a.claimTask(lane);
        const i = self.next_task.v.fetchAdd(1, .monotonic);
        return if (i < self.tasks.len) i else null;
    }

    /// The next reduce block, claimed as `claimTask` claims chunks.
    fn claimBlock(self: *ParEval, lane: u32) ?u32 {
        if (self.aff) |a| return a.claimBlock(lane);
        const j = self.next_block.v.fetchAdd(1, .monotonic);
        return if (j < self.cuts.len - 1) j else null;
    }

    /// Reduces cells `[lo, hi)` of the combined slot-then-row index.
    fn reduceBlock(self: *ParEval, lo: u32, hi: u32, comptime mode: Mode) void {
        const pl = self.job_planes;
        if (lo < self.nnz and mode != .charge) {
            const end = @min(hi, self.nnz);
            const bg: []const f64 = if (mode == .newton) self.job_base.g else &.{};
            sumCells(self.slots, lo, end, pl.g_vals, self.g_stage, bg);
            if (self.has_charge) {
                const bc: []const f64 = if (mode == .newton) self.job_base.c else &.{};
                sumCells(self.slots, lo, end, pl.c_vals, self.c_stage, bc);
                // C7: the cells this lane just summed, still in its cache.
                if (self.job_form) |f| {
                    for (self.a_vals[lo..end], pl.g_vals[lo..end], pl.c_vals[lo..end]) |*a, g, c| a.* = g + f.alpha * c;
                }
            }
        }
        if (hi > self.nnz) {
            const r0 = @max(lo, self.nnz) - self.nnz;
            const r1 = hi - self.nnz;
            if (mode != .charge) sumCells(self.rows, r0, r1, pl.rhs, self.rhs_stage, &.{});
            if (self.has_charge) sumCells(self.rows, r0, r1, pl.q_vec, self.q_stage, &.{});
            // C7: the companion of the rows this lane just summed; row 0
            // waits for the ground pin (`FormA.comp`).
            if (mode != .charge) if (self.job_form) |f| if (f.comp) |comp| {
                const first = @max(r0, 1);
                if (first < r1) comp.applyRows(pl.rhs, pl.q_vec, first, r1);
            };
        }
    }
};

/// Pause-loop iterations a worker spins on `epoch` before it parks: long
/// enough to catch the next pass across a short solve, short enough that a
/// long LU solve does not burn the cores.
const park_spins: u32 = 4096;
const park_yields: u32 = 64;

// ---- private ----

/// `plane[i] = base[i] + stage[p0] + stage[p1] + ...` over cell i's
/// positions in tape order, left to right, for cells `[lo, hi)`; an empty
/// `base` is zero. Resets each position read to -0.0 for the next pass.
fn sumCells(gather: Gather, lo: u32, hi: u32, plane: []f64, stage: []f64, base: []const f64) void {
    for (lo..hi) |i| {
        var v: f64 = if (base.len > 0) base[i] else 0;
        for (gather.src[gather.seg[i]..gather.seg[i + 1]]) |p| {
            v += stage[p];
            stage[p] = -0.0;
        }
        plane[i] = v;
    }
}

test {
    _ = par_lanes;
}
