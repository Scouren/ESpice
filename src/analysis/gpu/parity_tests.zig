//! Host tests of GPU parity rows 12 (HB samples) and 9 (coupled inductors
//! on lanes), 16-gpu-parity.md, on the host instantiation where one exists.
//! Oracles: the host HB sampled operator (`mhb_newton.sample`), each sample
//! re-evaluated alone in reverse order, bitwise; the lanes' census rule
//! (`lanes.staticRefusal`, `device/tests/eval.zig` "GPU census") for
//! `lanes_samples.refusal`; `host_ops.lteSnap` on a coupled pair's
//! transient, bitwise, against the lane fix-up (`lanes_lte.table`,
//! `lk.lteFix`) on a lane-major ring.

const std = @import("std");
const t = std.testing;
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const Prepared = @import("device").Circuit;
const models = @import("models");
const solver = @import("solver");
const converger = solver.converger;
const lk = solver.lane_kernels;
const root = @import("../types.zig");
const mhb_newton = @import("../pss/mhb_newton.zig");
const mhb_spectrum = @import("../pss/mhb_spectrum.zig");
const mhb_transform = @import("../pss/mhb_transform.zig");
const Sim = @import("../tran/Sim.zig");
const host_ops = @import("../tran/host_ops.zig");
const tran_types = @import("../tran/types.zig");
const lanes_samples = @import("lanes_samples.zig");
const lanes_lte = @import("lanes_lte.zig");
const GROUND = root.GROUND;

// ---- private ----

/// A resistor-loaded MOS1 driven at its gate: a limiter and Meyer-cap state
/// with device state kernels, so stateful charge (`has_state_q`).
fn mosAmp(lib: *const Library) !struct { Prepared, u32 } {
    var b = try Builder.init(t.allocator, lib);
    const in = try b.addNode();
    const out = try b.addNode();
    const vdd = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1.5, .waveform = 2, .sin_vo = 1.5, .sin_va = 1, .sin_freq = 1e6 }, &.{}, .{ in, GROUND });
    try b.addDevice(models.vsource, "", &.{ .dc = 5 }, &.{}, .{ vdd, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1e4 }, &.{}, .{ vdd, out });
    try b.addDevice(models.mos1, "", &.{ .vto = 1, .kp = 1e-4 }, &.{}, .{ out, in, GROUND, GROUND });
    return .{ try b.compile(), in };
}

/// A pulse through 50 ohm into L1, coupled (k = 0.5) to L2 across 100 ohm.
fn coupledPair(lib: *const Library) !Prepared {
    var b = try Builder.init(t.allocator, lib);
    const in = try b.addNode();
    const p1 = try b.addNode();
    const p2 = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .waveform = 1, .pulse_v2 = 1, .pulse_td = 1e-9, .pulse_tr = 1e-9, .pulse_tf = 1e-9, .pulse_pw = 4e-9, .pulse_per = 10e-9 }, &.{}, .{ in, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 50 }, &.{}, .{ in, p1 });
    // An inductor's branch current is the unknown it appends.
    const br1 = b.n;
    try b.addDevice(models.inductor, "", &.{ .l = 1e-6 }, &.{}, .{ p1, GROUND });
    const br2 = b.n;
    try b.addDevice(models.inductor, "", &.{ .l = 4e-6 }, &.{}, .{ p2, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 100 }, &.{}, .{ p2, GROUND });
    // M = k sqrt(L1 L2), as `addKinduc` resolves a K card.
    try b.addDevice(models.kinduc, "", &.{ .k = 0.5 * @sqrt(1e-6 * 4e-6) }, &.{}, .{ br1, br2 });
    return b.compile();
}

/// A voltage switch, host-stepped (hysteresis state, no device state
/// kernel): on the lanes' census list.
fn switched(lib: *const Library) !Prepared {
    var b = try Builder.init(t.allocator, lib);
    const ctl = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ ctl, GROUND });
    try b.addDevice(models.isource, "", &.{ .dc = 1e-3 }, &.{}, .{ GROUND, out });
    try b.addDevice(models.vswitch, "", &.{}, &.{}, .{ out, GROUND, ctl, GROUND });
    return b.compile();
}

fn expectBits(want: f64, got: f64) !void {
    try t.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
}

test "HB samples: each sample evaluated alone is the host sampled operator's, bitwise, state hooks and all" {
    // Oracle: `mhb_newton.sample`, the host HB sampled operator, on a MOS1
    // with state hooks and stateful charge after a DC solve that ran its
    // state pass (`dcSeed`'s state). Each sample is then evaluated alone in
    // reverse order, the start a sample lane has (the packed rows, no state
    // carried between samples): f, q, g and c bitwise per sample. The card
    // alone checks the lane eval kernel against these planes and `laneSims`'
    // `analog_initial` (a GPU HB run of this circuit under the admit patch).
    const a = t.allocator;
    var lib = try Library.init(a);
    defer lib.deinit();
    var prepared, const gate = try mosAmp(&lib);
    defer prepared.deinit();
    var ckt = try root.Circuit.instantiate(&prepared, a);
    defer ckt.deinit();
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;
    try t.expect(ckt.has_state_q);
    try t.expectEqual(@as(?[]const u8, null), lanes_samples.refusal(&ckt));
    const x_dc = try a.alloc(f64, n);
    defer a.free(x_dc);
    @memset(x_dc, 0);
    try ckt.computeBaseline();
    const ws = try ckt.workspace();
    ckt.setSimState(.{ .kind = .dc });
    _ = try converger.run(&ckt, ws, x_dc, 0, .{}, root.EvalHook{});
    // The state pass held the MOS batch's `analog initial` results: the
    // case `laneSims` serves.
    var held = false;
    for (ckt.batches) |b| if (b.hooks.gpu_payload) |gp| if (gp(b.ctx).held_initial) |h| {
        held = held or h.*;
    };
    try t.expect(held);

    const tones = [_]f64{1e6};
    const spec = try mhb_spectrum.spectrum(a, &tones, &.{4}, 0, 1);
    defer spec.deinit(a);
    const nf = 2 * spec.freqs.len - 1;
    const nt = mhb_transform.transformSamples(spec);
    const tr_buf = try a.alloc(f64, nt + 2 * nt * nf);
    defer a.free(tr_buf);
    const tr = try mhb_transform.transform(spec, &tones, tr_buf, a);
    const x_hat = try a.alloc(f64, n * nf);
    defer a.free(x_hat);
    @memset(x_hat, 0);
    for (0..n) |node| x_hat[node * nf] = x_dc[node];
    // A 1 V gate swing takes the MOS through cutoff and saturation.
    x_hat[@as(usize, gate) * nf + 1] = 1;
    const slab = try a.alloc(f64, 3 * n * nt + 2 * nnz * nt);
    defer a.free(slab);
    var off: usize = 0;
    const p = mhb_newton.takePlanes(slab, &off, n * nt, nnz * nt);
    const x_sample = try a.alloc(f64, n);
    defer a.free(x_sample);
    const dt = mhb_newton.sampleDt(spec);
    // No state pass runs between samples: every Instance row (the `$prev`
    // latches a commit writes) is the one the sample lanes pack, bitwise.
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(a);
    for (ckt.batches) |b| if (b.hooks.gpu_payload) |gp| try rows.appendSlice(a, gp(b.ctx).instances);
    mhb_newton.sample(&ckt, tr, nf, dt, x_hat, x_sample, p);
    var at: usize = 0;
    for (ckt.batches) |b| if (b.hooks.gpu_payload) |gp| {
        const now = gp(b.ctx).instances;
        try t.expectEqualSlices(u8, rows.items[at..][0..now.len], now);
        at += now.len;
    };
    try t.expectEqual(rows.items.len, at);
    try t.expect(at > 0);

    var s = nt;
    while (s > 0) {
        s -= 1;
        for (0..n) |node| x_sample[node] = p.x[node * nt + s];
        ckt.setSimState(.{ .t = tr.times[s], .dt = dt, .kind = .tran });
        ckt.eval(x_sample, tr.times[s]);
        for (0..n) |node| {
            try expectBits(p.f[node * nt + s], ckt.rhs[node]);
            try expectBits(p.q[node * nt + s], ckt.q_vec[node]);
        }
        for (0..nnz) |slot| {
            try expectBits(p.g[slot * nt + s], ckt.g_vals[slot]);
            try expectBits(p.c[slot * nt + s], ckt.c_vals[slot]);
        }
    }
}

test "HB samples: the lifted refusal admits device state kernels and turns down a host-stepped switch" {
    // Oracle: the lanes' census (`device/tests/eval.zig` "GPU census"):
    // mos1 and kinduc are off its lanes list, vswitch is on it, refused as
    // host-stepped. Today's rule refuses mos1 for its state hooks; the
    // lifted one must not.
    const a = t.allocator;
    var lib = try Library.init(a);
    defer lib.deinit();
    var mos, _ = try mosAmp(&lib);
    defer mos.deinit();
    var pair = try coupledPair(&lib);
    defer pair.deinit();
    var sw = try switched(&lib);
    defer sw.deinit();
    const want = [_]?[]const u8{ null, null, "host-stepped" };
    for ([_]*const Prepared{ &mos, &pair, &sw }, want) |prep, w| {
        var ckt = try root.Circuit.instantiate(prep, a);
        defer ckt.deinit();
        const got = lanes_samples.refusal(&ckt);
        if (w) |why| try t.expectEqualStrings(why, got orelse return error.TestExpectedEqual) else try t.expectEqual(@as(?[]const u8, null), got);
    }
}

test "kinduc lanes: after a charge pass each lane's LTE states are host lteSnap's, bitwise" {
    // Oracle: `host_ops.lteSnap`, the host transient's LTE states, at three
    // accepted points of a coupled pair (the inductor and kinduc tape spans
    // zeroed, both branch rows' q appended). The lane recipe on the host
    // instantiation: each point's raw tape in its own lane's ring slot at
    // the `n_lt` stride, as the charge kernel writes it, then `lk.lteFix`
    // with `lanes_lte.table`; every other cell keeps its seed. The card
    // alone checks `arp_lane_lte_fix` and the lane step over n_lt states:
    // the GPU transient of this pair, bitwise per lane, under the admit patch.
    const a = t.allocator;
    var lib = try Library.init(a);
    defer lib.deinit();
    var prepared = try coupledPair(&lib);
    defer prepared.deinit();
    var ckt = try root.Circuit.instantiate(&prepared, a);
    defer ckt.deinit();
    const x = try a.alloc(f64, ckt.n);
    defer a.free(x);
    @memset(x, 0);
    var wf = try tran_types.Waveform.init(a, 1, 64);
    defer wf.deinit();
    var sim: Sim = undefined;
    try sim.init(&ckt, x, &.{0}, &wf, .{ .t_stop = 8e-9, .dt_init = 0.25e-9, .uic = true }, a, null, null);
    defer sim.deinit();
    const n: usize = ckt.n;
    const n_tape = sim.n_qt;
    const rows = sim.lte_rows;
    const n_lt = n_tape + rows.len;
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqual(@as(usize, 2), sim.lte_zero.len);

    // Three accepted points, one per lane: raw tape, q plane, lteSnap.
    const N = 3;
    var raw: [N][]f64 = undefined;
    var qv: [N][]f64 = undefined;
    var want: [N][]f64 = undefined;
    var got: usize = 0;
    defer for (0..got) |l| {
        a.free(raw[l]);
        a.free(qv[l]);
        a.free(want[l]);
    };
    var attempts: u32 = 0;
    while (got < N) : (attempts += 1) {
        try t.expect(attempts < 10_000);
        const at = (try sim.begin(host_ops.HostOps{})) orelse return error.TestUnexpectedResult;
        const nr = try converger.run(sim.ckt, sim.ws, sim.trial, at.t_dev, at.nr_opts, at.hook);
        const steps = sim.steps;
        const verdict = try sim.end(&at, nr, host_ops.HostOps{});
        try t.expect(verdict == .go);
        // Points inside the pulse (high from 2 ns), where both branches
        // carry current and the zeroed spans hold flux.
        const t_min = 2.5e-9 + 1e-9 * @as(f64, @floatFromInt(got));
        if (sim.steps == steps or at.t_dev < t_min) continue;
        raw[got] = try a.alloc(f64, n_tape);
        qv[got] = try a.dupe(f64, ckt.q_vec[0..n]);
        want[got] = try a.alloc(f64, n_lt);
        got += 1;
        ckt.snapshotQTape(raw[got - 1]);
        host_ops.lteSnap(&ckt, want[got - 1], sim.lte_zero, rows);
    }
    // The spans are live: a zeroed entry was nonzero in the tape.
    var live = false;
    for (sim.lte_zero) |z| for (raw[N - 1][z[0]..z[1]]) |v| {
        live = live or v != 0;
    };
    try t.expect(live);

    const fix = try lanes_lte.table(a, n_tape, sim.lte_zero, rows);
    defer fix.deinit(a);
    const empty = try lanes_lte.table(a, n_tape, &.{}, &.{});
    defer empty.deinit(a);
    try t.expectEqual(@as(usize, 0), empty.dst.len);
    const n_hist = 3;
    const seed: f64 = -7.25;
    const ring = try a.alloc(f64, N * n_hist * n_lt);
    defer a.free(ring);
    @memset(ring, seed);
    const q = try a.alloc(f64, (n + 1) * N);
    defer a.free(q);
    @memset(q, 0);
    const slot0 = [N]usize{ 2, 0, 1 };
    for (0..N) |l| {
        for (raw[l], 0..) |v, j| ring[(slot0[l] * n_lt + j) * N + l] = v;
        for (qv[l], 0..) |v, i| q[i * N + l] = v;
        lk.lteFix(fix.dst.len, fix.dst, fix.src, q[l..], ring[slot0[l] * n_lt * N + l ..], N);
    }
    for (0..N) |l| for (0..n_hist) |k| for (0..n_lt) |j| {
        const cell = ring[(k * n_lt + j) * N + l];
        try expectBits(if (k == slot0[l]) want[l][j] else seed, cell);
    };
}
