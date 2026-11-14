//! `--timing-in-depth`'s split of the transient's step bookkeeping, the
//! work of `Sim.begin` and `Sim.end` outside Newton (N7,
//! docs/perf_research/09-after-the-levers.md "N7 Step bookkeeping").
//! Armed only when the Newton phase clock is (`converger.Workspace.prof.io`
//! non-null); otherwise every `lap` is one null test.
//!
//! Contents:
//! - `pub const StepClock = struct` (`Phase`, `start`, `lap`, `print`)

const std = @import("std");
const assert = std.debug.assert;

/// Wall time per bookkeeping phase, summed over the run.
pub const StepClock = struct {
    io: ?std.Io = null,
    /// Nanoseconds per phase, indexed by `Phase`.
    ns: [5]u64 = @splat(0),
    last: std.Io.Timestamp = .zero,

    /// begin: the attempt's setup (checkpoint, sim state, coefficients,
    /// predictor). charges: the q re-read and LTE snapshot. bound: the
    /// LTE step bounds and order control. ring: the history advance, the
    /// slice rotation, the commit, breakpoint landing and the rebase.
    /// record: the waveform row, VPI accept, stream and breakpoint clamp.
    pub const Phase = enum(u3) { begin, charges, bound, ring, record };

    /// Opens a timed stretch: the time before it is nobody's.
    pub fn start(c: *StepClock) void {
        const io = c.io orelse return;
        c.last = .now(io, .awake);
    }

    /// Charges the time since the last `start` or `lap` to `phase`.
    pub fn lap(c: *StepClock, phase: Phase) void {
        comptime assert(@typeInfo(Phase).@"enum".field_names.len == @typeInfo(@FieldType(StepClock, "ns")).array.len);
        const io = c.io orelse return;
        const now: std.Io.Timestamp = .now(io, .awake);
        c.ns[@backingInt(phase)] += @intCast(c.last.durationTo(now).nanoseconds);
        c.last = now;
    }

    /// The `timing:` line, when armed.
    pub fn print(c: *const StepClock, steps: u32, attempts: u64, states: usize, bound_lanes: bool) void {
        if (c.io == null) return;
        assert(c.io != null);
        assert(c.ns.len == 5);
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6;
            }
        }.f;
        std.debug.print("timing: tran step: accepted={d} attempts={d} charge_states={d} bound_lanes={} begin={d:.3}ms charges={d:.3}ms bound={d:.3}ms ring={d:.3}ms record={d:.3}ms\n", .{
            steps, attempts, states, bound_lanes, ms(c.ns[0]), ms(c.ns[1]), ms(c.ns[2]), ms(c.ns[3]), ms(c.ns[4]),
        });
    }
};
