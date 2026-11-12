//! The device LU's rent-or-buy under lever `p1` (08-placement.md sec. 2,
//! "The LU rule is rent-or-buy", and sec. 6 step 4): whether a pivot epoch
//! moves to the device, as a pure function of the calibration file's `lu`
//! rows and the epoch's census. No clock, no probe, no driver. Each host
//! refactor rents at h - d over the device call; moving the epoch buys at
//! one table build (plus the driver's start while it is down). The epoch
//! moves once the rent it has paid reaches M times the price, which costs
//! at most 1 + M times the best choice in hindsight, with no guess of how
//! long the pivot sequence lives.
//! In: `machine.Lu` rows and an `Epoch`. Out: `Costs`, buy or rent.
//! Cites: the ski-rental bound (Karlin et al., via 08-placement.md sec. 3).
//!
//! Contents:
//! - `pub const Epoch = struct`
//! - `pub const Costs = struct { h, d, build }`
//! - `pub fn costs(rows: []const machine.Lu, host_key: u64, image: u64, e: Epoch) ?Costs`
//! - `pub fn buys(rows: []const machine.Lu, host_key: u64, image: u64, start_in_ms: f64, e: Epoch) bool`

const std = @import("std");
const assert = std.debug.assert;
const machine = @import("machine.zig");
const price = @import("price.zig");
const per_query = @import("exec_config.zig").ThreadPool.per_query;

/// One pivot epoch as the rent-or-buy sees it: what the factor fixes.
pub const Epoch = struct {
    /// Unknowns, and LU flops per refactor (the epoch's census).
    n: u32,
    flops: u64,
    /// Lanes the host refactor runs on; 1 to `ThreadPool.per_query`
    /// prices between a row's one-lane and full-lane times.
    lanes: u32,
    /// Refactors of this epoch the host has run so far.
    age: u32,
    /// The driver is up, so buying pays no start.
    driver_up: bool,
};

/// One refactor and both solves of an epoch, us: on the host at its
/// lanes (`h`), as one device call (`d`), and the epoch's table build.
pub const Costs = struct { h: f64, d: f64, build: f64 };

/// Hand-built rows: two sizes of one F/n class (4,000; 08-placement.md's
/// logic_bsim4_10k numbers: 29 ms host at 8 lanes, a 15.1 ms device call,
/// a 0.48 s build), a second class (F/n 100), and rows no epoch may use.
const key: u64 = 0x1;
const img: u64 = 0x2;
const rows_fixture = [_]machine.Lu{
    // A: F/n 4,000.
    .{ .host_key = key, .image = img, .n = 10_000, .flops = 40_000_000, .host_us = 200_000, .host_par_us = 29_000, .dev_us = 15_100, .table_us = 480_000 },
    // B: the same class at twice the size.
    .{ .host_key = key, .image = img, .n = 20_000, .flops = 80_000_000, .host_us = 400_000, .host_par_us = 58_000, .dev_us = 30_200, .table_us = 960_000 },
    // C, C2: F/n 100, where the device call costs more than the host.
    .{ .host_key = key, .image = img, .n = 10_000, .flops = 1_000_000, .host_us = 5_000, .host_par_us = 1_200, .dev_us = 1_500, .table_us = 12_000 },
    .{ .host_key = key, .image = img, .n = 20_000, .flops = 2_000_000, .host_us = 10_000, .host_par_us = 2_400, .dev_us = 3_000, .table_us = 24_000 },
    // X: another device image; Z: no build key. Both F/n 4,000 at B's
    // size and cheap to buy, so a rule that used either would draw its
    // line through A and move the epoch at once.
    .{ .host_key = key, .image = 0x3, .n = 20_000, .flops = 80_000_000, .host_us = 400_000, .host_par_us = 58_000, .dev_us = 1, .table_us = 1 },
    .{ .host_key = 0, .image = img, .n = 20_000, .flops = 80_000_000, .host_us = 400_000, .host_par_us = 58_000, .dev_us = 1, .table_us = 1 },
};

/// The epoch's costs on the line through the two usable rows nearest its
/// F/n (flops per unknown, by log distance; the earlier row wins a tie),
/// interpolated or extrapolated in flops and floored at 0. A row is usable
/// when its keys are `host_key` (never 0, which marks no build key) and
/// `image`. Null with fewer than two usable rows, or two of one size: no
/// line, so the epoch stays on the host.
pub fn costs(rows: []const machine.Lu, host_key: u64, image: u64, e: Epoch) ?Costs {
    assert(e.n > 0);
    assert(e.lanes >= 1);
    const want = perCol(e.flops, e.n);
    var best: [2]?*const machine.Lu = .{ null, null };
    var dist: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
    for (rows) |*r| {
        if (host_key == 0 or r.host_key != host_key or r.image != image or r.n == 0 or r.flops == 0) continue;
        const far = @abs(@log(perCol(r.flops, r.n) / want));
        if (far < dist[0]) {
            best[1] = best[0];
            dist[1] = dist[0];
            best[0] = r;
            dist[0] = far;
        } else if (far < dist[1]) {
            best[1] = r;
            dist[1] = far;
        }
    }
    const a = best[0] orelse return null;
    const b = best[1] orelse return null;
    if (a.flops == b.flops) return null;
    const t = (fl(e.flops) - fl(a.flops)) / (fl(b.flops) - fl(a.flops));
    const ha = hostAt(a, e.lanes);
    const hb = hostAt(b, e.lanes);
    const k: Costs = .{
        .h = @max(0, ha + t * (hb - ha)),
        .d = @max(0, a.dev_us + t * (b.dev_us - a.dev_us)),
        .build = @max(0, a.table_us + t * (b.table_us - a.table_us)),
    };
    assert(k.h >= 0 and k.d >= 0 and k.build >= 0);
    return k;
}

/// Whether the epoch moves to the device now: its rows price it (`costs`),
/// the host is the dearer per refactor, and age * (h - d) >= M * buy,
/// buy = build + `start_in_ms` while the driver is down. Never when
/// h <= d; the host keeps an epoch no row prices.
pub fn buys(rows: []const machine.Lu, host_key: u64, image: u64, start_in_ms: f64, e: Epoch) bool {
    assert(start_in_ms >= 0);
    const k = costs(rows, host_key, image, e) orelse return false;
    if (k.h <= k.d) return false;
    const buy = k.build + if (e.driver_up) @as(f64, 0) else start_in_ms * 1000;
    assert(buy >= 0);
    return fl(e.age) * (k.h - k.d) >= price.margin * buy;
}

// ---- private ----

fn fl(x: anytype) f64 {
    return @floatFromInt(x);
}

fn perCol(flops: u64, n: u32) f64 {
    return fl(flops) / fl(n);
}

/// A row's host time at `lanes`: on the line from its one-lane time to
/// its `per_query`-lane time, clamped to that range of lanes.
fn hostAt(r: *const machine.Lu, lanes: u32) f64 {
    const l = std.math.clamp(lanes, 1, per_query);
    return r.host_us + (r.host_par_us - r.host_us) * fl(l - 1) / fl(per_query - 1);
}

// Oracle: hand arithmetic on `rows_fixture`, with M = 3.3 written out
// (the test fails first if `price.margin` moves, so the numbers are refit
// by hand, never recomputed the code's way).
// - At A's size, 8 lanes: rent = 29,000 - 15,100 = 13,900 us; M * buy =
//   3.3 * 480,000 = 1,584,000. 113 * 13,900 = 1,570,700 rents; 114 *
//   13,900 = 1,584,600 buys (the break-even lies between).
// - Driver down, start 137 ms: buy = 617,000; M * buy = 2,036,100. 146 *
//   13,900 = 2,029,400 rents; 147 * 13,900 = 2,043,300 buys.
// - One lane: rent = 200,000 - 15,100 = 184,900; 8 rents (1,479,200), 9
//   buys (1,664,100).
// - Halfway from A to B (n 15,000, 60M flops, 8 lanes): t = 0.5, h =
//   43,500, d = 22,650, build = 720,000; rent 20,850; M * buy = 2,376,000.
//   113 rents (2,356,050), 114 buys (2,376,900).
// - F/n 100 halfway from C to C2: h = 1,800 <= d = 2,250: never.
test "lu_price: rent, buy and the break-even on hand-built lu rows" {
    try std.testing.expectEqual(@as(f64, 3.3), price.margin);
    const rows: []const machine.Lu = &rows_fixture;
    const a: Epoch = .{ .n = 10_000, .flops = 40_000_000, .lanes = 8, .age = 0, .driver_up = true };
    const k = costs(rows, key, img, a).?;
    try std.testing.expectEqual(@as(f64, 29_000), k.h);
    try std.testing.expectEqual(@as(f64, 15_100), k.d);
    try std.testing.expectEqual(@as(f64, 480_000), k.build);
    const cases = [_]struct { Epoch, bool }{
        .{ a, false },
        .{ .{ .n = 10_000, .flops = 40_000_000, .lanes = 8, .age = 113, .driver_up = true }, false },
        .{ .{ .n = 10_000, .flops = 40_000_000, .lanes = 8, .age = 114, .driver_up = true }, true },
        .{ .{ .n = 10_000, .flops = 40_000_000, .lanes = 8, .age = 146, .driver_up = false }, false },
        .{ .{ .n = 10_000, .flops = 40_000_000, .lanes = 8, .age = 147, .driver_up = false }, true },
        .{ .{ .n = 10_000, .flops = 40_000_000, .lanes = 1, .age = 8, .driver_up = true }, false },
        .{ .{ .n = 10_000, .flops = 40_000_000, .lanes = 1, .age = 9, .driver_up = true }, true },
        .{ .{ .n = 15_000, .flops = 60_000_000, .lanes = 8, .age = 113, .driver_up = true }, false },
        .{ .{ .n = 15_000, .flops = 60_000_000, .lanes = 8, .age = 114, .driver_up = true }, true },
        .{ .{ .n = 15_000, .flops = 1_500_000, .lanes = 8, .age = 1_000_000, .driver_up = true }, false },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("case {d}: age {d}, lanes {d}\n", .{ i, c[0].age, c[0].lanes });
        try std.testing.expectEqual(c[1], buys(rows, key, img, 137, c[0]));
    }
}

// Oracle: the rule as stated, no row -> host. With only unusable rows
// beside one usable one (another image, no build key, a zero key asked
// for), or none at all, no epoch moves at any age, cheap as they are.
test "lu_price: a missing or unusable row keeps the epoch on the host" {
    const e: Epoch = .{ .n = 10_000, .flops = 40_000_000, .lanes = 8, .age = 1_000_000, .driver_up = true };
    const one_and_strays = [_]machine.Lu{ rows_fixture[4], rows_fixture[5], rows_fixture[0] };
    try std.testing.expect(costs(&one_and_strays, key, img, e) == null);
    try std.testing.expect(!buys(&one_and_strays, key, img, 137, e));
    try std.testing.expect(!buys(&.{}, key, img, 137, e));
    // A build with no key (0) prices nothing, even rows keyed 0.
    try std.testing.expect(!buys(&rows_fixture, 0, img, 137, e));
}
