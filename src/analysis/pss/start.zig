//! An autonomous shooting's start, as ngspice's PSS starts it: the DC
//! point (or the `.ic` values under `uic`) in, one settling transient and
//! fixed-step periods until the phase node's swing settles, then a record
//! of `measure_periods` more; out the period guess, the phase node, the
//! anchor's time on the sources' axis and the swing ratio (`Start`), x left
//! at the anchor.
//! Cites: ngspice pssinit.c:16-20, dcpss.c:3560-3566, 3884 and 4218.
//!
//! Contents:
//! - `pub const Start = struct`
//! - `pub fn startOscillator(ckt: *root.Circuit, ws: *converger.Workspace, sc: *period.Companion, x: []f64, options: Options, allocator: std.mem.Allocator) !Start`
//! - `pub fn swingOf(rec: []const f64, n: usize, row: u32) f64`

const std = @import("std");
const num = @import("core").numerics;
const converger = @import("solver").converger;
const root = @import("../types.zig");
const period = @import("period.zig");
const tran = @import("../tran/tran.zig");

const Options = @import("core").query.Pss;
const integrateOnePeriod = period.integrateOnePeriod;

/// An autonomous start's outcome: the shooting's first period, the phase
/// node, the anchor's time on the sources' axis (`Pss.t_origin`), and the
/// phase node's swing ratio per period over the record, last crossing
/// interval to first: a decaying oscillation's dominant Floquet multiplier
/// magnitude, 1 on a limit cycle.
pub const Start = struct { period: f64, osc_node: u32, t_origin: f64, swing_ratio: f64 };

/// Guess periods an autonomous solve records to measure the period from.
const measure_periods: usize = 8;

/// Volts the oscillator node is pushed off its DC equilibrium to start it.
const osc_kick: f64 = 1e-3;

/// Cap on the periods an autonomous start settles past
/// `osc_settle_periods` while the swing still grows by over 1 % a period.
const max_settle_periods: usize = 2000;

/// Starts an oscillator for the autonomous solve, as ngspice's PSS does: one
/// transient from t = 0 (the DC point, or the `.ic` values under `uic`)
/// over `osc_settle_periods` guess periods, its first step and step cap
/// ngspice's (pssinit.c:16-20, dcpss.c:3560-3566), so a PWL or pulse
/// start-up kick plays once. A given osc node is kicked off its equilibrium
/// first. Fixed-step periods then continue that transient's time until the
/// phase node's swing settles (at most `max_settle_periods`), and record
/// `measure_periods` more. Under `.largest_swing` the phase node is the net
/// that swings most over the last settle period (`largestSwing`), named in
/// a warning. The period is the mean spacing of the phase node's rising
/// mid-swing crossings in that record. Leaves `x` at the first sample after
/// the last crossing, the phase anchor the solve pins.
pub fn startOscillator(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *period.Companion,
    x: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Start {
    const n: usize = ckt.n;
    const steps: usize = options.n_samples;
    const guess = options.period;
    var osc = options.osc_node;
    if (osc != root.GROUND) x[osc] += osc_kick;
    const t_stab = @as(f64, @floatFromInt(options.osc_settle_periods)) * guess;
    if (t_stab > 0) {
        var wf = try tran.Waveform.init(allocator, 0, 1);
        defer wf.deinit();
        const reached = try tran.simulate(ckt, x, &.{}, &wf, .{
            .tol = options.tol,
            .t_stop = t_stab,
            .t_start = t_stab,
            .dt_init = guess / 100,
            .dt_max = guess / 2,
            .uic = options.uic,
        }, allocator);
        if (!reached) return error.TimestepTooSmall;
    }

    // Every unknown, each period: the settle test reads the phase node, the
    // pick every net, and the anchor its whole state.
    const rows = try allocator.alloc(u32, n);
    defer allocator.free(rows);
    for (rows, 0..) |*r, i| r.* = @intCast(i);
    const stride = (steps + 1) * (n + 1);
    const record = try allocator.alloc(f64, measure_periods * stride);
    defer allocator.free(record);
    var opts = options;
    // A weakly unstable tank grows from the kick over many periods: keep
    // settling until the phase node's swing moves under 1 % a period.
    var settled: usize = 0;
    var prev_swing: f64 = 0;
    while (settled < max_settle_periods) {
        opts.t_origin = t_stab + @as(f64, @floatFromInt(settled)) * guess;
        settled += 1;
        if (!try integrateOnePeriod(ckt, ws, sc, x, rows, record[0..stride], opts)) return error.OscillatorDidNotStart;
        if (options.phase_node == .largest_swing) osc = largestSwing(ckt, record[0..stride]);
        if (osc == root.GROUND) return error.OscillatorDidNotStart;
        const swing = swingOf(record[0..stride], n, osc);
        if (@abs(swing - prev_swing) <= 0.01 * swing) break;
        prev_swing = swing;
    }
    if (options.phase_node == .largest_swing)
        std.debug.print("Warning: pss: no net names the phase node; picked v({s}), the net with the largest swing\n", .{ckt.nodeName(osc)});
    const t_record = t_stab + @as(f64, @floatFromInt(settled)) * guess;
    for (0..measure_periods) |p| {
        opts.t_origin = t_record + @as(f64, @floatFromInt(p)) * guess;
        if (!try integrateOnePeriod(ckt, ws, sc, x, rows, record[p * stride ..][0..stride], opts)) return error.OscillatorDidNotStart;
    }

    // Sample g of the record is row g % steps of period g / steps; the last
    // row of each period repeats the next period's first.
    const total = measure_periods * steps + 1;
    const Sample = struct {
        /// The record row of sample g.
        fn index(g: usize, s: usize) usize {
            const p = @min(g / s, measure_periods - 1);
            return p * (s + 1) + g - p * s;
        }
        fn row(rec: []const f64, g: usize, s: usize, cols: usize) []const f64 {
            return rec[index(g, s) * cols + 1 ..][0 .. cols - 1];
        }
    };
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (0..total) |g| {
        const v = Sample.row(record, g, steps, n + 1)[osc];
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const level = 0.5 * (lo + hi);
    var first: f64 = 0;
    var last: f64 = 0;
    var anchor: usize = 0;
    // Samples after the first, second and next-to-last crossings.
    var g_first: usize = 0;
    var g_second: usize = 0;
    var g_before: usize = 0;
    var crossings: u32 = 0;
    var prev = Sample.row(record, 0, steps, n + 1)[osc];
    for (1..total) |g| {
        const v = Sample.row(record, g, steps, n + 1)[osc];
        if (prev < level and v >= level) {
            const at = @as(f64, @floatFromInt(g - 1)) + (level - prev) / (v - prev);
            if (crossings == 0) first = at;
            if (crossings == 0) g_first = g;
            if (crossings == 1) g_second = g;
            g_before = anchor;
            last = at;
            anchor = g;
            crossings += 1;
        }
        prev = v;
    }
    if (crossings < 2 or !(hi - lo > osc_kick)) return error.OscillatorDidNotStart;
    num.copySimd(x[0..n], Sample.row(record, anchor, steps, n + 1));
    const dt = guess / @as(f64, @floatFromInt(steps));
    const cols = n + 1;
    const swing_first = swingOf(record[Sample.index(g_first, steps) * cols .. Sample.index(g_second, steps) * cols], n, osc);
    const swing_last = swingOf(record[Sample.index(g_before, steps) * cols .. Sample.index(anchor, steps) * cols], n, osc);
    return .{
        .period = (last - first) / @as(f64, @floatFromInt(crossings - 1)) * dt,
        .osc_node = osc,
        .t_origin = t_record + @as(f64, @floatFromInt(anchor)) * dt,
        .swing_ratio = if (crossings < 3) 1 else std.math.pow(f64, swing_last / swing_first, 1 / @as(f64, @floatFromInt(crossings - 2))),
    };
}

/// Max minus min of unknown `row` over the rows [t, x...] of `rec`.
pub fn swingOf(rec: []const f64, n: usize, row: u32) f64 {
    std.debug.assert(rec.len % (n + 1) == 0 and row < n);
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    var k: usize = 0;
    while (k < rec.len) : (k += n + 1) {
        lo = @min(lo, rec[k + 1 + row]);
        hi = @max(hi, rec[k + 1 + row]);
    }
    return hi - lo;
}

// ---- private ----

/// The net that swings most over one recorded period `rec` (rows
/// [t, x...]), the lowest row on a tie; GROUND when none moves. A net is a
/// named row past ground: branch currents and device-internal unknowns
/// (unnamed, or `dev#unknown`) are not.
fn largestSwing(ckt: *const root.Circuit, rec: []const f64) u32 {
    const n: usize = ckt.n;
    var best: f64 = 0;
    var pick: u32 = root.GROUND;
    for (1..n) |i| {
        const name = ckt.nodeName(@intCast(i));
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '#') != null) continue;
        const swing = swingOf(rec, n, @intCast(i));
        if (swing > best) {
            best = swing;
            pick = @intCast(i);
        }
    }
    return pick;
}
