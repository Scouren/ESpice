//! Tests of `price.zig`: the placement oracle (gpu/placement.tsv) by deck
//! name against the fixture calibration `price.machine.tsv`, determinism
//! across calls and threads, rowless batches, `interp`, and `opOnHost`.
//! Cites: docs/perf_research/08-placement.md sec. 6 step 3 (its oracle and
//! done-when).

const std = @import("std");
const assert = std.debug.assert;
const machine = @import("machine.zig");
const price = @import("price.zig");
const Machine = machine.Machine;
const Batch = price.Batch;
const Census = price.Census;
const Verdict = price.Verdict;
const place = price.place;
const interp = price.interp;
const margin = price.margin;
const sizes = machine.model_sizes;

/// The model of each GPU-eligible row of a placement.tsv deck, in its
/// `rows` order; null for a history line, which has no row. Read off the
/// decks' cards in tests/conformance/tests/netlist (R, V, M level 1 or 68,
/// O, P, Y).
const deck_models = [_]struct { []const u8, []const ?[]const u8 }{
    .{ "tran/ltra_tran_long_run_past_8192", &.{ "resistor", "vsource", null } },
    .{ "tran/cpl_tran_history_past_2048", &.{ "resistor", "vsource", null } },
    .{ "tran/bench_tline_cpl3_4_line", &.{ "resistor", "vsource", null } },
    .{ "tran/cpl_tran_even_mode", &.{ "resistor", "vsource", null } },
    .{ "tran/bench_tline_txl1_1_line", &.{ "mos1", "vsource", null } },
    .{ "tran/device_lossy_tline", &.{ "resistor", "vsource", null } },
    .{ "four/sine", &.{ "resistor", "vsource" } },
    .{ "dc/device_hisim2", &.{ "hisim2", "vsource" } },
    .{ "stress/scaling_parallel_inverters_100", &.{ "mos1", "mos1", "vsource" } },
    .{ "stress/scaling_parallel_inverters_2000", &.{ "mos1", "mos1", "vsource" } },
    .{ "stress/scaling_inverter_chain_256", &.{ "mos1", "mos1", "vsource" } },
    .{ "stress/scaling_inverter_chain_4k", &.{ "mos1", "mos1", "vsource" } },
    .{ "tran/txl_wide_batch_1000", &.{ null, "resistor", "vsource" } },
};

/// Decks the fixture places on the losing side, with the measured walls:
/// each must miss, so a fix that lands one fails until its line goes.
const known = [_][]const u8{
    // cpu 21.3 s, cuda 3.80 s. The rows price the host's evaluation at
    // 552 us; the run spends 3.06 ms per eval (21.3 s over 6,955). The
    // size error, 3.25x, is the largest of the oracle and sets `margin`.
    "stress/scaling_inverter_chain_4k",
    // cpu 6.60 s, cuda 3.44 s (2.42 s against 3.45 s under VerA 0.23,
    // d36ae56c). The TXL line has no row and stays on the host by policy
    // (sec. 7 q. 6); its resistors and source alone price the host.
    "tran/txl_wide_batch_1000",
};

/// One placement.tsv deck: its name, census inputs and measured walls.
const Deck = struct {
    name: []const u8,
    evals: f64,
    fixed_us: f64,
    batches: [8]Batch = undefined,
    n: usize = 0,
    /// Every row has a model row: the priced walls are the measured run's.
    full: bool = true,
    cpu_s: f64,
    cuda_s: f64,
};

// ---- private ----

/// The fixture machine: `price.machine.tsv`, rows in `arena`.
fn fixture(arena: std.mem.Allocator) !Machine {
    return machine.parse(arena, @embedFile("price.machine.tsv"));
}

/// A fixture image key: the model's name in ASCII, big-endian.
fn key(name: []const u8) u64 {
    assert(name.len <= 8);
    var k: u64 = 0;
    for (name) |ch| k = k << 8 | ch;
    return k;
}

/// Parses one placement.tsv line, mapping its rows to fixture images.
fn parseDeck(line: []const u8) !Deck {
    var f = std.mem.splitScalar(u8, line, '\t');
    const name = f.next().?;
    const models = for (deck_models) |row| {
        if (std.mem.eql(u8, row[0], name)) break row[1];
    } else return error.DeckWithoutModels;
    var d: Deck = .{ .name = name, .evals = try std.fmt.parseFloat(f64, f.next().?), .fixed_us = undefined, .cpu_s = undefined, .cuda_s = undefined };
    _ = f.next().?; // init_us: the fixture's start_ms prices it.
    d.fixed_us = try std.fmt.parseFloat(f64, f.next().?);
    var cells = std.mem.splitScalar(u8, f.next().?, ',');
    while (cells.next()) |cell| : (d.n += 1) {
        const count = try std.fmt.parseInt(u32, cell[0..std.mem.indexOfScalar(u8, cell, ':').?], 10);
        const model = models[d.n] orelse {
            d.full = false;
            d.batches[d.n] = .{ .image = 0, .count = count };
            continue;
        };
        d.batches[d.n] = .{ .image = key(model), .count = count };
    }
    try std.testing.expectEqual(models.len, d.n);
    d.cpu_s = try std.fmt.parseFloat(f64, f.next().?);
    d.cuda_s = try std.fmt.parseFloat(f64, f.next().?);
    return d;
}

/// `d`'s census: placement.tsv's recorded fixed cost past `eval_fixed_us`
/// as bus bytes, one host lane (as the walls were priced).
fn censusOf(d: *const Deck, c: *const machine.Constants) Census {
    return .{ .batches = d.batches[0..d.n], .evals = d.evals, .bus_bytes = (d.fixed_us - c.eval_fixed_us) * c.bus_b_per_us, .stage_bytes = 0, .lanes = 1 };
}

/// Every placement.tsv deck, in file order.
fn decks(out: []Deck) !usize {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("gpu/placement.tsv"), '\n');
    var n: usize = 0;
    var header = true;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        if (header) {
            header = false;
            continue;
        }
        out[n] = try parseDeck(line);
        n += 1;
    }
    return n;
}

/// `a` and `b` bit for bit.
fn same(a: Verdict, b: Verdict) bool {
    return a.device == b.device and a.priced == b.priced and
        @as(u64, @bitCast(a.cpu_us)) == @as(u64, @bitCast(b.cpu_us)) and
        @as(u64, @bitCast(a.gpu_us)) == @as(u64, @bitCast(b.gpu_us));
}

test "price.place: each placement.tsv deck lands on its measured winner, and margin bounds the error" {
    // Oracle: measured walls by deck name (gpu/placement.tsv, provenance
    // there), priced from a fixture file built from the tree's recorded
    // numbers (price.machine.tsv, provenance per row). A verdict is right
    // when the chosen side's wall is within 1.3x of the other's (the walls'
    // run-to-run wander, placement.machine.tsv's margin note). A `known`
    // deck must miss. `margin` must cover the 95th percentile of
    // |ln(priced / measured)| over the decks whose every row is priced.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try fixture(arena.allocator());
    const tie = 1.3;
    var all: [32]Deck = undefined;
    const n = try decks(&all);
    var errs: [32]f64 = undefined;
    var n_errs: usize = 0;
    var misses: usize = 0;
    for (all[0..n]) |*d| {
        const v = place(&m, &censusOf(d, &m.c));
        const right = if (v.device) tie * d.cpu_s >= d.cuda_s else tie * d.cuda_s >= d.cpu_s;
        const is_known = for (known) |k| {
            if (std.mem.eql(u8, k, d.name)) break true;
        } else false;
        if (right == is_known) std.debug.print("{s}: priced cpu={d:.1} gpu={d:.1} us per eval, {s}; measured cpu {d} s cuda {d} s\n", .{ d.name, v.cpu_us, v.gpu_us, if (v.device) "GPU" else "CPU", d.cpu_s, d.cuda_s });
        try std.testing.expect(right != is_known);
        misses += @intFromBool(is_known);
        if (!d.full) continue;
        try std.testing.expectEqual(@as(u32, @intCast(d.n)), v.priced);
        const priced = (m.c.start_ms * 1e3 + d.evals * v.gpu_us) / (d.evals * v.cpu_us);
        errs[n_errs] = @abs(@log(priced / (d.cuda_s / d.cpu_s)));
        n_errs += 1;
    }
    // Every marker names a deck of the table; an empty capture is a broken one.
    try std.testing.expectEqual(known.len, misses);
    try std.testing.expect(n_errs >= 5 and n > misses);
    std.mem.sort(f64, errs[0..n_errs], {}, std.sort.asc(f64));
    const at = (n_errs * 95 + 99) / 100 - 1;
    const needed = @exp(errs[at]);
    if (needed > margin) std.debug.print("margin {d} < {d:.3}, the oracle's 95th percentile error\n", .{ margin, needed });
    try std.testing.expect(needed <= margin);
}

test "price.place: twice and from 8 threads, the same verdict bit for bit" {
    // Oracle: the first call's verdicts (determinism is a metamorphic
    // relation: the same inputs on another call or thread give the same
    // bytes).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try fixture(arena.allocator());
    var all: [32]Deck = undefined;
    const n = try decks(&all);
    var want: [32]Verdict = undefined;
    for (all[0..n], want[0..n]) |*d, *w| w.* = place(&m, &censusOf(d, &m.c));
    for (all[0..n], want[0..n]) |*d, w| try std.testing.expect(same(w, place(&m, &censusOf(d, &m.c))));
    const Worker = struct {
        fn run(mm: *const Machine, ds: []const Deck, out: []Verdict) void {
            for (ds, out) |*d, *o| o.* = place(mm, &censusOf(d, &mm.c));
        }
    };
    var got: [8][32]Verdict = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &got) |*t, *g| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, all[0..n], g[0..n] });
    for (threads) |t| t.join();
    for (got) |g| for (want[0..n], g[0..n]) |w, v| try std.testing.expect(same(w, v));
}

test "price.place: a batch without a model row stays out of both sides" {
    // Oracle: a metamorphic relation: adding a batch whose image has no
    // row leaves the verdict as it was, and a census of such batches
    // alone is the host's.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try fixture(arena.allocator());
    const mos = [_]Batch{ .{ .image = key("mos1"), .count = 4000 }, .{ .image = key("mos1"), .count = 4000 } };
    const with = [_]Batch{ mos[0], mos[1], .{ .image = key("txl"), .count = 1000 } };
    const q: Census = .{ .batches = &mos, .evals = 1e5, .bus_bytes = 0, .stage_bytes = 0, .lanes = 1 };
    var q2 = q;
    q2.batches = &with;
    const a = place(&m, &q);
    try std.testing.expect(a.device);
    try std.testing.expectEqual(@as(u32, 2), a.priced);
    try std.testing.expect(same(a, place(&m, &q2)));
    var alone = q;
    alone.batches = with[2..];
    const b = place(&m, &alone);
    try std.testing.expect(!b.device);
    try std.testing.expectEqual(@as(u32, 0), b.priced);
}

test "price.opOnHost: under p1 an operating point under gpu_lanes is priced, not barred" {
    // Oracle: hand arithmetic on the fixture (start_ms 350, eval_fixed_us
    // 40, bus_b_per_us 11,000; hisim2's rows; M = 3.3 written out), one OP
    // of 30 evals (`dispatch.expectedEvals(.op)`), 1.1 MB over the bus.
    // - 16,384 hisim2: cpu 163,840 us, gpu 40 + 21,896 + 100 = 22,036 us;
    //   30 * (163,840 - 72,718.8) = 2,733,636 > 350,000: device, where
    //   HEAD's gpu_lanes rule keeps it on the host.
    // - 1,024 hisim2: cpu 10,240, gpu 40 + 2,576 + 100 = 2,716;
    //   30 * 1,277.2 = 38,316 < 350,000: host. The same census at 1,000
    //   evals (a transient) saves 1,277,200: device.
    try std.testing.expectEqual(@as(f64, 3.3), margin);
    try std.testing.expect(price.opOnHost(false, true, true));
    try std.testing.expect(!price.opOnHost(true, true, true));
    try std.testing.expect(!price.opOnHost(false, true, false) and !price.opOnHost(false, false, true));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try fixture(arena.allocator());
    const big = [_]Batch{.{ .image = key("hisim2"), .count = 16_384 }};
    const small = [_]Batch{.{ .image = key("hisim2"), .count = 1_024 }};
    var q: Census = .{ .batches = &big, .evals = 30, .bus_bytes = 1.1e6, .stage_bytes = 0, .lanes = 1 };
    const a = place(&m, &q);
    try std.testing.expect(a.device);
    try std.testing.expectApproxEqRel(@as(f64, 163_840), a.cpu_us, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 22_036), a.gpu_us, 1e-12);
    q.batches = &small;
    const b = place(&m, &q);
    try std.testing.expect(!b.device);
    try std.testing.expectApproxEqRel(@as(f64, 10_240), b.cpu_us, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 2_716), b.gpu_us, 1e-12);
    q.evals = 1_000;
    try std.testing.expect(place(&m, &q).device);
}

test "price.interp: a power law between sizes, proportional past the last" {
    // Oracle: values by hand on a power law and on a line.
    const row = [4]f64{ 1, 64, 1024, 16384 };
    // Exact at the sizes; a row proportional to count stays proportional.
    for (sizes, row) |s, v| try std.testing.expectApproxEqRel(v, interp(row, s), 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 256), interp(row, 256), 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 32768), interp(row, 32768), 1e-12);
    // Halfway in log size between 64 and 1024 (256): the geometric mean.
    const flat = [4]f64{ 4, 4, 100, 100 };
    try std.testing.expectApproxEqRel(@as(f64, 20), interp(flat, 256), 1e-12);
    // A bracket with a zero falls back to a line in log size.
    const zero = [4]f64{ 0, 8, 8, 8 };
    try std.testing.expectApproxEqRel(@as(f64, 4), interp(zero, 8), 1e-12);
}
