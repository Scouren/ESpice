//! The coupled-inductor fix-up of one lane's LTE states (16-gpu-parity.md
//! row 9): after a charge pass writes the tape into a ring slot, the
//! entries `host_ops.lteSnap` zeroes read 0 and the inductor branch rows'
//! q are appended, so the slot holds the host's `n_lt` states. std only:
//! the kernel root compiles this file for NVPTX and AMDGCN.
//! Oracle: `analysis/gpu/parity_tests.zig` (`host_ops.lteSnap`, bitwise).
//! Cites: ngspice indload.c:70-77 (one INDflux state per inductor).
//!
//! Contents:
//! - `pub const lte_zero_src: u32`
//! - `pub fn lteFix(m: usize, dst: anytype, src: anytype, q: anytype, slot: anytype, stride: usize) void`

const std = @import("std");

/// `lteFix`'s source for an entry that reads 0 (a coupled tape span).
pub const lte_zero_src: u32 = std.math.maxInt(u32);

/// Entry e of `m` sets column `dst[e]` of `slot` to q row `src[e]`, or to 0
/// where `src[e]` is `lte_zero_src`: `lteSnap`'s spans and rows, in its
/// values. Columns and rows `stride` apart (1 contiguous, the lane count
/// lane-major), as slices or many-item pointers of any address space.
pub fn lteFix(m: usize, dst: anytype, src: anytype, q: anytype, slot: anytype, stride: usize) void {
    for (0..m) |e| {
        const s = src[e];
        slot[@as(usize, dst[e]) * stride] = if (s == lte_zero_src) 0 else q[@as(usize, s) * stride];
    }
}
