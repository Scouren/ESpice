//! Jacobian-vs-finite-difference property over every built-in model
//! (TESTING.md, wrong device derivative): at random voltages each stamped G entry
//! must match a central difference of the stamped residual, and each C entry
//! one of the stamped charge; and at fixed points for a card whose terms
//! the defaults switch off (diode tunnelling, VDMOS LAMBDA in reverse
//! mode, a lateral pnp's substrate junction). An entry whose differences
//! do not converge fails too (`FdNotConverged`), unless their spread is
//! within `row_reltol` of the row's largest partial and holds the dual.
//! Reaches each model through its object's vtable, as the builder does, so
//! no device body compiles into this test.
const std = @import("std");
const abi = @import("device_abi");
const catalog = @import("../catalog.zig");

const points = 12;
const rtol = 1e-5;
/// Absolute floors: 1% of the default gmin, below which no Newton step moves
/// (asmhemt's 2e-12 S gate leak wanders by 2.5e-15 S with h), and 1 aF.
const g_floor = 1e-14;
const c_floor = 1e-18;
/// ngspice's default RELTOL, the accuracy every answer is held to. Where no
/// two Richardson values agree, the difference is an oracle only to their
/// spread; a spread within this fraction of the row's largest partial is
/// below anything the row's Newton step or small-signal answer can show.
/// `eps |value| / h`, the residual's rounding, is no such floor: the
/// tolerance holds it already, and an entry fails here when the rounding
/// of the model's internal terms, which the residual does not show, swamps
/// the difference (l_utsoi's NSIG row: its differences at h/2, h/4 and h/8
/// move by 7e-9 to 8e-9 each halving, more than its residual's rounding
/// allows).
const row_reltol = 1e-3;
/// Models whose .va marks ngspice's Meyer-cap coefficients `vera_nodiff`:
/// their C plane is not ∂q/∂x by design, so only G is checked.
const nodiff = [_][]const u8{ "hfet1", "hfet2", "mesa", "mos1", "mos2", "mos3", "mos6", "mos9", "bsim4va" };

const Planes = struct {
    g: []f64,
    c: []f64,
    rhs: []f64,
    q: []f64,
};

/// The central differences' steps as fractions of h. Every column stamps
/// x ± h and x ± h/2; a column with an entry those two do not pass also
/// stamps x ± h/4 and x ± h/8, so a failure tells a wrong dual from a
/// difference that has not converged.
const fractions = [_]f64{ 1, 0.5, 0.25, 0.125 };

/// G, checked against the stamped residual, or C, against the stamped
/// charge.
const Plane = enum { g, c };

/// What the differences say about one entry's dual. `mismatch`: two
/// successive Richardson values agree and the dual is off them.
/// `unconverged`: no two agree, and their spread is too wide for the row
/// to be an oracle there, or does not hold the dual.
const Verdict = enum { pass, mismatch, unconverged };

// ---- private ----

/// Checks model `name`, its card pairs `params` bound, at each point of
/// `fixed` or, when it is empty, at `points` random voltages. Returns the
/// largest |G| entry stamped at a checked point. Fails at the first entry
/// `judge` does not pass: `JacobianMismatch` off a converged difference,
/// `FdNotConverged` where no difference converges, printing the point and
/// every difference; and with `NoFinitePoint` when no point stamps finite
/// planes. Leaves its blobs and planes in `gpa`: the caller passes an arena.
fn checkModel(gpa: std.mem.Allocator, name: []const u8, vt: *const abi.DeviceVtable, params: []const abi.Param, fixed: []const []const f64, rand: std.Random) !f64 {
    const mblob = try gpa.alignedAlloc(u8, .@"16", vt.model_size);
    const iblob = try gpa.alignedAlloc(u8, .@"16", vt.instance_size);
    vt.init_model(mblob.ptr);
    vt.init_instance(iblob.ptr);
    try vt.bind_model(mblob.ptr, params).unwrap();
    try vt.bind_instance(iblob.ptr, params).unwrap();
    if (vt.derive) |derive| derive(mblob.ptr);
    // Unknowns 0..n, collapsed internals aliased as the builder does.
    const nodes = try gpa.alloc(u32, vt.n_u);
    const alias = try gpa.alloc(i32, vt.n_u);
    @memset(alias, -1);
    if (vt.collapse) |collapse| collapse(mblob.ptr, iblob.ptr, alias.ptr);
    var n: u32 = 0;
    for (nodes, alias, 0..) |*node, a, u| {
        node.* = if (u >= vt.num_ports and a >= 0) nodes[@intCast(a)] else blk: {
            n += 1;
            break :blk n - 1;
        };
    }

    const proto = try vt.proto_create(gpa).unwrap();
    defer proto.destroy(proto.ctx, gpa);
    try vt.proto_add(proto.ctx, gpa, mblob.ptr, iblob.ptr, nodes.ptr).unwrap();
    var pb: abi.PatternBuilder = .{};
    for (0..n) |i| try pb.add(gpa, @intCast(i), @intCast(i));
    try proto.pattern(proto.ctx, gpa, &pb).unwrap();
    var col_ptr: []u32 = undefined;
    var row_idx: []u32 = undefined;
    const nnz = try pb.toCsc(gpa, gpa, n, &col_ptr, &row_idx);
    const template = try proto.finalize(proto.ctx, gpa, .{ .col_ptr = col_ptr, .row_idx = row_idx, .n = n, .trash_slot = nnz }).unwrap();
    defer template.hooks.deinit(template.ctx, gpa);
    const batch = try template.hooks.instantiate(template.ctx, gpa).unwrap();
    defer batch.hooks.deinit(batch.ctx, gpa);
    // A static DC solve past its first iterate: no `analog initial` rerun.
    batch.hooks.set_sim_state(batch.ctx, .{ .kind = .dc, .analog_initial = false, .iteration = 2 });

    // planes[0] at x, planes[1 + 2k] and planes[2 + 2k] at x ± h fractions[k].
    var planes: [1 + 2 * fractions.len]Planes = undefined;
    for (&planes) |*p| p.* = .{
        .g = try gpa.alloc(f64, nnz + 1),
        .c = try gpa.alloc(f64, nnz + 1),
        .rhs = try gpa.alloc(f64, n + 1),
        .q = try gpa.alloc(f64, n + 1),
    };
    const x = try gpa.alloc(f64, n);
    const g_max = try gpa.alloc(f64, n);
    const c_max = try gpa.alloc(f64, n);
    const check_c = for (nodiff) |m| {
        if (std.mem.eql(u8, m, name)) break false;
    } else true;

    var checked: usize = 0;
    var g_seen: f64 = 0;
    for (0..if (fixed.len > 0) fixed.len else points) |k| {
        // The given point, else ±2 V (or A on a branch row): forward and
        // reverse bias, every region.
        if (fixed.len > 0) {
            std.debug.assert(fixed[k].len == n);
            @memcpy(x, fixed[k]);
        } else for (x) |*v| {
            v.* = rand.float(f64) * 4 - 2;
        }
        evalAt(batch, planes[0], x);
        const p0 = planes[0];
        if (!allFinite(p0.g) or !allFinite(p0.rhs) or !allFinite(p0.c) or !allFinite(p0.q)) continue;
        @memset(g_max, 0);
        @memset(c_max, 0);
        for (row_idx, p0.g[0..nnz], p0.c[0..nnz]) |r, g, c| {
            g_max[r] = @max(g_max[r], @abs(g));
            c_max[r] = @max(c_max[r], @abs(c));
            g_seen = @max(g_seen, @abs(g));
        }
        for (0..n) |col| {
            // Large on purpose: below ~1e-4 V the rounding of cancelling
            // internal currents swamps the difference (psp103, mextram).
            // h/8, 1.25e-4 V, is stamped only for an entry h and h/2 fail.
            const h = 1e-3 * @max(1.0, @abs(x[col]));
            stampSteps(batch, &planes, x, col, h, 0, 2);
            var refined = false;
            for ([_]Plane{ .g, .c }) |plane| {
                if (plane == .c and !check_c) continue;
                const jac = if (plane == .g) p0.g else p0.c;
                const row_max = if (plane == .g) g_max else c_max;
                for (col_ptr[col]..col_ptr[col + 1]) |slot| {
                    const r = row_idx[slot];
                    // A partial 1e-9 below its row's largest moves no Newton step.
                    const slack = 1e-9 * row_max[r] + @as(f64, if (plane == .g) g_floor else c_floor);
                    var d: [fractions.len]f64 = @splat(std.math.nan(f64));
                    var vmax: f64 = 0;
                    var verdict: Verdict = .unconverged;
                    for ([_]usize{ 2, fractions.len }) |levels| {
                        if (levels > 2 and !refined) {
                            stampSteps(batch, &planes, x, col, h, 2, fractions.len);
                            refined = true;
                        }
                        for (0..levels) |s| {
                            const up = planes[1 + 2 * s];
                            const down = planes[2 + 2 * s];
                            const a = (if (plane == .g) up.rhs else up.q)[r];
                            const b = (if (plane == .g) down.rhs else down.q)[r];
                            d[s] = (a - b) / (2 * h * fractions[s]);
                            vmax = @max(vmax, @abs(a), @abs(b));
                        }
                        verdict = judge(jac[slot], d[0..levels], h, vmax, slack, row_max[r]);
                        if (verdict == .pass) break;
                    }
                    if (verdict == .pass) continue;
                    const what = if (verdict == .mismatch) "dual off its converged difference" else "FD not converged at this point";
                    std.debug.print("{s}: {s}[{d}][{d}] {s} (point {d}): dual {e}; FD at h, h/2, h/4, h/8 {e} {e} {e} {e}; Richardson {e} {e} {e}; h {e}; row max {e}; |value| up to {e}; x {any}\n", .{ name, @tagName(plane), r, col, what, k, jac[slot], d[0], d[1], d[2], d[3], richardson(&d, 0), richardson(&d, 1), richardson(&d, 2), h, row_max[r], vmax, x });
                    return if (verdict == .mismatch) error.JacobianMismatch else error.FdNotConverged;
                }
            }
        }
        checked += 1;
    }
    if (checked == 0) {
        std.debug.print("{s}: no finite point\n", .{name});
        return error.NoFinitePoint;
    }
    return g_seen;
}

/// Stamps planes[1 + 2k] at x + h fractions[k] and planes[2 + 2k] at
/// x - h fractions[k] on unknown `col`, for k in [from, to); leaves x as it
/// was.
fn stampSteps(batch: abi.Batch, planes: []const Planes, x: []f64, col: usize, h: f64, from: usize, to: usize) void {
    const x0 = x[col];
    defer x[col] = x0;
    for (from..to) |k| for ([_]f64{ 1, -1 }, 1..) |sign, j| {
        x[col] = x0 + sign * h * fractions[k];
        evalAt(batch, planes[2 * k + j], x);
    };
}

/// Judges dual `jac` against `d`, one row's central differences at
/// h fractions[0..d.len]. Richardson's value of two successive ones cancels
/// their h² error. A tolerance is rtol of the larger value, `vmax`'s
/// rounding at the finer step, and `slack`. The first Richardson value
/// passes within it. Otherwise the oracle is the finer value of the
/// coarsest successive pair that agrees within it, whose spread widens it.
/// With no such pair over all `fractions`, the oracle is good only to the
/// spread s of every Richardson value: the dual passes within s of them
/// when s ≤ `row_reltol` × `row_max`, the row's largest |partial|.
fn judge(jac: f64, d: []const f64, h: f64, vmax: f64, slack: f64, row_max: f64) Verdict {
    std.debug.assert(d.len >= 2 and d.len <= fractions.len);
    std.debug.assert(row_max >= 0);
    const eps = std.math.floatEps(f64);
    const first = richardson(d, 0);
    if (@abs(jac - first) <= rtol * @max(@abs(jac), @abs(first)) + 8 * eps * vmax / (h * fractions[1]) + slack) return .pass;
    for (1..d.len - 1) |k| {
        const coarse = richardson(d, k - 1);
        const fine = richardson(d, k);
        const tol = rtol * @max(@abs(jac), @abs(fine)) + 8 * eps * vmax / (h * fractions[k + 1]) + slack;
        const spread = @abs(coarse - fine);
        if (!(spread <= tol)) continue;
        return if (@abs(jac - fine) <= tol + spread) .pass else .mismatch;
    }
    // Two steps only: the caller stamps the rest before this floor applies.
    if (d.len < fractions.len) return .unconverged;
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (0..d.len - 1) |k| {
        const v = richardson(d, k);
        if (std.math.isNan(v)) return .unconverged;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const s = hi - lo;
    const held = jac >= lo - s and jac <= hi + s;
    return if (s <= row_reltol * row_max and held) .pass else .unconverged;
}

/// Richardson's extrapolation of central differences d[k] and d[k + 1],
/// whose steps are a factor 2 apart.
fn richardson(d: []const f64, k: usize) f64 {
    return (4 * d[k + 1] - d[k]) / 3;
}

/// Stamps every plane at x from +0.0.
fn evalAt(batch: abi.Batch, p: Planes, x: []const f64) void {
    for ([_][]f64{ p.g, p.c, p.rhs, p.q }) |s| @memset(s, 0);
    batch.eval(batch.ctx, &.{ .g_vals = p.g, .c_vals = p.c, .rhs = p.rhs, .q_vec = p.q }, 0, 1, x, 0);
}

fn allFinite(xs: []const f64) bool {
    for (xs) |v| if (!std.math.isFinite(v)) return false;
    return true;
}

test "device jacobian == finite difference, every built-in model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var failures: usize = 0;
    inline for (catalog.catalog) |e| {
        const vt = catalog.vtable(e.name);
        // Seeded from the model's name, so its points do not move when a
        // model joins the catalog. diode_t's defaults (RTH0 = 1 K/W) and
        // ±2 K on tj check its thermal row and column.
        var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0, e.name));
        // A `$systf` device needs a VPI application bound first. Every model
        // reports before the test fails.
        if (vt.systf_calls.len == 0) _ = checkModel(arena.allocator(), e.name, vt, &.{}, &.{}, prng.random()) catch |err| {
            if (err != error.JacobianMismatch and err != error.FdNotConverged and err != error.NoFinitePoint) return err;
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "diode tunnelling jacobian == finite difference at three reverse biases" {
    // Oracle: a central difference of the stamped residual, at 2, 4 and 6 V
    // of reverse bias, where the random ±2 V points above never reach and
    // the default JTUN = JTUNSW = 0 leaves the tunnel currents off. The card
    // is gf180 np_3p3's (regression/diode_tunnelling.sp). The conductance
    // floor is ngspice 44.2's chord slope of that deck's current over
    // [5.75, 6] V, (1.6568e-5 - 6.3023e-6) A / 0.25 V = 4.1e-5 S: a lower
    // bound on the slope at 6 V of a current convex in reverse bias. A
    // diode.va without tunnelling stamps about gmin there.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0);
    const params = [_]abi.Param{
        .{ .key = "is", .value = 2.2959e-7 },   .{ .key = "jsw", .value = 2.1207e-13 },    .{ .key = "n", .value = 1.01 },
        .{ .key = "bv", .value = 11 },          .{ .key = "ibv", .value = 1e-3 },          .{ .key = "tnom", .value = 25 },
        .{ .key = "jtun", .value = 1.1223e-5 }, .{ .key = "jtunsw", .value = 6.4125e-12 }, .{ .key = "ntun", .value = 10 },
        .{ .key = "xtitun", .value = -25 },     .{ .key = "area", .value = 100e-12 },      .{ .key = "pj", .value = 40e-6 },
    };
    // (V(a), V(c)); RS = 0 collapses the internal anode.
    const fixed = [_][]const f64{ &.{ 0, 2 }, &.{ 0, 4 }, &.{ 0, 6 } };
    const g = try checkModel(arena.allocator(), "diode", catalog.vtable("diode"), &params, &fixed, prng.random());
    try std.testing.expect(g >= 4.1e-5);
}

test "vdmos jacobian == finite difference in reverse mode with lambda" {
    // Oracle: a central difference of the stamped residual where the
    // default LAMBDA = 0 leaves t0 = 1 + LAMBDA*vds (signed vds,
    // vdmosload.c:366) out: vds < 0 with vgs above VTO, the reversed linear
    // region. IS = 1e-30 keeps the body diode, forward there, out of the d-s
    // entries t0's slope shares. The largest entry is the channel's
    // |dI/dV(d)| at (-2, 4, 0), vgst*t0 - I0*LAMBDA = 4*0.8 - 6*0.1 = 2.6 S
    // by hand (I0 the current before t0), which a channel left off would
    // not reach. RD = RG = RS = RB = 0 collapse every internal.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0);
    const params = [_]abi.Param{
        .{ .key = "vto", .value = 2 },      .{ .key = "kp", .value = 1 },
        .{ .key = "lambda", .value = 0.1 }, .{ .key = "is", .value = 1e-30 },
    };
    // (V(d), V(g), V(s)).
    const fixed = [_][]const f64{ &.{ -1, 3, 0 }, &.{ -2, 4, 0 }, &.{ -0.5, 2.5, 0 } };
    const g = try checkModel(arena.allocator(), "vdmos", catalog.vtable("vdmos"), &params, &fixed, prng.random());
    try std.testing.expect(g >= 2.5);
}

test "lateral pnp substrate jacobian == finite difference with cjs and iss" {
    // Oracle: a central difference of the stamped residual and charge where
    // the defaults CJS = ISS = 0 leave the substrate junction at gmin. A pnp
    // without SUBS is lateral (bjtsetup.c:40-46): the junction runs S to b'
    // in type*subs's frame (bjtload.c:139, 185-187), reversed 2.3 V at the
    // first point and forward 0.7 V at the second, where ISS draws
    // 1e-16*exp(0.7/Vt) ~ 5e-5 A. Forward active: vbe 0.7 V, vbc -1.3 V.
    // RB = RC = RE = 0 and TF = 0 collapse every internal.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0);
    const params = [_]abi.Param{
        .{ .key = "type", .value = -1 }, .{ .key = "cjs", .value = 1e-12 },
        .{ .key = "mjs", .value = 0.3 }, .{ .key = "iss", .value = 1e-16 },
    };
    // (V(c), V(b), V(e), V(s)).
    const fixed = [_][]const f64{ &.{ -2, -0.7, 0, -3 }, &.{ -2, -0.7, 0, 0 } };
    _ = try checkModel(arena.allocator(), "gummel_poon", catalog.vtable("gummel_poon"), &params, &fixed, prng.random());
}

test "judge: a true slope passes, one 3% off is a mismatch, and differences across a kink are no oracle" {
    // Oracles: analytic slopes. The diode law i(v) = 1e-14 exp(v / 25 mV)
    // at 0.6 V, slope i / 25 mV; |v - 10 uV| at 0, slope -1, where every
    // step from h = 1 mV to h/8 straddles the kink. Red before
    // FdNotConverged: the kink was a JacobianMismatch, the spread of its
    // differences passed in the tolerance.
    const diode = struct {
        fn at(v: f64) f64 {
            return 1e-14 * @exp(v / 0.025);
        }
    }.at;
    const h = 1e-3;
    var smooth: [fractions.len]f64 = undefined;
    var kink: [fractions.len]f64 = undefined;
    for (&smooth, &kink, fractions) |*s, *a, f| {
        s.* = (diode(0.6 + h * f) - diode(0.6 - h * f)) / (2 * h * f);
        a.* = (@abs(h * f - 1e-5) - @abs(-h * f - 1e-5)) / (2 * h * f);
    }
    const slope = diode(0.6) / 0.025;
    const vmax = diode(0.6 + h);
    try std.testing.expectEqual(Verdict.pass, judge(slope, smooth[0..2], h, vmax, g_floor, slope));
    // Two steps cannot tell the 3% slope's cause: the caller refines.
    try std.testing.expectEqual(Verdict.unconverged, judge(1.03 * slope, smooth[0..2], h, vmax, g_floor, slope));
    try std.testing.expectEqual(Verdict.mismatch, judge(1.03 * slope, &smooth, h, vmax, g_floor, slope));
    try std.testing.expectEqual(Verdict.unconverged, judge(-1, &kink, h, 1e-3, g_floor, 1));
}

test "judge: unconverged differences pass a dual inside their spread only where the spread is below the row's reltol" {
    // Oracle: row_reltol's statement. The kink's differences at 1e-6 of
    // their size: Richardson values -2.33e-8, -4.67e-8, -9.33e-8, spread
    // 7e-8, which holds -5e-8 and not -2e-7. Beside a partial of 1 S that is
    // 7e-8 of the row, under 1e-3; as the row's largest it is the row.
    const d = [_]f64{ -1e-8, -2e-8, -4e-8, -8e-8 };
    try std.testing.expectEqual(Verdict.pass, judge(-5e-8, &d, 1e-3, 1e-9, g_floor, 1));
    try std.testing.expectEqual(Verdict.unconverged, judge(-2e-7, &d, 1e-3, 1e-9, g_floor, 1));
    try std.testing.expectEqual(Verdict.unconverged, judge(-5e-8, &d, 1e-3, 1e-9, g_floor, 8e-8));
    // Two steps never reach the floor: the caller refines first.
    try std.testing.expectEqual(Verdict.unconverged, judge(-5e-8, d[0..2], 1e-3, 1e-9, g_floor, 1));
}
