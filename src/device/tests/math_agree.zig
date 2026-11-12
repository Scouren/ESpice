//! The two math libraries ESPice links, `gompute.math` (the dual family) and
//! VerA's `contract.gm` (generated setup code, the scalar limiters, VerA's
//! constant folds), bit for bit over the inputs Gompute's own tests sweep.
//! Every "exact" hoist from core to setup and every constant fold moves a
//! call from one library to the other; this is the gate under those claims
//! (docs/perf_research/12-math-and-contract.md M8).
//!
//! Oracle: each library is the other's reference. The test names, per
//! function, the first input where the two differ and how many inputs do.
//! Both claim the ARM optimized-routines no-FMA bodies for exp, log and pow,
//! which must agree on every input. The rest are musl or std on each side;
//! the ones measured to differ are named in `known_differ` with the cause,
//! and a named one that stops differing fails until its line goes. NaN
//! payloads are counted, not gated: neither library promises one.
const std = @import("std");
const gmath = @import("gompute").math;
const gm = @import("contract").gm;

const Tally = struct {
    n: usize = 0,
    differ: usize = 0,
    /// Inputs where both returned a NaN but with different bits.
    nan_payload: usize = 0,
    first_x: f64 = 0,
    first_y: f64 = 0,
    first_got: u64 = 0,
    first_want: u64 = 0,

    fn at(t: *Tally, x: f64, y: f64, a: f64, b: f64) void {
        t.n += 1;
        const ua: u64 = @bitCast(a);
        const ub: u64 = @bitCast(b);
        if (ua == ub) return;
        if (std.math.isNan(a) and std.math.isNan(b)) {
            t.nan_payload += 1;
            return;
        }
        if (t.differ == 0) {
            t.first_x = x;
            t.first_y = y;
            t.first_got = ua;
            t.first_want = ub;
        }
        t.differ += 1;
    }
};

/// Both zeros, both infinities, NaNs with payloads of either sign, the
/// subnormal and normal ends, and each exp threshold with its neighbours.
const specials = [_]u64{
    0x0000000000000000, 0x8000000000000000, 0x7ff0000000000000, 0xfff0000000000000,
    0x7ff8000000000000, 0xfff8000000000000, 0x7ff8000000000001, 0xfff800000000dead,
    0x7ff0000000000001, 0xfff0000000000001, 0x7ff4000000c0ffee, 0x7fffffffffffffff,
    0xffffffffffffffff, 0x0000000000000001, 0x8000000000000001, 0x000fffffffffffff,
    0x800fffffffffffff, 0x0010000000000000, 0x8010000000000000, 0x7fefffffffffffff,
    0xffefffffffffffff, 0x3ff0000000000000, 0xbff0000000000000,
};
const thresholds = [_]f64{ 0x1p-54, 512.0, 1024.0, 709.782712893384, 745.1332191019411, 0x1p-1022, 1.0 - 0x1p-4, 1.0 + 0x1.09p-4, 1.0 };

const known_differ = .{
    // gompute: log * 1/ln10 (two roundings); gm: std.math.log10. 2636 of 1.47M.
    "log10",
    // gompute: musl sinh/cosh over its own expm1/exp; gm: std.math. 26 / 121k.
    "sinh",
    "cosh",
    // gompute 2.0.0 returned +0 for atan(-0); 2.0.1 keeps the sign and then
    // agrees on every input. Delete this line when the pin moves to >= 2.0.1.
    "atan",
};

const unary = .{ "exp", "log", "log10", "sin", "cos", "tan", "tanh", "sinh", "cosh", "expm1", "log1p", "atan" };

const Unary = struct {
    t: [unary.len]Tally = @splat(.{}),
    v_exp: Tally = .{},
    v_log: Tally = .{},
    lane: usize = 0,
    buf: [4]f64 = undefined,

    fn visit(u: *Unary, x: f64) void {
        inline for (unary, 0..) |name, i| u.t[i].at(x, 0, @field(gmath, name)(x), @field(gm, name)(x));
        // Width 4, the dual family's lane count: four consecutive inputs.
        u.buf[u.lane] = x;
        u.lane += 1;
        if (u.lane < 4) return;
        u.lane = 0;
        const v: @Vector(4, f64) = u.buf;
        const ea = gmath.exp(v);
        const eb = gm.exp(v);
        const la = gmath.log(v);
        const lb = gm.log(v);
        inline for (0..4) |l| {
            u.v_exp.at(v[l], 0, ea[l], eb[l]);
            u.v_log.at(v[l], 0, la[l], lb[l]);
        }
    }
};

// ---- private ----

fn key(x: f64) i64 {
    const u: u64 = @bitCast(x);
    return @bitCast(if (u >> 63 != 0) (@as(u64, 1) << 63) -% u else u);
}
fn unkey(k: i64) f64 {
    const u: u64 = @bitCast(k);
    return @bitCast(if (k < 0) (@as(u64, 1) << 63) -% u else u);
}

/// Calls `visit(ctx, x)` over the union of the exp and log sweeps of
/// Gompute's libm differential (same seed, same counts), every biased
/// exponent of either sign, the thresholds walked ulp by ulp, and the
/// specials.
fn sweep(ctx: anytype, comptime visit: anytype) void {
    var prng = std.Random.DefaultPrng.init(0x5EED_C0FFEE);
    const rnd = prng.random();
    for (specials) |b| visit(ctx, @bitCast(b));
    for (thresholds) |t0| for ([_]f64{ t0, -t0 }) |t| {
        const k0 = key(t);
        for (0..2_000) |i| {
            const off: i64 = @intCast(i);
            visit(ctx, unkey(k0 +| off));
            visit(ctx, unkey(k0 -| off));
        }
    };
    for (0..400_000) |_| visit(ctx, -745.2 + rnd.float(f64) * (709.79 + 745.2));
    for (0..400_000) |_| {
        const e: u64 = rnd.intRangeAtMost(u64, 0, 2047);
        visit(ctx, @bitCast((rnd.int(u64) & (1 << 63)) | (e << 52) | (rnd.int(u64) >> 12)));
    }
    for (0..400_000) |_| visit(ctx, 1.0 - 0x1.1p-4 + rnd.float(f64) * 0x1.1p-3);
    for (0..100_000) |i| {
        const off: i64 = @intCast(i);
        visit(ctx, unkey(key(1.0) +| off));
        visit(ctx, unkey(key(1.0) -| off));
    }
}

/// Measured against gompute 2.0.0 and vera 0.23.0 (the pins of this
/// commit). Each differs in the last bit on some inputs because the two sides
/// run different bodies on the host; `contract.gm` takes std or the builtin
/// there and Gompute its own port.
fn knownDiffer(comptime name: []const u8) bool {
    inline for (known_differ) |k| if (comptime std.mem.eql(u8, k, name)) return true;
    return false;
}

fn report(name: []const u8, t: Tally) void {
    if (t.differ == 0) {
        std.debug.print("  {s:<12} {d:>9} inputs, identical ({d} NaN-payload differences)\n", .{ name, t.n, t.nan_payload });
    } else {
        std.debug.print("  {s:<12} {d:>9} inputs, {d} differ; first at x={x} y={x}: gompute {x} contract.gm {x} ({d} NaN-payload differences)\n", .{ name, t.n, t.differ, t.first_x, t.first_y, t.first_got, t.first_want, t.nan_payload });
    }
}

test "gompute.math and contract.gm agree bit for bit" {
    var u: Unary = .{};
    sweep(&u, Unary.visit);

    // pow: Gompute's pow sweep (x log-uniform over 1e-30..1e30, y over
    // -40..40; the SPICE junction exponents), the C99 cross product, and
    // the vector form `powV(vec, y)` against `pow(vec, splat y)`.
    var p: Tally = .{};
    var pv: Tally = .{};
    var prng = std.Random.DefaultPrng.init(0x5EED_C0FFEE);
    const rnd = prng.random();
    const ln10 = 2.302585092994045684;
    for (0..1_000_000) |_| {
        const x = gm.exp(ln10 * (rnd.float(f64) * 60.0 - 30.0));
        const y = rnd.float(f64) * 80.0 - 40.0;
        p.at(x, y, gmath.pow(x, y), gm.pow(x, y));
    }
    for ([_]f64{ 1.1739, 0.87225, 0.693, 0.99, 0.649, 0.351, 1.4552480184709202 }) |y| {
        for (0..100_000) |i| {
            const uu = @as(f64, @floatFromInt(i)) / 100_000.0;
            const x = gm.exp(ln10 * (-3.1249 + uu * (0.4771 + 3.1249)));
            p.at(x, y, gmath.pow(x, y), gm.pow(x, y));
        }
        var i: usize = 0;
        while (i < 100_000) : (i += 4) {
            var v: @Vector(4, f64) = undefined;
            inline for (0..4) |l| v[l] = 1e-3 + @as(f64, @floatFromInt(i + l)) * 1e-4;
            const a = gmath.pow(v, @as(@Vector(4, f64), @splat(y)));
            const b = gm.powV(v, y);
            inline for (0..4) |l| pv.at(v[l], y, a[l], b[l]);
        }
    }
    const inf = std.math.inf(f64);
    const ys = [_]f64{
        0.0,     -0.0,     1.0,               -1.0,    2.0,    -2.0,    3.0,  -3.0,
        0.5,     -0.5,     2.5,               -2.5,    64.0,   -64.0,   65.0, -65.0,
        inf,     -inf,     std.math.nan(f64), 1023.0,  1024.0, -1074.0, 1e10, -1e10,
        0x1p-70, -0x1p-70, 0x1p70,            -0x1p70, 1e308,
    };
    for (specials) |xb| for (ys) |y| {
        const x: f64 = @bitCast(xb);
        p.at(x, y, gmath.pow(x, y), gm.pow(x, y));
    };

    std.debug.print("\n  gompute.math vs contract.gm, bit for bit:\n", .{});
    inline for (unary, 0..) |name, i| report(name, u.t[i]);
    report("exp x4", u.v_exp);
    report("log x4", u.v_log);
    report("pow", p);
    report("pow x4", pv);
    var bad = false;
    inline for (unary, 0..) |name, i| {
        const known = comptime knownDiffer(name);
        if (known and u.t[i].differ == 0) std.debug.print("  {s}: named in known_differ but now agrees; delete its line\n", .{name});
        if (!known and u.t[i].differ != 0) std.debug.print("  {s}: differs and is not named in known_differ\n", .{name});
        bad = bad or (known != (u.t[i].differ != 0));
    }
    for ([_]Tally{ u.v_exp, u.v_log, p, pv }) |t| bad = bad or t.differ != 0;
    try std.testing.expect(!bad);
}
