//! Where `--backend auto` runs a query's device evaluation under lever
//! `p1`: a pure function of the calibration file (`machine.Machine`) and
//! the query's census. No clock, no host probe, no record of an earlier
//! run, no driver or thread-pool state, so one deck places the same on
//! every run and every thread. Imports no driver.
//! In: `Census` (each GPU-eligible batch's image and width, the expected
//! evals, the bytes each eval moves, the lanes the plan wants). Out:
//! `Verdict`.
//! Cites: docs/perf_research/08-placement.md sec. 2 (rule 1, the cost
//! model, the margin M) and sec. 6 step 3.
//!
//! Contents:
//! - `pub const margin: f64`
//! - `pub const Batch = struct`, `pub const Census = struct`, `pub const Verdict = struct`
//! - `pub fn place(m: *const Machine, q: *const Census) Verdict`
//! - `pub fn rowOf(m: *const Machine, image: u64) ?*const machine.Model`
//! - `pub fn interp(at: [4]f64, count: u32) f64`
//! - `pub fn opOnHost(p1: bool, gpu_lanes: bool, op: bool) bool`

const std = @import("std");
const assert = std.debug.assert;
const machine = @import("machine.zig");
const Machine = machine.Machine;
const sizes = machine.model_sizes;

/// M: the device must beat the host by this factor over the query's
/// evaluation, the driver's start paid on top. It bounds the model's error
/// (the 95th percentile of |ln(priced / measured)| wall ratio over the
/// placement oracle's fully priced decks); the oracle test recomputes it
/// and fails when this constant is smaller. ponytail: 3.3 covers the
/// hand-built fixture (`price.machine.tsv`), whose largest error is
/// chain_4k's 3.25x by arithmetic, not by a run; step 2's measured oracle
/// and step 1's measured file refit it.
pub const margin: f64 = 3.3;

/// One GPU-eligible batch as the price sees it: what the circuit fixes.
pub const Batch = struct {
    /// The kernel image's Wyhash: the key of its `machine.Model` row.
    image: u64,
    /// Instances.
    count: u32,
};

/// One query's counts, known before its first evaluation.
pub const Census = struct {
    batches: []const Batch,
    /// Expected device evaluations (`dispatch.expectedEvals`).
    evals: f64,
    /// Bytes over the bus, and staging bytes, per evaluation.
    bus_bytes: f64,
    stage_bytes: f64,
    /// Host lanes the query's plan stamps on (`lanePlan`), not what the
    /// pool grants at the moment.
    lanes: u32,
};

/// The price of one query's device evaluation.
pub const Verdict = struct {
    /// The evaluation goes to the device.
    device: bool,
    /// Priced us per evaluation over the priced batches: on the host's
    /// lanes, and on the device with its fixed cost.
    cpu_us: f64,
    gpu_us: f64,
    /// Batches with a model row; the others stay on the host either way.
    priced: u32,
};

/// The device takes the evaluation iff its saving over the query,
/// `evals * (cpu_us - margin * gpu_us)`, exceeds the driver's start. The
/// start is charged on every query, driver up or not, so the verdict is
/// the deck's alone (step 6 moves it to the Problem). A batch without a
/// model row is left out of both sides; none priced is the host. Any NaN
/// prices the host.
pub fn place(m: *const Machine, q: *const Census) Verdict {
    assert(q.lanes >= 1);
    assert(q.batches.len <= std.math.maxInt(u32));
    const c = &m.c;
    var host: f64 = 0;
    var gained: f64 = 0;
    var kern: f64 = 0;
    var priced: u32 = 0;
    for (q.batches) |b| {
        const row = rowOf(m, b.image) orelse continue;
        const h = interp(row.host_p_us, b.count);
        host += h;
        gained += h * row.lane_gain;
        kern += @max(0, interp(row.dev_us, b.count) - c.eval_fixed_us);
        priced += 1;
    }
    if (priced == 0) return .{ .device = false, .cpu_us = 0, .gpu_us = 0, .priced = 0 };
    // The lanes' gain, weighted by each batch's host time.
    const g = if (q.lanes == 1 or !(host > 0)) @as(f64, 1) else @max(1, gained / host);
    const cpu_us = host / g;
    const gpu_us = c.eval_fixed_us + kern + q.bus_bytes / c.bus_b_per_us + q.stage_bytes / c.stage_b_per_us;
    const saved = q.evals * (cpu_us - margin * gpu_us);
    assert(priced <= q.batches.len);
    return .{ .device = saved > c.start_ms * 1e3, .cpu_us = cpu_us, .gpu_us = gpu_us, .priced = priced };
}

/// `m`'s model row for `image`, or null: that batch stays on the host. A
/// scan of at most ~90 rows, once per batch per query.
pub fn rowOf(m: *const Machine, image: u64) ?*const machine.Model {
    for (m.models) |*row| {
        if (row.image == image) return row;
    }
    return null;
}

/// A row's value at `count` instances from its values `at` the four
/// `model_sizes`: a power law between two sizes (linear in log value
/// against log size), proportional to `count` past the last. Linear in
/// value where a bracket holds a value <= 0.
pub fn interp(at: [4]f64, count: u32) f64 {
    assert(count >= 1);
    assert(sizes[0] == 1);
    const x: f64 = @floatFromInt(count);
    const last: f64 = @floatFromInt(sizes[3]);
    if (count >= sizes[3]) return at[3] * x / last;
    const k: usize = if (count <= sizes[1]) 0 else if (count <= sizes[2]) 1 else 2;
    const lo: f64 = @floatFromInt(sizes[k]);
    const hi: f64 = @floatFromInt(sizes[k + 1]);
    const t = @log(x / lo) / @log(hi / lo);
    if (!(at[k] > 0 and at[k + 1] > 0)) return at[k] + t * (at[k + 1] - at[k]);
    return @exp(@log(at[k]) + t * (@log(at[k + 1]) - @log(at[k])));
}

/// Whether an operating point skips the device before any price: HEAD's
/// rule under `gpu_lanes`, where every OP runs on the CPU workers. Under
/// `p1` nothing is barred: `place` decides its device evaluation (the
/// model rows) and `lu_price.buys` its device LU (the `lu` rows). The
/// executor passes `gpu_lanes and may_batch` for the LU.
pub fn opOnHost(p1: bool, gpu_lanes: bool, op: bool) bool {
    return !p1 and gpu_lanes and op;
}

test {
    _ = @import("price_tests.zig");
}
