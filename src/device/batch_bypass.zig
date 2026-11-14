//! The latency bypass of one device batch: a Newton iterate's limited
//! unknowns in, either the instance's recorded stamps replayed to first
//! order or a fresh, recorded evaluation out. Opt-in (`Hooks.set_bypass`):
//! it moves values within the Newton tolerance. Cites SPICE's bypass test
//! (the unknowns and the predicted current both within tolerance) and the
//! hand-kept model list `traits.bypass_models`. The C4 lever
//! (`BypassTol.c4`, docs/perf_research/04-levers-cpu.md) judges the hit
//! rate per window of transient steps and re-arms a batch it turned off,
//! and replays a step's first iterate for a model that does not read the
//! iteration (VerA's `sim_reads`), and keys a recording on the row minus
//! the fields that reach only a charge value (`traits.chargeOnlyFields`);
//! off, the shipped bypass bit for bit. `BypassTol.hold` (`c4h`,
//! measurement only) keeps a C4 batch on whatever its windows show. `BypassTol.stats` counts each
//! batch's evaluations by outcome and prints them when the batch frees its
//! bypass (`bypass-stats:`).
//!
//! Contents:
//! - `pub fn Bypass(comptime D: type) type`: the per-batch record (`tol`,
//!   `ref`, `meta`, `inst`, `cells`, `vals`, `rows`, `cols`, `hits`,
//!   `misses`, `off`, `rearm_in`, `offs`, `census`) with `Census`,
//!   `bypassable`, `c4_only`, `rec_cap`, `review`, `countPlain`,
//!   `setBypass`, `freeBypass`, `evalBypass`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const abi = @import("device_abi");
const dual = @import("dual.zig");
const layout = @import("layout.zig");
const stamp = @import("stamp.zig");
const traits = @import("traits.zig");
const sink_mod = @import("sink.zig");
const staging_gpa = @import("proto_store.zig").staging_gpa;
const DeviceBatch = @import("batch.zig").DeviceBatch;
const Planes = abi.Planes;
const SimState = abi.SimState;
const RecordCap = sink_mod.RecordCap;
const RecordSink = sink_mod.RecordSink;

/// Per instance of `DeviceBatch(D)`: the limited unknowns and the writes of
/// its last full Newton evaluation, and what that evaluation depended on.
/// Lives on `staging_gpa`, like every buffer a worker thread may create.
pub fn Bypass(comptime D: type) type {
    const n_u: usize = contract.nU(D);
    const has_q = @hasDecl(D, "q");
    const has_limit = @hasDecl(D, "limit");
    return struct {
        tol: abi.BypassTol,
        /// `count * n_u`: each instance's limited unknowns at its recording.
        ref: []f64,
        /// `count`: what each recording depends on; `class` 0 is none.
        meta: []Meta,
        /// `count * @sizeOf(D.Instance)`: each instance's bytes at its
        /// recording, which hold latched and held values. `State` is
        /// `updateState`'s staging, which `eval` never reads.
        inst: []u8,
        /// `RecordSink`'s columns, `count *` `cells_len`, `cells_len`,
        /// `rec_cap.res + rec_cap.jac` and `rec_cap.jac`.
        cells: []*f64,
        vals: []f64,
        rows: []u8,
        cols: []u8,
        /// Instance evaluations that replayed and that evaluated, summed
        /// over ParEval's lanes; read between solves (`setSimState`).
        /// usize: wasm32 has no 64-bit atomics.
        // ponytail: wraps after 2^32 evaluations on 32-bit targets, which
        // only skews `review`'s ratio there; u64 again if that matters.
        hits: std.atomic.Value(usize) = .init(0),
        misses: std.atomic.Value(usize) = .init(0),
        /// Set once the hit rate proved too low to pay for recording: the
        /// batch evaluates plainly for the rest of the run.
        off: bool = false,
        /// C4 only: reviews left before a batch that was turned off probes
        /// again; 0 while on.
        rearm_in: u32 = 0,
        /// C4 only: how many times a window turned the batch off; each
        /// turn-off doubles the next backoff, so a model whose hits never
        /// pay is re-armed O(log(reviews)) times, not once per backoff.
        offs: u8 = 0,
        /// `BypassTol.stats` only: counts per `Census` tag, summed over
        /// ParEval's lanes.
        census: [n_census]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0)),

        /// What `census` counts. `evals`: every instance evaluation the
        /// bypass saw, first iterates included; a miss that is neither a
        /// byte nor a tolerance miss (a limiter correction, no recording, a
        /// class or plane change) is the rest of `evals`. A hit's cost, for
        /// C4's break-even rate from a profile: `replay_writes`, the plane
        /// entries the replays wrote (residual, G and C), and
        /// `charge_reads`, the charge evaluations they ran.
        /// `plain`: instance evaluations of the batch while its bypass was
        /// off (`countPlain`, per pass), so `evals + plain` is every
        /// evaluation the batch made with a bypass allocated. `windows`:
        /// C4 windows judged; `under_5th` and `under_14th`: of those, the
        /// ones with hits under one in five (the review's rule) and under
        /// one in fourteen, counted whether or not the window turned the
        /// batch off.
        pub const Census = enum(u8) { evals, replays, byte_misses, tol_misses, first_replays, windows_off, rearmed, replay_writes, charge_reads, plain, windows, under_5th, under_14th };
        const n_census = @typeInfo(Census).@"enum".field_names.len;

        const Bp = @This();
        const Batch = DeviceBatch(D);
        /// A recording's iteration class (0: none), its segment lengths,
        /// and the key of the planes its cells address.
        const Meta = struct { class: u16 = 0, n_res: u16 = 0, n_jac: u16 = 0, n_qjac: u16 = 0, plane: u64 = 0 };

        /// Whether a Newton evaluation of D is a pure function of the
        /// instance's limited unknowns, its bytes and the iteration class:
        /// no time-dependent stimulus, no Newton history, no evaluation that
        /// writes the instance beyond a status latch, and not a constant
        /// Jacobian (whose evaluation costs less than a replay).
        pub const bypassable = !(@hasDecl(D, "nextBreakpoint") and traits.skipsTimerState(D)) and
            !traits.hasSpiceBreaks(D) and !traits.skipsTimerState(D) and
            !@hasDecl(D, "advanceIteration") and !@hasDecl(D, "checkConvergence") and
            !(@hasDecl(D, "mutable_eval") and D.mutable_eval and !traits.statusOnlyMutable(D)) and
            !(@hasDecl(D, "constant") and D.constant.g) and (@hasDecl(D, "u_kinds") or c4_only) and
            @sizeOf(D.Instance) <= 4096 and (traits.bypass_models.has(traits.baseName(D)) or c4_only);
        /// Whether D bypasses with the C4 lever on only
        /// (`traits.bypass_models_c4`): with it off the batch never arms.
        pub const c4_only = traits.bypass_models_c4.has(traits.baseName(D));

        /// Upper bounds on one instance's recorded writes in a Newton pass:
        /// one residual per written row, its row's pattern entries, and the
        /// charge rows' pattern entries.
        pub const rec_cap: RecordCap = blk: {
            @setEvalBranchQuota(100_000);
            const jp = layout.rowPattern(D, "jac_pattern");
            const jr = layout.writtenRows(D, "jac_rows");
            var c: RecordCap = .{ .res = 0, .jac = 0, .qjac = 0 };
            for (0..n_u) |ru| if (jr[ru]) {
                c.res += 1;
                c.jac += @popCount(jp[ru]);
            };
            if (has_q) {
                const qp = layout.rowPattern(D, "q_pattern");
                const qr = layout.writtenRows(D, "q_rows");
                for (0..n_u) |ru| if (qr[ru]) {
                    c.qjac += @popCount(qp[ru]);
                };
            }
            break :blk c;
        };
        const cells_len = rec_cap.res + rec_cap.jac + rec_cap.qjac;
        const rows_len = rec_cap.res + rec_cap.jac;
        const res_rows = layout.writtenRows(D, "jac_rows");
        /// C4: whether a step's first iterate may replay and record. A model
        /// that reads `$simparam("iteration")` (the Meyer MOS levels) branches
        /// on it, and the class does not key on it.
        const replays_first = !contract.simReads(D).iteration;

        // C4's review (`reviewWindow`). Provisional, all three.
        // ponytail: one in five is a guess; the measurement that fits it is
        // the break-even hit rate, a miss's cost with the bypass on (the
        // recording) over a plain evaluation's cost, per model. The window
        // and the backoff fit from how many steps a latent phase lasts after
        // an active one on bench_ngspice_mosamp and the BSIM4 1k decks.
        /// Evaluations per instance one window judges.
        const window_evals: u64 = 4;
        /// A window turns the batch off when hits * this < evaluations.
        const break_even_den: u64 = 5;
        /// Reviews (solves) an off batch waits before it probes again the
        /// first time; the wait doubles at each later turn-off.
        const backoff_reviews: u32 = 64;
        /// Doublings past which the wait stays put: 64 << 25 = 2^31 fits u32.
        const max_doublings: u8 = 25;

        /// C4's key: the byte spans of `D.Instance` outside
        /// `traits.chargeOnlyFields(D)`, ascending; null when that list is
        /// empty and the whole row keys.
        const key_spans: ?[]const [2]usize = blk: {
            const names = traits.chargeOnlyFields(D);
            if (names.len == 0) break :blk null;
            @setEvalBranchQuota(20_000 + 100 * @sizeOf(D.Instance));
            var skip: [@sizeOf(D.Instance)]bool = @splat(false);
            for (names) |name| {
                if (!@hasField(D.Instance, name)) @compileError(@typeName(D) ++ ".Instance has no field " ++ name ++ " (traits.charge_only)");
                const at = @offsetOf(D.Instance, name);
                for (at..at + @sizeOf(@FieldType(D.Instance, name))) |i| skip[i] = true;
            }
            var spans: []const [2]usize = &.{};
            var i: usize = 0;
            while (i < skip.len) {
                if (skip[i]) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < skip.len and !skip[i]) i += 1;
                spans = spans ++ [_][2]usize{.{ start, i }};
            }
            const final = spans[0..spans.len].*;
            break :blk &final;
        };

        comptime {
            // Local rows and columns ride in u8, a segment length in u16.
            if (bypassable) assert(n_u <= 256);
            if (bypassable) assert(cells_len <= std.math.maxInt(u16));
        }

        /// Turns the bypass off once, after four evaluations per instance, a
        /// batch replays under one in five: it pays the recording for
        /// nothing (a BSIM4 whose instance bytes move every step: 3%; a CMOS
        /// chain: 85%).
        /// With the C4 lever on, `reviewWindow` decides instead.
        pub fn review(bp: *Bp, count: u32) void {
            if (bp.tol.c4) return reviewWindow(bp, count);
            if (bp.off) return;
            const h = bp.hits.load(.monotonic);
            const total = h + bp.misses.load(.monotonic);
            if (total < 4 * @as(u64, count)) return;
            if (h * 5 < total) {
                bp.off = true;
                if (bp.tol.stats) bp.tally(.windows_off, 1);
            }
        }

        /// Counts `n` instance evaluations the batch made plainly while its
        /// bypass was off (`Census.plain`); statistics only.
        pub inline fn countPlain(bp: *Bp, n: usize) void {
            assert(bp.off);
            if (bp.tol.stats) bp.tally(.plain, n);
        }

        /// `Hooks.set_bypass`: sets the tolerances, clearing every
        /// recording, or frees the bypass when `tol` is null. Best effort:
        /// out of memory leaves the batch evaluating plainly.
        pub fn setBypass(ctx: *anyopaque, tol: ?abi.BypassTol) void {
            const self = Batch.of(ctx);
            if (comptime !bypassable) return;
            if (comptime c4_only) if (tol == null or !tol.?.c4) return freeBypass(self);
            if (self.bypass) |bp| {
                bp.tol = tol orelse return freeBypass(self);
                if (!bp.off) @memset(bp.meta, .{});
                return;
            }
            self.bypass = create(self.count, tol orelse return) catch null;
        }

        /// Frees the batch's bypass records, if any.
        pub fn freeBypass(self: *Batch) void {
            const bp = self.bypass orelse return;
            if (bp.tol.stats) bp.printCensus();
            staging_gpa.free(bp.cols);
            staging_gpa.free(bp.rows);
            staging_gpa.free(bp.vals);
            staging_gpa.free(bp.cells);
            staging_gpa.free(bp.inst);
            staging_gpa.free(bp.meta);
            staging_gpa.free(bp.ref);
            staging_gpa.destroy(bp);
            self.bypass = null;
        }

        /// Newton evaluation of `[first, last)` with the latency bypass: each
        /// instance replays its recorded writes when its inputs are within
        /// tolerance of the recording, else evaluates (recording afresh).
        /// Each plane cell's writes replay in their recorded order, so it
        /// sums as a fresh evaluation with those values would.
        pub fn evalBypass(self: *Batch, bp: *Bp, sink: anytype, first: u32, last: u32, sim: SimState, limiting: bool, pl: *const Planes, comptime staged: bool) void {
            // One test per call. The shipped loop is `evalLoop(.., false)`;
            // C4 and the census share a second instantiation.
            if (bp.tol.c4 or bp.tol.stats) return evalLoop(self, bp, sink, first, last, sim, limiting, pl, staged, true);
            evalLoop(self, bp, sink, first, last, sim, limiting, pl, staged, false);
        }

        // ---- private ----

        /// `evalBypass`'s loop. `ext` false is the shipped bypass; true
        /// reads `tol.c4` (first iterate, counting, key) and `tol.stats`
        /// (the census), each a bool the instance loop tests.
        inline fn evalLoop(self: *Batch, bp: *Bp, sink: anytype, first: u32, last: u32, sim: SimState, limiting: bool, pl: *const Planes, comptime staged: bool, comptime ext: bool) void {
            assert(first <= last);
            assert(last <= self.count);
            const SinkT = @typeInfo(@TypeOf(sink)).pointer.child;
            const c4 = ext and bp.tol.c4;
            const stats = ext and bp.tol.stats;
            var cen: [n_census]usize = @splat(0);
            defer if (stats) for (&bp.census, cen) |*g, v| {
                _ = g.fetchAdd(v, .monotonic);
            };
            if (stats) cen[@backingInt(Census.evals)] += last - first;
            const first_iter = sim.iteration <= 1;
            // The first iterate neither replays nor records (Meyer models
            // branch on it), so a later iterate's recording reaches the next
            // timepoint. C4: unless the model never reads the iteration.
            if (first_iter and !(c4 and replays_first)) return self.evalSplit(sink, first, last, sim, limiting);
            // Which planes the recorded pointers address.
            var key = std.hash.Wyhash.init(@intFromBool(staged));
            key.update(std.mem.asBytes(&[_]usize{ @intFromPtr(pl.g_vals.ptr), @intFromPtr(pl.c_vals.ptr), @intFromPtr(pl.rhs.ptr), @intFromPtr(pl.q_vec.ptr) }));
            const plane_key = key.final();
            const class = classOf(sim);
            const lim_writes = comptime if (has_limit) layout.limitWritesOf(D) else 0;
            var hits: usize = 0;
            var misses: usize = 0;
            // C4 counts from the first transient step: a static solve (dt 0,
            // the transient's operating point included) moves every instance
            // and says nothing about the latency to come.
            const counted = !c4 or sim.dt > 0;
            defer if (counted) {
                _ = bp.hits.fetchAdd(hits, .monotonic);
                _ = bp.misses.fetchAdd(misses, .monotonic);
            };
            var id = first;
            while (id < last) : (id += 1) {
                var lx: [n_u]f64 = undefined;
                var corr = false;
                inline for (0..n_u) |u| {
                    const xg = sink.x(sink.gath(id, u));
                    lx[u] = xg;
                    if (comptime layout.has(lim_writes, u)) if (limiting) {
                        const l = sink.lim(id, u);
                        lx[u] = l;
                        if (@as(u64, @bitCast(xg)) != @as(u64, @bitCast(l))) corr = true;
                    };
                }
                const m = &bp.meta[id];
                const ref = bp.ref[@as(usize, id) * n_u ..][0..n_u];
                const inst_now = std.mem.asBytes(&self.instances[id]);
                const inst_rec = bp.inst[@as(usize, id) * @sizeOf(D.Instance) ..][0..@sizeOf(D.Instance)];
                const eligible = !corr and m.class == class and m.plane == plane_key;
                const keyed = eligible and keyEql(c4, inst_now, inst_rec);
                if (keyed and replay(bp, id, m.*, &lx, ref, SinkT.stores)) {
                    // Charges and the tape are re-read exactly (values only):
                    // a Meyer model's C is not dq/dx, and the transient
                    // multiplies a charge error by 2/dt.
                    if (comptime has_q) stamp.evalQRange(D, dual.RealFor(@hasDecl(D, "collapse")), sink, id, id + 1, sim, null);
                    hits += 1;
                    if (stats) {
                        cen[@backingInt(Census.replays)] += 1;
                        cen[@backingInt(Census.first_replays)] += @intFromBool(first_iter);
                        cen[@backingInt(Census.replay_writes)] += @as(usize, m.n_res) + m.n_jac + m.n_qjac;
                        cen[@backingInt(Census.charge_reads)] += @intFromBool(has_q);
                    }
                    continue;
                }
                misses += 1;
                if (stats) {
                    if (keyed) cen[@backingInt(Census.tol_misses)] += 1;
                    if (eligible and !keyed) cen[@backingInt(Census.byte_misses)] += 1;
                }
                // Full evaluation, recorded, keyed on the bytes it read.
                @memcpy(inst_rec, inst_now);
                var rec: RecordSink(SinkT, rec_cap, &res_rows) = .{
                    .inner = sink,
                    .id = id,
                    .cells = bp.cells[@as(usize, id) * cells_len ..][0..cells_len],
                    .vals = bp.vals[@as(usize, id) * cells_len ..][0..cells_len],
                    .rows = bp.rows[@as(usize, id) * rows_len ..][0..rows_len],
                    .cols = bp.cols[@as(usize, id) * rec_cap.jac ..][0..rec_cap.jac],
                };
                self.evalSplit(&rec, id, id + 1, sim, limiting);
                @memcpy(ref, &lx);
                m.* = if (corr or rec.overflow) .{} else .{
                    .class = class,
                    .n_res = @intCast(rec.n_res),
                    .n_jac = @intCast(rec.n_jac),
                    .n_qjac = @intCast(rec.n_qjac),
                    .plane = plane_key,
                };
            }
            assert(id == last);
        }

        /// Whether a recording's instance bytes key `now`: the whole row,
        /// or with `c4` the row minus `key_spans`' complement, the fields
        /// that reach only a charge value (a hit re-reads the charges).
        inline fn keyEql(c4: bool, now: []const u8, rec: []const u8) bool {
            assert(now.len == rec.len);
            if (key_spans) |spans| if (c4) {
                inline for (spans) |sp| {
                    if (!std.mem.eql(u8, now[sp[0]..sp[1]], rec[sp[0]..sp[1]])) return false;
                }
                return true;
            };
            return std.mem.eql(u8, now, rec);
        }

        fn tally(bp: *Bp, tag: Census, n: usize) void {
            _ = bp.census[@backingInt(tag)].fetchAdd(n, .monotonic);
        }

        fn printCensus(bp: *const Bp) void {
            var c: [n_census]usize = undefined;
            for (&c, &bp.census) |*o, *v| o.* = v.load(.monotonic);
            assert(c[@backingInt(Census.replays)] <= c[@backingInt(Census.evals)]);
            std.debug.print("bypass-stats: model={s} evals={d} replays={d} byte_misses={d} tol_misses={d} first_replays={d} windows_off={d} rearmed={d} replay_writes={d} charge_reads={d} plain={d} windows={d} under_5th={d} under_14th={d}\n", .{ traits.baseName(D), c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12] });
        }

        /// C4's review: judges each window of `window_evals` evaluations per
        /// instance on its own and starts the next from zero; a window under
        /// the break-even rate turns the batch off for `backoff_reviews`
        /// reviews, doubled at each turn-off after the first, after which it
        /// records afresh. Serial, between solves.
        fn reviewWindow(bp: *Bp, count: u32) void {
            assert(bp.tol.c4);
            assert(bp.meta.len == count);
            if (bp.off) {
                bp.rearm_in -|= 1;
                if (bp.rearm_in == 0) {
                    bp.off = false;
                    if (bp.tol.stats) bp.tally(.rearmed, 1);
                    // A write_params or a new query while off left the
                    // recordings unkeyed on the Model rows they read.
                    @memset(bp.meta, .{});
                }
                return;
            }
            const h = bp.hits.load(.monotonic);
            const total = h + bp.misses.load(.monotonic);
            if (total < window_evals * @as(u64, count)) return;
            bp.hits.store(0, .monotonic);
            bp.misses.store(0, .monotonic);
            if (bp.tol.stats) {
                bp.tally(.windows, 1);
                bp.tally(.under_5th, @intFromBool(h * 5 < total));
                bp.tally(.under_14th, @intFromBool(h * 14 < total));
            }
            // `hold` (`c4h`): measurement only, the window is judged and
            // forgotten but the batch stays on.
            if (h * break_even_den < total and !bp.tol.hold) {
                bp.off = true;
                bp.rearm_in = backoff_reviews << @intCast(@min(bp.offs, max_doublings));
                bp.offs +|= 1;
                if (bp.tol.stats) bp.tally(.windows_off, 1);
            }
            assert(bp.off == (bp.rearm_in > 0));
        }

        fn create(count: u32, tol: abi.BypassTol) !*Bp {
            const bp = try staging_gpa.create(Bp);
            errdefer staging_gpa.destroy(bp);
            const ref = try staging_gpa.alloc(f64, count * n_u);
            errdefer staging_gpa.free(ref);
            const meta = try staging_gpa.alloc(Meta, count);
            errdefer staging_gpa.free(meta);
            const inst = try staging_gpa.alloc(u8, count * @sizeOf(D.Instance));
            errdefer staging_gpa.free(inst);
            const cells = try staging_gpa.alloc(*f64, count * cells_len);
            errdefer staging_gpa.free(cells);
            const vals = try staging_gpa.alloc(f64, count * cells_len);
            errdefer staging_gpa.free(vals);
            const rows = try staging_gpa.alloc(u8, count * rows_len);
            errdefer staging_gpa.free(rows);
            const cols = try staging_gpa.alloc(u8, count * rec_cap.jac);
            @memset(meta, .{});
            bp.* = .{ .tol = tol, .ref = ref, .meta = meta, .inst = inst, .cells = cells, .vals = vals, .rows = rows, .cols = cols };
            assert(bp.meta.len == count);
            return bp;
        }

        /// The iteration class a recording is keyed on: the analysis kind and
        /// the flags a model branches on. Never 0, the empty `Meta`'s class.
        fn classOf(sim: SimState) u16 {
            const class: u16 = 1 + 2 * @as(u16, @intCast(@backingInt(sim.kind))) +
                64 * @as(u16, @intFromBool(sim.analog_initial)) +
                128 * @as(u16, @intFromBool(sim.initial_step)) +
                256 * @as(u16, @intFromBool(sim.final_step)) +
                512 * @as(u16, @intFromBool(sim.t > 0));
            assert(class & 1 == 1);
            return class;
        }

        /// Replays instance `id`'s recording `m` at `lx` in residual form,
        /// f(x) ~ f(ref) + J (x - ref), when every unknown and every
        /// predicted residual change is within tolerance; false, writing
        /// nothing, otherwise. `stores`: the cells are staging positions.
        fn replay(bp: *const Bp, id: u32, m: Meta, lx: *const [n_u]f64, ref: *const [n_u]f64, comptime stores: bool) bool {
            assert(m.class != 0);
            assert(m.n_res <= rec_cap.res);
            assert(m.n_jac <= rec_cap.jac);
            assert(m.n_qjac <= rec_cap.qjac);
            var d: [n_u]f64 = undefined;
            inline for (0..n_u) |u| {
                const tol = bp.tol.reltol * @max(@abs(lx[u]), @abs(ref[u])) +
                    (if (comptime isVoltage(u)) bp.tol.vntol else bp.tol.abstol);
                d[u] = lx[u] - ref[u];
                // An infinite `d` passes an infinite `tol`; the dense
                // product this replaced turned it into a NaN and refused.
                if (!(@abs(d[u]) <= tol) or std.math.isInf(d[u])) return false;
            }
            const cells = bp.cells[@as(usize, id) * cells_len ..][0..cells_len];
            const vals = bp.vals[@as(usize, id) * cells_len ..][0..cells_len];
            const rows = bp.rows[@as(usize, id) * rows_len ..][0..rows_len];
            const cols = bp.cols[@as(usize, id) * rec_cap.jac ..][0..rec_cap.jac];
            // J (x - ref) per local row, each row's columns in ascending
            // order from +0.0. A pattern entry no write fills would add a ±0
            // product, which leaves a sum that is never -0 unchanged.
            var jd: [n_u]f64 = @splat(0);
            const js = rec_cap.res;
            for (cols[0..m.n_jac], rows[js..][0..m.n_jac], vals[js..][0..m.n_jac]) |c, r, v| jd[r] += v * d[c];
            // SPICE's second test: the predicted change itself within
            // tolerance (an exponential junction moves far more current than
            // a vntol-sized step suggests).
            for (rows[0..m.n_res], vals[0..m.n_res]) |r, v| {
                if (!(@abs(jd[r]) <= bp.tol.reltol * @abs(v) + bp.tol.abstol)) return false;
            }
            for (cells[0..m.n_res], rows[0..m.n_res], vals[0..m.n_res]) |p, r, v| put(p, v + jd[r], stores);
            for (cells[js..][0..m.n_jac], vals[js..][0..m.n_jac]) |p, v| put(p, v, stores);
            const qs = rows_len;
            for (cells[qs..][0..m.n_qjac], vals[qs..][0..m.n_qjac]) |p, v| put(p, v, stores);
            return true;
        }

        /// Whether unknown `u` is a node potential. VerA omits `u_kinds`
        /// when every unknown is one (no branch flow).
        fn isVoltage(comptime u: usize) bool {
            if (comptime !@hasDecl(D, "u_kinds")) return true;
            return D.u_kinds[u] == .voltage;
        }

        inline fn put(p: *f64, v: f64, comptime stores: bool) void {
            if (stores) p.* = v else p.* += v;
        }
    };
}
