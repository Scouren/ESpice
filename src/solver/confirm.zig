//! Lever c3, a linear circuit's confirming Newton iteration without its
//! factor: stage 1 (`settle`: the second iteration takes a zero step) and
//! stage 2 (`linearAccept`: the second iteration is not run). `newton`
//! calls `settle` once per W = 1 iteration; with c3 off it returns false
//! and nothing else runs.
//!
//! In: the workspace and the assembled matrix at x_k. Out: `ws.dx`
//! settled, or false for `newton`'s own factor and solve.
//!
//! Cites docs/perf_research/04-levers-cpu.md (C3), 02-baseline.md (the
//! confirming-iteration census).
//!
//! Contents:
//! - `pub const Stats = struct`
//! - `pub fn settle(ws: *Workspace, v: []const f64, iter: u16, init_fix: bool) bool`
//! - `pub fn linearAccept(ws: *Workspace, sys: anytype, x: []const f64, init_fix: bool, max_iter: u16) bool`

const std = @import("std");
const assert = std.debug.assert;
const Workspace = @import("newton_workspace.zig").Workspace;
const newton_sys = @import("newton_sys.zig");

/// Lever c3's counters on one workspace, summed over its solves.
pub const Stats = struct {
    /// Stage 1: confirming iterations that took the zero step, with no solve.
    linear_skips: u64 = 0,
    /// Stage 2: solves accepted at x_1 with the second iteration not run.
    linear_accepts: u64 = 0,
};

/// Lever c3 stage 1: on a linear circuit (`ws.linear`), at iteration 1
/// outside INITFIX, with the matrix `v` bitwise the one iteration 0
/// factored, the update is rounding noise; sets `ws.dx` to 0 and returns
/// true. Otherwise returns false and leaves the factor and solve to
/// `newton`. `finalizeStep` still runs every gate. Asserts that `v` holds
/// the pattern's values.
pub fn settle(ws: *Workspace, v: []const f64, iter: u16, init_fix: bool) bool {
    const slv = &ws.slv;
    const n = slv.n;
    assert(v.len >= slv.col_ptr[n]);
    assert(ws.dx.len >= n);
    if (!(ws.knobs.perf.c3 and ws.linear and iter == 1 and !init_fix and slv.unchanged(v))) return false;
    @memset(ws.dx[0..n], 0);
    ws.confirm.linear_skips += 1;
    return true;
}

/// Lever c3 stage 2, after iteration 0 refused only as the first iterate:
/// accepts a linear circuit's solve at x_1 = x, the point the confirming
/// iteration would publish, without running that iteration. Its products
/// are fed elsewhere (the trace in impl-c2-c3-w3.md): the matrix is the one
/// just factored (the flag), staging runs here at x_1 as `finalizeStep`
/// would, and every later reader of the planes re-evaluates them, except
/// N3's staged accept, which reads them as the last assembly at x (the
/// caller keeps `n3` off) and `-Dcertify`, refused here. The residual and
/// device gates at x_1 are not run; they fail only where the solve itself
/// was inaccurate, where ngspice accepts too (04-levers-cpu.md C3).
/// Returns false and changes nothing but the staging when a device flips
/// there; the confirming iteration then runs and stages again (`updateStates`
/// reverts first). Asserts that `x` holds n values.
pub fn linearAccept(ws: *Workspace, sys: anytype, x: []const f64, init_fix: bool, max_iter: u16) bool {
    const S = newton_sys.Deref(@TypeOf(sys));
    const n = ws.slv.n;
    assert(x.len == n);
    assert(ws.x_old.len >= n);
    if (!(ws.linear and !init_fix and max_iter >= 2)) return false;
    if (comptime @hasDecl(S, "certify") and S.certify) return false;
    if (comptime @hasDecl(S, "updateStates")) if (sys.updateStates(x) != null) return false;
    // What the confirming iteration's update leaves: x_old = x_1.
    @memcpy(ws.x_old[0..n], x);
    ws.confirm.linear_accepts += 1;
    return true;
}

test {
    _ = @import("confirm_tests.zig");
}
