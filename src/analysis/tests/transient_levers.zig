//! The transient's step-loop levers N3 and N7
//! (docs/perf_research/09-after-the-levers.md) and C3's `linear` fact
//! (04-levers-cpu.md). A lever-on run is driven in lockstep with a
//! lever-off one over the same prepared circuit and compared after every
//! attempt.
//! Oracles: the lever-off path, bit for bit (N3, N7); the scalar min chain
//! `stepBoundGear` (N7's lane min); the device hooks' own facts (`linear`).
//! Also: the bound on lanes (`bound_lanes`) against the index-order loop.
//!
//! Contents:
//! - `pub fn each(_: ReversePool, n: u32, ctx: *anyopaque, f: *const fn (*anyopaque, u32) void) void` (ReversePool)

const std = @import("std");
const t = std.testing;
const converger = @import("solver").converger;
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const Prepared = @import("device").Circuit;
const Method = @import("core").query.Method;
const Levers = @import("core").perf.Levers;
const models = @import("models");
const root = @import("../types.zig");
const Sim = @import("../tran/Sim.zig");
const HostOps = @import("../tran/host_ops.zig").HostOps;
const integrator = @import("../tran/integrator.zig");
const bound_lanes = @import("../tran/bound_lanes.zig");
const tran_types = @import("../tran/types.zig");
const GROUND = root.GROUND;
const vec_w = std.simd.suggestVectorLength(f64) orelse 8;

const Fixture = enum { rc, diode, mos };

/// What the lever-off run went through, so the test can require the
/// cases its oracle must have covered.
const Seen = struct { steps: u32, rejects: u64, landings: u64, narrowed: bool };

/// Runs every task on the calling thread, last first: an order no lane
/// pool keeps, so a result that leaned on index order would show.
const ReversePool = struct {
    pub fn each(_: ReversePool, n: u32, ctx: *anyopaque, f: *const fn (*anyopaque, u32) void) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            f(ctx, i);
        }
    }
};

// ---- private ----

/// A 0-to-5 V pulse whose corners the step lands on, into: an RC (charge
/// with no limiter or state), the RC with a diode across C (a limiter), or
/// a resistor-loaded MOS1 (limiter and Meyer-cap state) beside an RC that
/// no MOS row reaches, so N3's narrowed rebase leaves that C out. Returns
/// the circuit and its two probe nodes.
fn build(lib: *const Library, f: Fixture) !struct { Prepared, [2]u32 } {
    var b = try Builder.init(t.allocator, lib);
    const in = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .waveform = 1, .pulse_v2 = 5, .pulse_td = 2e-9, .pulse_tr = 1e-9, .pulse_tf = 1e-9, .pulse_pw = 4e-9, .pulse_per = 12e-9 }, &.{}, .{ in, GROUND });
    switch (f) {
        .rc, .diode => {
            try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ in, out });
            try b.addDevice(models.capacitor, "", &.{ .c = 1e-12 }, &.{}, .{ out, GROUND });
            if (f == .diode) try b.addDevice(models.diode, "", &.{ .is = 1e-14, .cjo = 1e-12 }, &.{}, .{ out, GROUND });
        },
        .mos => {
            const vdd = try b.addNode();
            const side = try b.addNode();
            try b.addDevice(models.vsource, "", &.{ .dc = 5 }, &.{}, .{ vdd, GROUND });
            try b.addDevice(models.resistor, "", &.{ .r = 1e4 }, &.{}, .{ vdd, out });
            try b.addDevice(models.mos1, "", &.{ .vto = 1, .kp = 1e-4 }, &.{}, .{ out, in, GROUND, GROUND });
            try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ in, side });
            try b.addDevice(models.capacitor, "", &.{ .c = 1e-12 }, &.{}, .{ side, GROUND });
        },
    }
    return .{ try b.compile(), .{ in, out } };
}

/// One attempt's Newton solve, as `Sim.drive` runs it.
fn solve(s: *Sim, a: *const Sim.Attempt) !converger.Result {
    return converger.run(s.ckt, s.ws, s.trial, a.t_dev, a.nr_opts, a.hook) catch |err| switch (err) {
        error.QueryCancelled, error.OutOfMemory => return err,
        else => converger.Result{ .converged = false, .iterations = 0 }, // else: a numerical failure retries the step
    };
}

fn expectBits(want: []const f64, got: []const f64) !void {
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(got));
}

/// Everything a later step reads: the time, step and order, the solution,
/// the live history slots (slot 0 is the ring's scratch), the dynamic
/// currents, the charge plane and every device's LTE tape. Device state
/// shows through the plane and the tape: under `has_state_q` the rebase
/// re-reads every stateful charge under the committed state.
fn expectSame(off: *Sim, on: *Sim) !void {
    try t.expectEqual(@as(u64, @bitCast(off.t)), @as(u64, @bitCast(on.t)));
    try t.expectEqual(@as(u64, @bitCast(off.dt)), @as(u64, @bitCast(on.dt)));
    try t.expectEqual(off.order, on.order);
    try t.expectEqual(off.steps, on.steps);
    try expectBits(off.cur, on.cur);
    if (!off.has_charge) return;
    for (off.qHist()[1..], on.qHist()[1..]) |a, b| try expectBits(a, b);
    for (off.qtHist()[1..], on.qtHist()[1..]) |a, b| try expectBits(a, b);
    try expectBits(off.i_prev, on.i_prev);
    try expectBits(off.qt_i_prev, on.qt_i_prev);
    try expectBits(off.ckt.q_vec[0..off.n], on.ckt.q_vec[0..on.n]);
    const len = off.ckt.qTapeLen();
    const tape_off = try t.allocator.alloc(f64, len);
    defer t.allocator.free(tape_off);
    const tape_on = try t.allocator.alloc(f64, len);
    defer t.allocator.free(tape_on);
    off.ckt.snapshotQTape(tape_off);
    on.ckt.snapshotQTape(tape_on);
    try expectBits(tape_off, tape_on);
}

/// With N3 off no batch reports clean charges, so `acceptStaged` can never
/// take the staged path. Oracle: the `track_charges` contract.
fn expectUntracked(ckt: *const root.Circuit) !void {
    for (ckt.batches) |b| if (b.hooks.charges_clean) |f| try t.expect(!f(b.ctx));
}

/// Runs `prepared` twice in lockstep from a uic start, levers off and
/// with `levers` on, and compares them after every attempt and the
/// waveforms at the end. The knobs are set before `Sim.init`, which turns
/// N3's charge tracking on as production does.
fn lockstep(prepared: *const Prepared, probes: []const u32, opts: tran_types.Options, levers: Levers) !Seen {
    const gpa = t.allocator;
    var off = try root.Circuit.instantiate(prepared, gpa);
    defer off.deinit();
    var on = try root.Circuit.instantiate(prepared, gpa);
    defer on.deinit();
    on.knobs.perf = levers;
    const x_off = try gpa.alloc(f64, off.n);
    defer gpa.free(x_off);
    const x_on = try gpa.alloc(f64, on.n);
    defer gpa.free(x_on);
    @memset(x_off, 0);
    @memset(x_on, 0);
    var wf_off = try tran_types.Waveform.init(gpa, @intCast(probes.len), 64);
    defer wf_off.deinit();
    var wf_on = try tran_types.Waveform.init(gpa, @intCast(probes.len), 64);
    defer wf_on.deinit();
    var s_off: Sim = undefined;
    try s_off.init(&off, x_off, probes, &wf_off, opts, gpa, null, null);
    defer s_off.deinit();
    var s_on: Sim = undefined;
    try s_on.init(&on, x_on, probes, &wf_on, opts, gpa, null, null);
    defer s_on.deinit();
    try expectSame(&s_off, &s_on);

    var attempts: u32 = 0;
    while (try s_off.begin(HostOps{})) |a_off| : (attempts += 1) {
        try t.expect(attempts < 100_000);
        const a_on = (try s_on.begin(HostOps{})) orelse return error.TestUnexpectedResult;
        const nr_off = try solve(&s_off, &a_off);
        const nr_on = try solve(&s_on, &a_on);
        try t.expectEqual(nr_off.converged, nr_on.converged);
        try t.expectEqual(nr_off.iterations, nr_on.iterations);
        const v_off = try s_off.end(&a_off, nr_off, HostOps{});
        const v_on = try s_on.end(&a_on, nr_on, HostOps{});
        try t.expectEqual(v_off, v_on);
        try expectSame(&s_off, &s_on);
        try expectUntracked(&off);
        try t.expect(v_off == .go);
    } else try t.expect((try s_on.begin(HostOps{})) == null);
    try t.expectEqual(wf_off.len, wf_on.len);
    try expectBits(wf_off.data(), wf_on.data());
    return .{
        .steps = s_off.steps,
        .rejects = s_off.st.rej_lte + s_off.st.rej_newton + s_off.st.rej_state,
        .landings = s_off.st.bp_landings,
        .narrowed = s_on.rebase_batches.len > 0,
    };
}

test "N3 and N7: lever on is lever off bit for bit after every attempt, rejections and breakpoints included" {
    // Oracle: the lever-off run of the same circuit, compared by bits.
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var rejects: u64 = 0;
    var landings: u64 = 0;
    for ([_]Fixture{ .rc, .diode, .mos }) |f| for ([_]Method{ .trapezoidal, .gear_3 }) |m| {
        var prepared, const probes = try build(&lib, f);
        defer prepared.deinit();
        const seen = try lockstep(&prepared, &probes, .{
            .t_stop = 20e-9,
            .dt_init = 0.5e-9,
            .uic = true,
            .method = m,
            // Tight, so the LTE rejects some attempts.
            .tol = .{ .reltol = 1e-4, .trtol = 1 },
        }, .{ .n3 = true, .n7 = true });
        try t.expect(seen.steps > 10);
        // The MOS fixture's side RC shares no row with the MOS.
        try t.expectEqual(f == .mos, seen.narrowed);
        rejects += seen.rejects;
        landings += seen.landings;
    };
    // The oracle saw a rejected and retried attempt and a breakpoint landing.
    try t.expect(rejects > 0);
    try t.expect(landings > 0);
}

test "N7: stepBoundGearLanes is stepBoundGear bit for bit at every length, NaN and inf included" {
    // Oracle: the scalar min chain, `stepBoundGear`.
    var prng = std.Random.DefaultPrng.init(0x7a7e);
    const r = prng.random();
    const len_max = 40;
    var block: [8][len_max]f64 = undefined;
    var ip: [len_max]f64 = undefined;
    var g: [len_max]f64 = undefined;
    const dts = [_]f64{ 1e-9, 1.3e-9, 0.7e-9, 1e-9, 2e-9, 1.1e-9, 0.9e-9 };
    const lte: integrator.LteIn = .{ .dt = dts[0], .dt1 = dts[1], .dt2 = dts[2], .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
    const c: integrator.Coeffs = .{ .ag0 = 1e9, .ag2 = 0 };
    for (0..len_max + 1) |len| for (0..3) |plant| {
        for (&block) |*h| for (h) |*v| {
            v.* = (r.float(f64) - 0.5) * 1e-12;
        };
        for (&ip, &g) |*a, *b| {
            a.* = (r.float(f64) - 0.5) * 1e-3;
            b.* = (r.float(f64) - 0.5) * 1e-3;
        }
        if (len > 0) switch (plant) {
            0 => {},
            1 => block[2][r.uintLessThan(usize, len)] = std.math.nan(f64),
            else => ip[r.uintLessThan(usize, len)] = std.math.inf(f64), // else: plant 2
        };
        var q: [8][]const f64 = undefined;
        for (&q, &block) |*s, *h| s.* = h[0..len];
        for ([_]Method{ .gear_3, .gear_4, .gear_6 }) |m| for ([_]Method{ .backward_euler, .trapezoidal, .gear_3 }) |cm| {
            const p = integrator.order(m);
            const want = integrator.stepBoundGear(m, cm, q[0 .. p + 2], ip[0..len], g[0..len], c, lte, &dts);
            const got = integrator.stepBoundGearLanes(m, cm, q[0 .. p + 2], ip[0..len], g[0..len], c, lte, &dts);
            try t.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
        };
    };
}

test "linear: an RC is x-independent, the same RC with a diode is not" {
    // Oracle: the hooks' facts (a constant Jacobian; a diode's limiter).
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    for ([_]bool{ false, true }) |diode| {
        var b = try Builder.init(t.allocator, &lib);
        const out = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ out, GROUND });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ out, GROUND });
        if (diode) try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ out, GROUND });
        var prepared = try b.compile();
        defer prepared.deinit();
        try t.expectEqual(!diode, prepared.linear);
    }
}

test "step clock: armed it changes no output and times only what lies outside Newton" {
    // Oracles: the unarmed run (bits of the waveform; an unarmed clock
    // keeps every phase at zero), and the test's own clock around `begin`
    // and `end`, which brackets every stretch the step clock may charge:
    // their sum bounds the phases' sum, while Newton's time lies outside.
    const gpa = t.allocator;
    var lib = try Library.init(gpa);
    defer lib.deinit();
    var prepared, const probes = try build(&lib, .mos);
    defer prepared.deinit();
    const opts: tran_types.Options = .{ .t_stop = 20e-9, .dt_init = 0.5e-9, .uic = true };
    var wf_off = try tran_types.Waveform.init(gpa, @intCast(probes.len), 64);
    defer wf_off.deinit();
    var wf_on = try tran_types.Waveform.init(gpa, @intCast(probes.len), 64);
    defer wf_on.deinit();
    const wfs = [2]*tran_types.Waveform{ &wf_off, &wf_on };
    var outside: u64 = 0;
    var phases: [2]u64 = @splat(0);
    for (0..2) |armed| {
        var ckt = try root.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        @memset(x, 0);
        var s: Sim = undefined;
        try s.init(&ckt, x, &probes, wfs[armed], opts, gpa, null, null);
        defer s.deinit();
        try t.expect(s.clock.io == null);
        if (armed == 1) s.clock.io = t.io;
        var attempts: u32 = 0;
        while (true) : (attempts += 1) {
            try t.expect(attempts < 100_000);
            const t0: std.Io.Timestamp = .now(t.io, .awake);
            const a = (try s.begin(HostOps{})) orelse break;
            const t1: std.Io.Timestamp = .now(t.io, .awake);
            const nr = try solve(&s, &a);
            const t2: std.Io.Timestamp = .now(t.io, .awake);
            try t.expect(try s.end(&a, nr, HostOps{}) == .go);
            const t3: std.Io.Timestamp = .now(t.io, .awake);
            if (armed == 1) outside += @intCast(t0.durationTo(t1).nanoseconds + t2.durationTo(t3).nanoseconds);
        }
        for (s.clock.ns) |ns| phases[armed] += ns;
        try t.expect(s.steps > 10);
        s.clock.io = null; // no `timing:` line from the test's deinit
    }
    try t.expectEqual(@as(u64, 0), phases[0]);
    try t.expect(phases[1] > 0);
    if (phases[1] > outside) std.debug.print("step clock {d} ns > bracketing windows {d} ns\n", .{ phases[1], outside });
    try t.expect(phases[1] <= outside);
    try t.expectEqual(wf_off.len, wf_on.len);
    try expectBits(wf_off.data(), wf_on.data());
}

test "N7: the bound on lanes is the index-order loop bit for bit at 1, 2, 3 and 8 lanes, with a NaN state and ties" {
    // Oracles: `stepBound(1, ...)`, the scalar index-order loop, and
    // `stepBound(W, ...)`, the shipped one, compared by bits.
    var prng = std.Random.DefaultPrng.init(0x9e7);
    const r = prng.random();
    const n = 1003; // not a multiple of any vector width
    var hist: [4][n]f64 = undefined;
    var ip: [n]f64 = undefined;
    var mins_buf: [64]f64 = undefined;
    const lte: integrator.LteIn = .{ .dt = 1e-9, .dt1 = 1.3e-9, .dt2 = 0.7e-9, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
    const c: integrator.Coeffs = .{ .ag0 = 2e9, .ag2 = 0.4e9, .ag1 = 1 };
    const pairs = [_][2]Method{ .{ .backward_euler, .backward_euler }, .{ .trapezoidal, .backward_euler }, .{ .trapezoidal, .trapezoidal }, .{ .gear_2, .gear_2 } };
    for (0..3) |plant| {
        for (&hist) |*h| for (h) |*v| {
            v.* = (r.float(f64) - 0.5) * 1e-12;
        };
        for (&ip) |*v| v.* = (r.float(f64) - 0.5) * 1e-3;
        switch (plant) {
            0 => {},
            // Ties: one state copied far away, so equal minima land in
            // different chunks.
            1 => for (0..4) |k| {
                hist[k][n - 1] = hist[k][3];
                ip[n - 1] = ip[3];
            },
            else => hist[2][517] = std.math.nan(f64), // else: plant 2
        }
        const q: [4][]const f64 = .{ &hist[0], &hist[1], &hist[2], &hist[3] };
        for (pairs) |pm| for ([_]usize{ 1, 2, 3, 8 }) |lanes| {
            const want = integrator.stepBound(1, pm[0], pm[1], q, &ip, c, lte);
            try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(integrator.stepBound(vec_w, pm[0], pm[1], q, &ip, c, lte))));
            const chunk = bound_lanes.chunkOf(n, lanes);
            const n_chunks = std.math.divCeil(usize, n, chunk) catch unreachable;
            const got = bound_lanes.boundLanes(ReversePool{}, mins_buf[0..n_chunks], chunk, pm[0], pm[1], q, &ip, c, lte);
            try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
            if (plant == 2) try std.testing.expect(std.math.isNan(got));
        };
    }
}
