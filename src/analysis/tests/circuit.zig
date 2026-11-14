//! Circuit pattern, plane-kernel, stamp and lifecycle tests. Oracles: a
//! comparison sort for the radix-sorted CSC pattern, the scalar
//! expression for the plane kernel, a full stamp for the baseline-seeded Newton stamp,
//! the serial stamp for the threaded ones (bit for bit), the serial load
//! for the A that ParEval's lever C7 forms (bit for bit), the plane accessors
//! against each other, and `checkAllAllocationFailures` for setup leaks.

const impl = @import("../Circuit.zig");
const combinePlanes = impl.combinePlanes;
const std = @import("std");
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const Prepared = @import("device").Circuit;
const models = @import("models");
const types = @import("../types.zig");
const ParEval = @import("../par_eval.zig").ParEval;
const Levers = @import("../par_eval.zig").Levers;
const integrator = @import("../tran/integrator.zig");
const Companion = integrator.Companion;
const circuit_devices = @import("../circuit_devices.zig");
const exec_config = @import("../exec_config.zig");
const par_lanes = @import("../par_lanes.zig");
const Batch = @import("device").abi.Batch;
const t = std.testing;

/// The planes, cell for cell; the trash cells hold no answer.
const Snap = struct { g: []f64, c: []f64, rhs: []f64, q: []f64 };
const take = struct {
    fn f(c: *const types.Circuit) !Snap {
        return .{
            .g = try t.allocator.dupe(f64, c.g_vals[0..c.nnz]),
            .c = try t.allocator.dupe(f64, c.c_vals[0..c.nnz]),
            .rhs = try t.allocator.dupe(f64, c.rhs[0..c.n]),
            .q = try t.allocator.dupe(f64, c.q_vec[0..c.n]),
        };
    }
    fn free(s: Snap) void {
        inline for (.{ s.g, s.c, s.rhs, s.q }) |p| t.allocator.free(p);
    }
    fn expectSame(want: Snap, c: *const types.Circuit) !void {
        try t.expectEqualSlices(f64, want.g, c.g_vals[0..c.nnz]);
        try t.expectEqualSlices(f64, want.c, c.c_vals[0..c.nnz]);
        try t.expectEqualSlices(f64, want.rhs, c.rhs[0..c.n]);
        try t.expectEqualSlices(f64, want.q, c.q_vec[0..c.n]);
    }
    /// Bitwise, so a -0 against a +0 or a NaN payload shows.
    fn expectBits(want: Snap, c: *const types.Circuit) !void {
        try expectBitsOf(want.g, c.g_vals[0..c.nnz]);
        try expectBitsOf(want.c, c.c_vals[0..c.nnz]);
        try expectBitsOf(want.rhs, c.rhs[0..c.n]);
        try expectBitsOf(want.q, c.q_vec[0..c.n]);
    }
};

// ---- private ----

/// 1 V into `stages` sections of series R, each with a C and a diode to
/// ground: constant-Jacobian, charge and nonlinear batches in one pattern.
fn ladder(lib: *const Library, stages: usize) !Prepared {
    var b = try Builder.init(t.allocator, lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ vin, types.GROUND });
    var prev = vin;
    for (0..stages) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 }, &.{}, .{ mid, types.GROUND });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14, .cjo = 1e-12 }, &.{}, .{ mid, types.GROUND });
        prev = mid;
    }
    return b.compile();
}

/// A state with every row distinct and the diodes forward-biased.
fn ramp(gpa: std.mem.Allocator, n: u32) ![]f64 {
    const x = try gpa.alloc(f64, n);
    for (x, 0..) |*v, i| v.* = 0.05 * @as(f64, @floatFromInt(i));
    x[types.GROUND] = 0;
    return x;
}

fn expectBitsOf(want: []const f64, got: []const f64) !void {
    try t.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
}

/// Equal up to reassociation of a few stamps per cell.
fn expectClose(expected: []const f64, actual: []const f64) !void {
    try t.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try t.expectApproxEqAbs(e, a, 1e-12 * (1 + @abs(e)));
}

/// `Census` by a walk of the tapes, for the census test: each chunk's
/// positions from its instance range and the tape's own stride, each
/// cell's chunks collected position by position. `n_cells` is the ground
/// (trash) index.
fn walkCensus(batches: []const Batch, tasks: []const par_lanes.EvalTask, n_cells: u32, rows: bool) !par_lanes.Census {
    const none = std.math.maxInt(u32);
    const mixed = none - 1;
    const owner = try t.allocator.alloc(u32, n_cells);
    defer t.allocator.free(owner);
    const count = try t.allocator.alloc(u64, n_cells);
    defer t.allocator.free(count);
    @memset(owner, none);
    @memset(count, 0);
    for (tasks, 0..) |task, i| {
        const b = batches[task.batch];
        const tapes = b.hooks.scatter_tapes(b.ctx);
        const tape = if (rows) tapes.rows else tapes.slots;
        const k = tape.len / b.count;
        for (tape[task.first * k .. task.last * k]) |cell| {
            if (cell == n_cells) continue;
            count[cell] += 1;
            owner[cell] = if (owner[cell] == none or owner[cell] == i) @intCast(i) else mixed;
        }
    }
    var c: par_lanes.Census = .{};
    for (owner, count) |o, k| {
        if (o == none) continue;
        c.total += k;
        if (o != mixed) c.single += k;
    }
    return c;
}

fn setUpEverything(gpa: std.mem.Allocator, prepared: *const Prepared) !void {
    var ckt = try types.Circuit.instantiate(prepared, gpa);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    _ = try ckt.workspace();
    _ = try ckt.collectParams();
    const saved = try ckt.saveState(gpa);
    saved.deinit(gpa);
    var par = try ParEval.init(gpa, t.io, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, 3, .{});
    par.deinit();
    // Every lever's tables (N8's affinity, C7's A, N3's verdicts) fail and
    // free cleanly too.
    var par_on = try ParEval.init(gpa, t.io, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, 3, .{ .c6 = true, .c7 = true, .n8 = true, .n3 = true });
    par_on.deinit();
    var copy = try types.Circuit.fromSnapshot(prepared, &ckt, gpa);
    copy.deinit();
    // Last: the move empties `ckt`, whose deferred deinit then frees nothing.
    var moved = try types.Circuit.fromSnapshotMove(prepared, &ckt, gpa);
    moved.deinit();
}

test "pattern CSC matches comparison sort across radix digits" {
    const PatternBuilder = @import("device").abi.PatternBuilder;
    const gpa = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x5041545445524e);
    for ([_]u32{ 1, 31, 65537, 131073 }) |n| {
        for ([_]usize{ 0, 1, 63, 64, 65, 257 }) |count| {
            var pattern: PatternBuilder = .{};
            defer pattern.deinit(gpa);
            var unique = std.AutoHashMap(u64, void).init(gpa);
            defer unique.deinit();
            var previous: u64 = 0;
            for (0..count) |i| {
                const row = if (i % 7 == 0) n - 1 else random.random().intRangeLessThan(u32, 0, n);
                const occupied_columns = [_]u32{ n - 1, 0, n / 2 };
                const col = occupied_columns[i % occupied_columns.len];
                const key = if (i % 4 == 1) previous else (@as(u64, col) << 32) | row;
                try pattern.add(gpa, @truncate(key), @intCast(key >> 32));
                try unique.put(key, {});
                previous = key;
            }
            const expected = try gpa.alloc(u64, unique.count());
            defer gpa.free(expected);
            var keys = unique.keyIterator();
            for (expected) |*key| key.* = keys.next().?.*;
            std.mem.sortUnstable(u64, expected, {}, std.sort.asc(u64));

            var col_ptr: []u32 = undefined;
            var row_idx: []u32 = undefined;
            const nnz = try pattern.toCsc(gpa, gpa, n, &col_ptr, &row_idx);
            defer gpa.free(col_ptr);
            defer gpa.free(row_idx);
            try std.testing.expectEqual(@as(u32, @intCast(expected.len)), nnz);
            try std.testing.expectEqual(expected.len, row_idx.len);
            try std.testing.expectEqual(@as(usize, n) + 1, col_ptr.len);
            try std.testing.expectEqual(@as(u32, 0), col_ptr[0]);
            var p: usize = 0;
            for (0..n) |col| {
                while (p < expected.len and expected[p] >> 32 == col) : (p += 1) {
                    try std.testing.expectEqual(@as(u32, @truncate(expected[p])), row_idx[p]);
                }
                try std.testing.expectEqual(@as(u32, @intCast(p)), col_ptr[col + 1]);
            }
            try std.testing.expectEqual(expected.len, p);
        }
    }
}

test "combinePlanes equals the scalar g + alpha*c at every length, offset and alias" {
    var random = std.Random.DefaultPrng.init(0x4321);
    const len_max = 200;
    var g: [len_max + 3]f64 = undefined;
    var c: [g.len]f64 = undefined;
    var out: [g.len]f64 = undefined;
    for (&g, &c) |*gv, *cv| {
        gv.* = random.random().float(f64) - 0.5;
        cv.* = random.random().float(f64) - 0.5;
    }
    // Specials ride through bit for bit: NaN, both infinities, -0, a denormal.
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), -0.0, 4.9e-324 }, 0..) |v, k| {
        g[7 * k + 1] = v;
        c[11 * k + 2] = v;
    }
    for (0..len_max + 1) |n| for (0..3) |off| for ([_]f64{ 0, -1, 0.125, 1e12 }) |alpha| {
        const gs = g[off..][0..n];
        const cs = c[off..][0..n];
        combinePlanes(out[off..][0..n], gs, cs, alpha);
        for (out[off..][0..n], gs, cs) |o, gv, cv| {
            const e = gv + alpha * cv;
            try std.testing.expectEqual(@as(u64, @bitCast(e)), @as(u64, @bitCast(o)));
        }
        // `out` aliasing `g` gives the same bits.
        var alias = g;
        combinePlanes(alias[off..][0..n], alias[off..][0..n], cs, alpha);
        try std.testing.expectEqualSlices(u64, @ptrCast(out[off..][0..n]), @ptrCast(alias[off..][0..n]));
    };
}

test "a Newton stamp seeded from the baseline equals a full stamp" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 3);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const nnz = ckt.nnz;
    const n = ckt.n;

    ckt.eval(x, 0);
    const g = try t.allocator.dupe(f64, ckt.g_vals[0..nnz]);
    defer t.allocator.free(g);
    const c = try t.allocator.dupe(f64, ckt.c_vals[0..nnz]);
    defer t.allocator.free(c);
    const rhs = try t.allocator.dupe(f64, ckt.rhs[0..n]);
    defer t.allocator.free(rhs);
    const q = try t.allocator.dupe(f64, ckt.q_vec[0..n]);
    defer t.allocator.free(q);

    try ckt.computeBaseline();
    try t.expect(ckt.has_baseline);
    try t.expect(!ckt.q_fresh);
    ckt.evalNewton(x, 0);
    try expectClose(g, ckt.g_vals[0..nnz]);
    try expectClose(c, ckt.c_vals[0..nnz]);
    try expectClose(rhs, ckt.rhs[0..n]);
    try expectClose(q, ckt.q_vec[0..n]);
    // A second baseline is a no-op that leaves the planes alone.
    try ckt.computeBaseline();
    try expectClose(g, ckt.g_vals[0..nnz]);
}

test "threaded stamps equal serial" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 6);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const nnz = ckt.nnz;
    const n = ckt.n;

    ckt.eval(x, 0);
    const full = try take.f(&ckt);
    defer take.free(full);
    ckt.evalNewton(x, 0);
    const newton = try take.f(&ckt);
    defer take.free(newton);
    // Serial charge-only stamp: bit for bit what `eval` left.
    ckt.evalQ(x, 0);
    try t.expectEqualSlices(f64, full.q, ckt.q_vec[0..n]);
    // The scalar accepted-point path fuses charge and state work; it must
    // use the same cache arithmetic as evalQ and the threaded path.
    ckt.land_rejects = true;
    defer ckt.land_rejects = false;
    _ = ckt.updateStates(x);
    try t.expectEqualSlices(f64, full.q, ckt.q_vec[0..n]);

    // 0 asks for one lane; 24 is more lanes than the 19 instances. Every
    // pass twice, so a position left stale by the last pass would show.
    for ([_]u32{ 0, 1, 2, 3, 5, 8, 24 }) |lanes| {
        var par = try ParEval.init(t.allocator, t.io, ckt.batches, nnz, n, ckt.has_charge, lanes, .{});
        defer par.deinit();
        ckt.par_eval = &par;
        defer ckt.par_eval = null;
        for (0..2) |_| {
            ckt.eval(x, 0);
            try take.expectSame(full, &ckt);
            // The Newton pass skips the constant stamps the full pass made.
            ckt.evalNewton(x, 0);
            try take.expectSame(newton, &ckt);
            @memset(ckt.q_vec, std.math.nan(f64));
            ckt.evalQ(x, 0);
            try t.expectEqualSlices(f64, full.q, ckt.q_vec[0..n]);
            _ = ckt.updateStates(x);
            try t.expectEqualSlices(f64, full.q, ckt.q_vec[0..n]);
        }
    }
}

test "ParEval levers C6, C7 and N8 keep the serial planes and the serial load" {
    // Oracle: the serial stamp (no ParEval) for the planes, and the serial
    // load (`combineGC` over the serial Newton planes) for A, both bitwise.
    // Each lever alone, all three, and none, at 1, 2, 3 and 8 lanes. Every
    // pass runs twice against the same serial bytes, so two runs at one
    // lane count give the same bytes (determinism) and a staging position
    // left stale by the first would show.
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 6);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    try t.expect(ckt.has_charge);
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const nnz = ckt.nnz;
    const n = ckt.n;
    // An ag0-sized alpha whose products round.
    const alpha: f64 = 1.0 / 3e-9;

    ckt.eval(x, 0);
    const full = try take.f(&ckt);
    defer take.free(full);
    ckt.evalNewton(x, 0);
    const newton = try take.f(&ckt);
    defer take.free(newton);
    const a_want = try t.allocator.alloc(f64, nnz);
    defer t.allocator.free(a_want);
    ckt.combineGC(alpha, a_want);
    const out = try t.allocator.alloc(f64, nnz);
    defer t.allocator.free(out);

    const combos = [_]Levers{ .{}, .{ .c6 = true }, .{ .c7 = true }, .{ .n8 = true }, .{ .c6 = true, .c7 = true, .n8 = true } };
    for ([_]u32{ 1, 2, 3, 8 }) |lanes| for (combos) |levers| {
        var par = try ParEval.init(t.allocator, t.io, ckt.batches, nnz, n, ckt.has_charge, lanes, levers);
        defer par.deinit();
        try t.expectEqual(levers.c7, par.formsA());
        ckt.par_eval = &par;
        defer ckt.par_eval = null;
        ckt.reduce_a = par.formsA();
        defer ckt.reduce_a = false;
        for (0..2) |_| {
            ckt.eval(x, 0);
            try take.expectBits(full, &ckt);
            ckt.evalNewton(x, 0);
            try take.expectBits(newton, &ckt);
            // The companion path: the planes as `evalNewton`, and A as the
            // serial load, formed in the reduce under C7.
            @memset(out, std.math.nan(f64));
            ckt.evalNewtonGC(x, 0, alpha);
            try take.expectBits(newton, &ckt);
            const a = ckt.newtonGC(alpha, out);
            try t.expectEqual(levers.c7, a.ptr != out.ptr);
            try expectBitsOf(a_want, a);
            // Handed out once: the next call combines into `out`.
            const again = ckt.newtonGC(alpha, out);
            try t.expect(again.ptr == out.ptr);
            try expectBitsOf(a_want, again);
            @memset(ckt.q_vec, std.math.nan(f64));
            ckt.evalQ(x, 0);
            try expectBitsOf(full.q, ckt.q_vec[0..n]);
            _ = ckt.updateStates(x);
            try expectBitsOf(full.q, ckt.q_vec[0..n]);
        }
    };
}

test "C7 adds the companion rows in the reduce, bitwise the serial companionAt" {
    // Oracle: the serial assemble, `evalNewtonGC` then `companionAt` over
    // every row (`integrator.Hook(null).assemble` with C7 off), for rhs and
    // the planes, and `combineGC` for A; bitwise, per method, at 1, 2, 3 and
    // 8 lanes, each pass twice (determinism).
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 6);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .t = 1e-9, .dt = 1e-9, .kind = .tran });
    try ckt.computeBaseline();
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const nnz = ckt.nnz;
    const n = ckt.n;
    const alpha: f64 = 1.0 / 3e-9;
    // Histories with every row distinct, so a row shifted by one shows.
    const hist = try t.allocator.alloc(f64, 3 * n);
    defer t.allocator.free(hist);
    for (hist, 0..) |*h, i| h.* = 1e-12 * (0.3 + @as(f64, @floatFromInt(i)) / 7.0);
    const q1 = hist[0..n];
    const q2 = hist[n .. 2 * n];
    const ip = hist[2 * n ..];
    const cf: integrator.Coeffs = .{ .ag0 = alpha, .ag2 = 0.37 * alpha, .ag1 = 0.9 };
    const a_want = try t.allocator.alloc(f64, nnz);
    defer t.allocator.free(a_want);
    const out = try t.allocator.alloc(f64, nnz);
    defer t.allocator.free(out);

    const Method = @FieldType(Companion, "method");
    inline for (.{ Method.backward_euler, Method.trapezoidal, Method.gear_2, Method.gear_3 }) |m| {
        ckt.evalNewtonGC(x, 1e-9, alpha);
        ckt.combineGC(alpha, a_want);
        integrator.companionAt(m, true, ckt.rhs[0..n], ckt.q_vec[0..n], q1, q2, ip, cf);
        const want = try take.f(&ckt);
        defer take.free(want);
        const comp: Companion = .{ .method = m, .q1 = q1, .q2 = q2, .i_prev = ip, .c = cf };
        for ([_]u32{ 1, 2, 3, 8 }) |lanes| for ([_]Levers{ .{ .c7 = true }, .{ .c6 = true, .c7 = true, .n8 = true } }) |levers| {
            var par = try ParEval.init(t.allocator, t.io, ckt.batches, nnz, n, ckt.has_charge, lanes, levers);
            defer par.deinit();
            ckt.par_eval = &par;
            defer ckt.par_eval = null;
            ckt.reduce_a = true;
            defer ckt.reduce_a = false;
            for (0..2) |_| {
                ckt.evalNewtonGCWith(x, 1e-9, alpha, comp);
                try take.expectBits(want, &ckt);
                try expectBitsOf(a_want, ckt.newtonGC(alpha, out));
            }
        };
    }
}

test "N3 on ParEval: the accept pass's charges, tape and states equal today's" {
    // Oracle: today's serial accept (no ParEval, no tracking): `evalQ` and
    // the state pass at the accepted x. Bitwise after every accept: q_vec,
    // the LTE tape, the reject time; the states through the next Newton
    // eval's planes, which read them. At 1, 2, 3 and 8 lanes. The tracked
    // pass must also have engaged: every charge batch's ranges clean.
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 4);
    defer prepared.deinit();
    for ([_]u32{ 1, 2, 3, 8 }) |lanes| {
        var ref = try types.Circuit.instantiate(&prepared, t.allocator);
        defer ref.deinit();
        var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
        defer ckt.deinit();
        for ([_]*types.Circuit{ &ref, &ckt }) |c| {
            c.setSimState(.{ .t = 0, .dt = 1e-9, .kind = .tran });
            try c.computeBaseline();
            c.land_rejects = true;
        }
        ckt.knobs.perf.n3 = true;
        const n = ckt.n;
        const x = try ramp(t.allocator, n);
        defer t.allocator.free(x);
        const tape_len = ref.qTapeLen();
        const tapes = try t.allocator.alloc(f64, 2 * tape_len);
        defer t.allocator.free(tapes);

        var par = try ParEval.init(t.allocator, t.io, ckt.batches, ckt.nnz, n, ckt.has_charge, lanes, .{ .n3 = true });
        defer par.deinit();
        ckt.par_eval = &par;
        defer ckt.par_eval = null;
        circuit_devices.setChargeTracking(&ckt, true);
        defer circuit_devices.setChargeTracking(&ckt, false);

        for (0..4) |k| {
            const tk = 1e-9 * @as(f64, @floatFromInt(k + 1));
            for (x[1..], 1..) |*v, i| v.* = 0.05 * @as(f64, @floatFromInt(i)) * (1 + 0.01 * @as(f64, @floatFromInt(k)));
            for ([_]*types.Circuit{ &ref, &ckt }) |c| {
                c.setSimState(.{ .t = tk, .dt = 1e-9, .kind = .tran });
                c.evalNewton(x, tk);
            }
            const want = try take.f(&ref);
            defer take.free(want);
            try take.expectBits(want, &ckt);
            for (ckt.batches, 0..) |b, bi| if (b.has_charge) try t.expect(par.chargesClean(bi));
            _ = ref.updateStates(x);
            _ = ckt.updateStates(x);
            try expectBitsOf(ref.q_vec[0..n], ckt.q_vec[0..n]);
            ref.snapshotQTape(tapes[0..tape_len]);
            ckt.snapshotQTape(tapes[tape_len..]);
            try expectBitsOf(tapes[0..tape_len], tapes[tape_len..]);
            try t.expectEqual(ref.reject_at, ckt.reject_at);
            try t.expect(ckt.q_fresh);
            _ = ref.stateCtl(.commit);
            _ = ckt.stateCtl(.commit);
        }
    }
}

test "#253: a lane loan returns exactly the lanes past the LU's admitted width" {
    // Oracle: the arithmetic written out per case. `held` borrowed lanes
    // plus the query's own; the LU admitted `admitted` lanes in all. Back
    // to the pool: `back`; still held: `kept`; `lu_threads` = kept + 1,
    // never below one lane and never above what is held.
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    const ws = try ckt.workspace();
    const Case = struct { held: u32, admitted: u32, back: u32, kept: u32 };
    const cases = [_]Case{
        // stress/scaling_rc_ladder_100k: the subtree plan declined.
        .{ .held = 7, .admitted = 1, .back = 7, .kept = 0 },
        .{ .held = 7, .admitted = 4, .back = 4, .kept = 3 },
        .{ .held = 7, .admitted = 8, .back = 0, .kept = 7 },
        // Fewer lanes held than admitted (the pool was short): keep them all.
        .{ .held = 3, .admitted = 8, .back = 0, .kept = 3 },
        // C6's wider cap, `per_query_wide - 1` borrowed.
        .{ .held = 15, .admitted = 16, .back = 0, .kept = 15 },
        .{ .held = 15, .admitted = 2, .back = 14, .kept = 1 },
        .{ .held = 0, .admitted = 1, .back = 0, .kept = 0 },
    };
    try t.expectEqual(@as(u32, 15), exec_config.ThreadPool.per_query_wide - 1);
    for (cases) |c| {
        var pool: exec_config.ThreadPool = .{ .free = .init(0) };
        var borrowed = c.held;
        var loan: exec_config.LaneLoan = .{ .pool = &pool, .held = &borrowed };
        ckt.lane_loan = &loan;
        ckt.solver_execution.lu_threads = @intCast(c.held + 1);
        // Before the LU judges an epoch: nothing moves, the loan stays.
        ws.slv.admitted_lanes = 0;
        circuit_devices.settleLaneLoan(&ckt, &ws.slv);
        try t.expectEqual(@as(?*exec_config.LaneLoan, &loan), ckt.lane_loan);
        try t.expectEqual(c.held, borrowed);
        try t.expectEqual(@as(u32, 0), pool.free.load(.monotonic));
        ws.slv.admitted_lanes = c.admitted;
        circuit_devices.settleLaneLoan(&ckt, &ws.slv);
        try t.expectEqual(c.back, pool.free.load(.monotonic));
        try t.expectEqual(c.kept, borrowed);
        try t.expectEqual(@as(u8, @intCast(c.kept + 1)), ckt.solver_execution.lu_threads);
        try t.expectEqual(@as(?*exec_config.LaneLoan, null), ckt.lane_loan);
        try t.expectEqual(c.held, c.back + c.kept);
    }
}

test "C7 step 2: the census counts what a walk of the tapes counts" {
    // Oracle: a second count by another route (`walkCensus`): no gather,
    // no chunk starts, no search. The ladder's batches stamp shared node
    // cells from different chunks, and a resistor's off-diagonal cells from
    // one, so each count is strictly between none and all.
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 6);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    for ([_]u32{ 1, 2, 3, 8 }) |lanes| {
        var par = try ParEval.init(t.allocator, t.io, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, lanes, .{});
        defer par.deinit();
        const got = try par.census();
        try t.expectEqual(try walkCensus(ckt.batches, par.tasks, ckt.nnz, false), got.slots);
        try t.expectEqual(try walkCensus(ckt.batches, par.tasks, ckt.n, true), got.rows);
        try t.expect(got.slots.single > 0 and got.slots.single < got.slots.total);
        try t.expect(got.rows.single < got.rows.total);
    }
}

test "C6 step 3: a query that borrows asks for per_query_wide lanes" {
    // Oracle: the rule written out per case. lanePlan wants 1 (no borrow)
    // or per_query (8); C6 widens only the borrowing want, to 16.
    const P = exec_config.ThreadPool;
    try t.expectEqual(@as(u32, 1), P.queryWant(1, false));
    try t.expectEqual(@as(u32, 8), P.queryWant(8, false));
    try t.expectEqual(@as(u32, 1), P.queryWant(1, true));
    try t.expectEqual(@as(u32, 16), P.queryWant(8, true));
}

test "a threaded pass finishes on lane 0 alone when no worker is ever scheduled" {
    // Every core busy can leave a pass's workers unscheduled throughout. The
    // barriers count finished items, not lanes, so lane 0 runs them all.
    // Waiting on every lane hung here, and stalled each pass of
    // stress/vacask_graetz at 8 threads on 4 cores past 900 s.
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 6);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    ckt.evalNewton(x, 0);
    const serial = try t.allocator.dupe(f64, ckt.rhs[0..ckt.n]);
    defer t.allocator.free(serial);

    var par = try ParEval.init(t.allocator, t.io, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, 4, .{});
    defer par.deinit();
    // `ring` spawns nothing, so no worker ever runs; `deinit` joins none.
    par.started = true;
    defer par.started = false;
    ckt.par_eval = &par;
    defer ckt.par_eval = null;
    const x_new = try t.allocator.dupe(f64, x);
    defer t.allocator.free(x_new);
    for (0..3) |_| {
        ckt.evalNewton(x, 0);
        try t.expectEqualSlices(u64, @ptrCast(serial), @ptrCast(ckt.rhs[0..ckt.n]));
        _ = ckt.applyLimits(x_new, x);
        ckt.clearLimits();
        _ = ckt.updateStates(x);
    }
}

test "a bypass replay on an instance with tied terminals: serial equals the lanes, and a fresh eval" {
    // A depletion MOS with gate, source and bulk on one node: mos1 writes
    // no gate row, so the gate shares the source's global row. Recording
    // tagged the source's residual with the gate's empty Jacobian row, and
    // the serial replay dropped the first-order move the staged replay made
    // (tran/device_mos6_inverter differed between 1 and 2 threads).
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const a = try b.addNode();
    const d = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 5 }, &.{}, .{ a, types.GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ d, types.GROUND });
    try b.addDevice(models.mos1, "", &.{ .vto = -1 }, &.{}, .{ d, a, a, a });
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    const x0 = try t.allocator.alloc(f64, ckt.n);
    defer t.allocator.free(x0);
    @memset(x0, 0);
    x0[a] = 5;
    x0[d] = 4.5;
    // Within the replay tolerances: 1e-4 V against reltol * 4.5 V.
    const x1 = try t.allocator.dupe(f64, x0);
    defer t.allocator.free(x1);
    x1[d] += 1e-4;
    const tol: @import("device").abi.BypassTol = .{ .reltol = 1e-3, .vntol = 1e-6, .abstol = 1e-12 };
    const n = ckt.n;

    // The oracle: a fresh evaluation at x1, which a first-order replay
    // matches to second order.
    ckt.beginSolve();
    ckt.advanceIteration(x0);
    ckt.evalNewton(x1, 0);
    const fresh = try t.allocator.dupe(f64, ckt.rhs[0..n]);
    defer t.allocator.free(fresh);
    ckt.evalNewton(x0, 0);
    const moved = try t.allocator.dupe(f64, ckt.rhs[0..n]);
    defer t.allocator.free(moved);

    ckt.setBypass(tol);
    defer ckt.setBypass(null);
    ckt.evalNewton(x0, 0);
    ckt.evalNewton(x1, 0);
    const serial = try t.allocator.dupe(f64, ckt.rhs[0..n]);
    defer t.allocator.free(serial);
    for (fresh, moved, serial) |f, m, r| try t.expect(@abs(r - f) <= 1e-3 * @abs(f - m) + 1e-15);

    for ([_]u32{ 1, 2, 3 }) |lanes| {
        var par = try ParEval.init(t.allocator, t.io, ckt.batches, ckt.nnz, n, ckt.has_charge, lanes, .{});
        defer par.deinit();
        ckt.par_eval = &par;
        defer ckt.par_eval = null;
        // The staged planes are other cells: the first pass records afresh.
        ckt.evalNewton(x0, 0);
        ckt.evalNewton(x1, 0);
        try t.expectEqualSlices(u64, @ptrCast(serial), @ptrCast(ckt.rhs[0..n]));
    }
}

test "linearize reuses the planes only for the same x_op until a writer runs" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const y = try t.allocator.dupe(f64, x);
    defer t.allocator.free(y);
    const slot = ckt.diag_slots[1];

    ckt.linearize(x);
    try t.expect(ckt.lin.valid);
    const stamped = ckt.g_vals[slot];
    ckt.g_vals[slot] = 12345;
    ckt.linearize(x);
    try t.expectEqual(@as(f64, 12345), ckt.g_vals[slot]);
    // Same values, different slice: a different x_op, so it re-stamps.
    ckt.linearize(y);
    try t.expectEqual(stamped, ckt.g_vals[slot]);

    ckt.linearize(y);
    ckt.eval(y, 0);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.evalQ(y, 0);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.evalNewton(y, 0);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    try ckt.setCircuitTemp(50);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    try ckt.recompute();
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    try ckt.recomputeType(ckt.batch_types[0]);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.beginSolve();
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.advanceIteration(y);
    try t.expect(!ckt.lin.valid);
    const saved = try ckt.saveState(t.allocator);
    defer saved.deinit(t.allocator);
    ckt.linearize(y);
    ckt.restoreState(saved);
    try t.expect(!ckt.lin.valid);
}

test "combineGC, gcAt, denseG and findSlot agree on every pattern entry" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    ckt.eval(x, 0);
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;

    const out = try t.allocator.alloc(f64, nnz + 1);
    defer t.allocator.free(out);
    out[nnz] = -7;
    ckt.combineGC(1e3, out);
    try t.expectEqual(@as(f64, -7), out[nnz]);
    const dense = try t.allocator.alloc(f64, n * n);
    defer t.allocator.free(dense);
    ckt.denseG(dense);
    const in_pattern = try t.allocator.alloc(bool, n * n);
    defer t.allocator.free(in_pattern);
    @memset(in_pattern, false);
    for (0..n) |col| for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |p| {
        const row = ckt.row_idx[p];
        try t.expectEqual(ckt.gcAt(1e3, @intCast(p)), out[p]);
        try t.expectEqual(@as(?u32, @intCast(p)), ckt.findSlot(row, @intCast(col)));
        try t.expectEqual(ckt.g_vals[p], dense[row * n + col]);
        in_pattern[row * n + col] = true;
    };
    for (0..n) |row| for (0..n) |col| {
        const hit = ckt.findSlot(@intCast(row), @intCast(col)) != null;
        try t.expectEqual(in_pattern[row * n + col], hit);
        if (!hit) try t.expectEqual(@as(f64, 0), dense[row * n + col]);
    };
}

test "snapshots copy or move device state and refuse a foreign topology" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var other = try ladder(&lib, 3);
    defer other.deinit();
    var source = try types.Circuit.instantiate(&prepared, t.allocator);
    defer source.deinit();
    source.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, source.n);
    defer t.allocator.free(x);
    source.eval(x, 0);
    const g = try t.allocator.dupe(f64, source.g_vals);
    defer t.allocator.free(g);

    try t.expectError(error.IncompatibleDependency, types.Circuit.fromSnapshot(&other, &source, t.allocator));
    try t.expectError(error.IncompatibleDependency, types.Circuit.fromSnapshotMove(&other, &source, t.allocator));
    var copy = try types.Circuit.fromSnapshot(&prepared, &source, t.allocator);
    defer copy.deinit();
    copy.eval(x, 0);
    try t.expectEqualSlices(f64, g, copy.g_vals);

    var moved = try types.Circuit.fromSnapshotMove(&prepared, &source, t.allocator);
    defer moved.deinit();
    // The source keeps nothing, and its own deinit frees nothing twice.
    try t.expectEqual(@as(usize, 0), source.batches.len);
    try t.expectEqual(@as(usize, 0), source.g_vals.len);
    source.release();
    moved.eval(x, 0);
    try t.expectEqualSlices(f64, g, moved.g_vals);
    try moved.refuseDigital("test");
}

test "a baseline that failed to allocate can be retried" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 1);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    // Allocation 0 is g_base, 1 c_base, 2 the zero state. Failing 1 used to
    // keep g_base, so the retry skipped the allocation and stamped into an
    // empty c_base.
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        ckt.gpa = failing.allocator();
        try t.expectError(error.OutOfMemory, ckt.computeBaseline());
        ckt.gpa = t.allocator;
        try t.expect(!ckt.has_baseline);
        try t.expectEqual(ckt.g_base.len, ckt.c_base.len);
    }
    try ckt.computeBaseline();
    try t.expect(ckt.has_baseline);
    try t.expectEqual(@as(usize, ckt.nnz) + 1, ckt.c_base.len);
}

test "every allocation in circuit setup can fail without a leak" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    // The first workspace fills the template's shared column order; fill it
    // now so every run below allocates the same.
    try setUpEverything(t.allocator, &prepared);
    try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, setUpEverything, .{&prepared});
}

test "probeNames borrows labels and names unlabeled rows" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 1);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var no_x: [0]f64 = .{};
    const labels = [_][]const u8{ "v(a)", "i(v1)" };
    var ctx: types.RunCtx = .{
        .circuit = &ckt,
        .x_op = &no_x,
        .probes = &.{ 1, 2 },
        .probe_labels = &labels,
        .source_node = 0,
        .source_branch = 0,
        .allocator = arena.allocator(),
        .scratch_allocator = t.allocator,
    };
    const same = try types.probeNames(&ctx, null);
    try t.expect(same.ptr == @as([]const []const u8, &labels).ptr);
    const with = try types.probeNames(&ctx, "time");
    try t.expectEqual(@as(usize, 3), with.len);
    try t.expectEqualStrings("time", with[0]);
    try t.expectEqualStrings("v(a)", with[1]);
    try t.expectEqualStrings("i(v1)", with[2]);
    // A label count that does not match the probes counts as unlabeled.
    ctx.probe_labels = labels[0..1];
    const bare = try types.probeNames(&ctx, null);
    try t.expectEqualStrings("v(1)", bare[0]);
    try t.expectEqualStrings("v(2)", bare[1]);
    // A row past the circuit has no name rather than overflowing.
    try t.expectEqualStrings("", ckt.nodeName(std.math.maxInt(u32)));
}
