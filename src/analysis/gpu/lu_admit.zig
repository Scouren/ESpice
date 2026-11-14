//! When `GpuLu` admits a pivot epoch to the device, under two levers. G3
//! (05-levers-gpu.md, "Operating-point pivot epochs stay on the host"):
//! once the epoch has survived `hold_refactors` host refactors (`Hold`).
//! P1 (08-placement.md step 4): once its host rent pays for its tables by
//! the calibration file's `lu` rows (`Rent`, over `lu_price.buys`).
//! In: each declined call's epoch and whether it refactors. Out: admit.
//! Cites: none.
//!
//! Contents:
//! - `pub const Hold = struct` (`ready`, `count`)
//! - `pub const Rent = struct` (`paid`, `add`)
//! - `pub const hold_refactors: u32`

const std = @import("std");
const assert = std.debug.assert;
const machine = @import("../machine.zig");
const lu_price = @import("../lu_price.zig");
const context_cost = @import("context_cost.zig");

/// G3: refactors a pivot epoch must survive on the host before the device
/// LU takes it, so the operating point's short-lived epochs never build or
/// upload tables and the transient's long one does. A host refactor that
/// fails starts a new epoch (`lu_factor.zig` bumps `pattern_epoch` on every
/// full factor), which resets the count; so reaching a call with the same
/// epoch proves each counted refactor survived. Only where the factor runs
/// changes, never the pivot rule or a value.
pub const Hold = struct {
    /// The `SparseLu.pattern_epoch` counted; null before the first call.
    epoch: ?u32 = null,
    /// Refactors this epoch asked for and the host ran, saturating at
    /// `hold_refactors`.
    survived: u32 = 0,

    /// Whether `epoch` has survived `hold_refactors` refactors.
    pub fn ready(h: Hold, epoch: u32) bool {
        assert(h.survived <= hold_refactors);
        return h.epoch == epoch and h.survived == hold_refactors;
    }

    /// A declined call of `epoch`: a new epoch restarts the count, and a
    /// call that refactors (the host runs it) adds one.
    pub fn count(h: *Hold, epoch: u32, refactor: bool) void {
        if (h.epoch != epoch) h.* = .{ .epoch = epoch };
        assert(h.survived < hold_refactors);
        if (refactor) h.survived += 1;
        assert(h.epoch.? == epoch);
    }
};

/// P1: the rent a pivot epoch has paid on the host, against the
/// calibration file's price for moving it (`lu_price.buys`). A new epoch
/// starts unpaid.
pub const Rent = struct {
    /// The calibration file; null (no file) keeps every epoch on the host.
    machine: ?*const machine.Machine = null,
    /// The device LU image's row key, hashed on first use.
    image: ?u64 = null,
    /// The epoch counted, its host refactors so far, its flops per refactor.
    epoch: ?u32 = null,
    refactors: u32 = 0,
    flops: u64 = 0,

    /// Whether `lu`'s pivot epoch (a `SparseLu`) moves to the device now,
    /// its host refactor on `lanes` lanes. Takes the epoch's census the
    /// first time it sees it.
    pub fn paid(r: *Rent, lu: anytype, lanes: u32, driver_up: bool) bool {
        const m = r.machine orelse return false;
        if (lu.n == 0) return false;
        if (r.epoch != lu.pattern_epoch) {
            var flops: u64 = 0;
            for (lu.ui.items) |i| flops += lu.lp[i + 1] - lu.lp[i];
            const known = r.image;
            r.* = .{ .machine = m, .image = known, .epoch = lu.pattern_epoch, .flops = flops };
        }
        const image = r.image orelse context_cost.imageKey("arp_lu_refactor");
        r.image = image;
        const e: lu_price.Epoch = .{ .n = lu.n, .flops = r.flops, .lanes = @max(lanes, 1), .age = r.refactors, .driver_up = driver_up };
        assert(r.epoch.? == lu.pattern_epoch);
        return lu_price.buys(m.lus, machine.lu_host_key, image, m.c.start_in_ms, e);
    }

    /// A declined call of the epoch `paid` last saw: one that refactors
    /// (the host runs it) adds to its age.
    pub fn add(r: *Rent, refactor: bool) void {
        if (refactor) r.refactors +|= 1;
    }
};

/// The refactors `Hold` waits for.
// ponytail: provisional, not measured. Fit it to the `gpu-lu (op)`
// `epochs` count (at most 2) and the operating-point time on
// logic_bsim4_10k, sram_bsim4_10k and logic_psp103_10k under
// `ESPICE_PERF=g3`.
pub const hold_refactors: u32 = 16;

// Oracle: the brief's admission rule, counted by hand. The device LU is not
// consulted until `hold_refactors` refactors of one epoch have run on the
// host, unchanged calls do not count, and a new epoch (a failed refactor's
// full factor) starts over. The solve values are bitwise the host's in both
// phases by construction (a held call returns before any device work); the
// end-to-end check, `ESPICE_GPU_LU_CHECK=1` under `ESPICE_PERF=g3`, needs a GPU.
test "Hold: an epoch reaches the device LU after hold_refactors host refactors" {
    var h: Hold = .{};
    try std.testing.expect(!h.ready(1));
    // Calls that do not refactor never admit the epoch.
    for (0..3 * hold_refactors) |_| h.count(1, false);
    try std.testing.expect(!h.ready(1));
    for (0..hold_refactors - 1) |_| {
        h.count(1, true);
        try std.testing.expect(!h.ready(1));
    }
    h.count(1, true);
    try std.testing.expect(h.ready(1));
    // A new epoch starts the count over; the old one is forgotten.
    try std.testing.expect(!h.ready(2));
    h.count(2, true);
    try std.testing.expect(!h.ready(2) and !h.ready(1));
    for (0..hold_refactors - 1) |_| h.count(2, true);
    try std.testing.expect(h.ready(2));
}
