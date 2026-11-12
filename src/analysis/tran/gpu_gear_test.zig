//! Gear orders 3 to 6 on the transient lanes: the lane bodies
//! (`lane_kernels.companionGear`, `stepBoundGear`) against the host
//! integrator on the same histories and steps, bitwise, at stride 1 and
//! lane-major.
//! Oracle: `integrator.gearAg`, `gearHistory`, `companionAt` and
//! `stepBoundGear`, the host transient's own arithmetic.
//!
//! Contents: `History` and two tests.

const std = @import("std");
const lk = @import("solver").lane_kernels;
const integrator = @import("integrator.zig");

/// Charges of 8 logical slots over `n` elements, the dynamic current, the
/// step history and the lane-major copies (`lanes` lanes, the data in lane
/// `lane`; the others hold NaN, so a stride slip shows).
const History = struct {
    const n = 5;
    const lanes = 3;
    const lane = 1;
    q: [8][n]f64,
    ip: [n]f64,
    dts: [7]f64,
    q_lm: [8][n * lanes]f64,
    ip_lm: [n * lanes]f64,

    fn init(seed: u64) History {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var h: History = undefined;
        for (&h.q) |*slot| for (slot) |*v| {
            v.* = 1e-12 * (r.float(f64) - 0.5);
        };
        for (&h.ip) |*v| v.* = 1e-3 * (r.float(f64) - 0.5);
        for (&h.dts) |*v| v.* = 1e-9 * (0.5 + r.float(f64));
        for (&h.q_lm, h.q) |*lm, slot| {
            @memset(lm, std.math.nan(f64));
            for (slot, 0..) |v, j| lm[j * lanes + lane] = v;
        }
        @memset(&h.ip_lm, std.math.nan(f64));
        for (h.ip, 0..) |v, j| h.ip_lm[j * lanes + lane] = v;
        return h;
    }

    fn at(h: *const History, j: usize) [8]f64 {
        var v: [8]f64 = undefined;
        for (&v, h.q) |*o, slot| o.* = slot[j];
        return v;
    }
};

// ---- private ----

fn bits(x: f64) u64 {
    return @bitCast(x);
}

test "lane gear: companionGear is integrator.companionAt over gearHistory's g, gear-3..6, bitwise" {
    const h = History.init(0x9e37);
    for (3..7) |kk| {
        const k: u8 = @intCast(kk);
        const ag = integrator.gearAg(k, &h.dts);
        var g: [History.n]f64 = undefined;
        var slots: [8][]f64 = undefined;
        var q = h.q;
        for (&slots, &q) |*s, *slot| s.* = slot;
        integrator.gearHistory(&g, slots[0 .. k + 1], ag);
        const c: integrator.Coeffs = .{ .ag0 = ag[0], .ag2 = 0 };
        var acc: [History.n]f64 = h.ip;
        var adv: [History.n]f64 = h.ip;
        switch (integrator.gear(k)) {
            inline .gear_3, .gear_4, .gear_5, .gear_6 => |m| {
                integrator.companionAt(m, true, &acc, &h.q[0], &h.q[1], &g, &h.ip, c);
                integrator.advanceCurrent(m, &adv, &h.q[0], &h.q[1], &g, c);
            },
            else => unreachable,
        }
        for (0..History.n) |j| {
            try std.testing.expectEqual(bits(acc[j]), bits(lk.companionGear(true, k, ag, h.at(j), h.ip[j])));
            try std.testing.expectEqual(bits(adv[j]), bits(lk.companionGear(false, k, ag, h.at(j), 0)));
        }
    }
}

test "lane gear: stepBoundGear is integrator.stepBoundGear at the order and both neighbours, bitwise" {
    const h = History.init(0x51ed);
    const lte: integrator.LteIn = .{ .dt = h.dts[0], .dt1 = h.dts[1], .dt2 = h.dts[2], .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-16, .trtol = 7 };
    var slots: [8][]const f64 = undefined;
    var slots_lm: [8][]const f64 = undefined;
    for (&slots, &slots_lm, &h.q, &h.q_lm) |*s, *s_lm, *slot, *lm| {
        s.* = slot;
        s_lm.* = lm[History.lane..];
    }
    // (order the bound is at, the step's own order): the order control's
    // three asks, gear-2 as the step below gear-3 and as the step under it.
    const cases = [_][2]u8{ .{ 3, 3 }, .{ 4, 4 }, .{ 5, 5 }, .{ 6, 6 }, .{ 3, 2 }, .{ 4, 3 }, .{ 5, 4 }, .{ 6, 5 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 5 }, .{ 5, 6 } };
    for (cases) |cs| {
        const p = cs[0];
        const cur = cs[1];
        var ag: [7]f64 = @splat(0);
        var g: [History.n]f64 = @splat(0);
        const c: integrator.Coeffs = if (cur >= 3) blk: {
            ag = integrator.gearAg(cur, &h.dts);
            var q = h.q;
            var mut: [8][]f64 = undefined;
            for (&mut, &q) |*s, *slot| s.* = slot;
            integrator.gearHistory(&g, mut[0 .. cur + 1], ag);
            break :blk .{ .ag0 = ag[0], .ag2 = 0 };
        } else integrator.coeffs(.gear_2, h.dts[0], h.dts[1], 0.5);
        const host = integrator.stepBoundGear(integrator.gear(p), integrator.gear(cur), &slots, &h.ip, &g, c, lte, &h.dts);
        const lin: lk.LteIn = .{ .dt = lte.dt, .dt1 = lte.dt1, .dt2 = lte.dt2, .reltol = lte.reltol, .abstol = lte.abstol, .chgtol = lte.chgtol, .trtol = lte.trtol, .ag0 = c.ag0, .ag1 = c.ag1, .ag2 = c.ag2 };
        const gear: lk.LaneGear = .{ .ag = ag, .dts = h.dts, .top = 6 };
        try std.testing.expect(std.math.isFinite(host));
        try std.testing.expectEqual(bits(host), bits(lk.stepBoundGear(p, cur, slots, h.ip, History.n, 1, lin, gear)));
        try std.testing.expectEqual(bits(host), bits(lk.stepBoundGear(p, cur, slots_lm, h.ip_lm[History.lane..], History.n, History.lanes, lin, gear)));
    }
}
