//! Coupled inductors on transient lanes (16-gpu-parity.md row 9). kinduc's
//! cross terms are ordinary charge stamps (`I(br1) <+ ddt(-m*V(br2))`),
//! which the lane eval and charge kernels already run; what differs is the
//! LTE. With a K card the host's LTE states are not the charge tape alone
//! (`sim_init`, after ngspice's one INDflux per inductor): the inductor and
//! kinduc tape spans read zero and each inductor branch row's q is
//! appended (`host_ops.lteSnap`). The lanes keep the same `n_lt` states
//! per ring slot, and after each charge pass `lk.lteFix` makes slot 0 what
//! `lteSnap` makes it. Without a K card the table is empty and nothing
//! runs.
//! In: `Sim.n_qt`, `lte_zero`, `lte_rows`. Out: the fix table, its launch.
//! Cites: ngspice indload.c:70-77.
//!
//! Contents:
//! - `pub const Fix = struct` (`deinit`)
//! - `pub fn table(gpa: std.mem.Allocator, n_tape: usize, zero: []const [2]u32, rows: []const u32) !Fix`
//! - `pub fn run(self: *GpuLanes, mask: *Buffer) !void`

const std = @import("std");
const assert = std.debug.assert;
const gompute = @import("gompute");
const lk = @import("solver").lane_kernels;
const lanes = @import("lanes.zig");
const lanes_batch = @import("lanes_batch.zig");
const GpuLanes = lanes.GpuLanes;
const Buffer = lanes_batch.Buffer;
const arg = gompute.interface.arg;

/// The fix-up after a charge pass, entry by entry: column `dst[e]` of a
/// lane's slot 0 takes q row `src[e]`, or 0 where `src[e]` is
/// `lk.lte_zero_src`. Spans first, then the appended rows.
pub const Fix = struct {
    dst: []u32,
    src: []u32,

    /// Frees both columns.
    pub fn deinit(f: Fix, gpa: std.mem.Allocator) void {
        gpa.free(f.dst);
        gpa.free(f.src);
    }
};

/// The fix table of a lane whose tape is `n_tape` long, with `lteSnap`'s
/// `zero` spans and `rows`: the LTE states are then `n_tape + rows.len`.
/// Empty without a K card. Caller owns it (`Fix.deinit`).
pub fn table(gpa: std.mem.Allocator, n_tape: usize, zero: []const [2]u32, rows: []const u32) !Fix {
    var m: usize = rows.len;
    for (zero) |z| {
        assert(z[0] <= z[1] and z[1] <= n_tape);
        m += z[1] - z[0];
    }
    const dst = try gpa.alloc(u32, m);
    errdefer gpa.free(dst);
    const src = try gpa.alloc(u32, m);
    var e: usize = 0;
    for (zero) |z| for (z[0]..z[1]) |j| {
        dst[e] = @intCast(j);
        src[e] = lk.lte_zero_src;
        e += 1;
    };
    for (rows, 0..) |r, k| {
        assert(r != lk.lte_zero_src);
        dst[e] = @intCast(n_tape + k);
        src[e] = r;
        e += 1;
    }
    assert(e == m);
    return .{ .dst = dst, .src = src };
}

/// `arp_lane_lte_fix` over the lanes of `mask`, on the slots the charge
/// pass just wrote (`d_slot0`), reading its q plane. Asserts a table.
pub fn run(self: *GpuLanes, mask: *Buffer) !void {
    if (comptime !lanes.available) return error.BackendUnavailable;
    assert(self.n_fix > 0);
    var nl: u64 = self.n_lanes;
    var m: u64 = self.n_fix;
    var n_lt: u64 = self.n_qt;
    try self.launch(&self.k.lte_fix, self.n_lanes, &.{
        arg(&nl),                    arg(&m),                     arg(&n_lt),            mask.argPtr(),               self.buf(.slot0).argPtr(),
        self.buf(.lte_dst).argPtr(), self.buf(.lte_src).argPtr(), self.buf(.q).argPtr(), self.buf(.ring_qt).argPtr(),
    });
}
