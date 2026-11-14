//! GPU backend selection test; runs without a GPU. The oracle is the
//! kernel artifacts the build carries (`gompute_kernels.has_cuda`/`has_hip`).
//! Also reaches the host-side tests of the GPU levers: G1's fan-out
//! (`lane_fan.zig`, the frequency rounds in `gpu/freq.zig`), G3's
//! pivot-epoch hold (`gpu/lu_admit.zig`), P1's device-LU rent-or-buy
//! (`lu_price.zig`), and the parity rows for HB samples and coupled
//! inductors on lanes (`gpu/parity_tests.zig`).

const impl = @import("../gpu/context.zig");
const artifacts = @import("gompute_kernels");
const backend = impl.test_access.backend;
const std = @import("std");

test {
    _ = @import("../lane_fan.zig");
    _ = @import("../gpu/lu.zig");
    _ = @import("../gpu/freq.zig");
    _ = @import("../gpu/lu_admit.zig");
    _ = @import("../lu_price.zig");
    _ = @import("../gpu/parity_tests.zig");
}

test "backend selection matches the artifacts this binary carries" {
    // A build with no images must resolve `backend` to null: every other
    // declaration in gpu/context.zig is guarded on it.
    try std.testing.expectEqual(artifacts.has_cuda or artifacts.has_hip, backend != null);
}
