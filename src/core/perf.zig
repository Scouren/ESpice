//! Performance levers under evaluation: one switch per work package of
//! docs/perf_research, all off by default, so one binary runs the shipped
//! path and any lever beside it. The facade parses `ESPICE_PERF` once
//! (`espice/config.zig`) and the value travels in the knobs; nothing here
//! reads the environment. A field comes with its lever's code, never
//! before it, and is deleted when its lever is accepted (its path becomes
//! the only one) or rejected.
//! In: the variable's text. Out: the set of levers that are on.
//! Cites no outside source.
//!
//! Contents:
//! - `pub const Levers = packed struct(u32)` (`all`)
//! - `Levers.parse(text: ?[]const u8) error{UnknownLever}!Levers`
//! - `Levers.any(l: Levers) bool`

const std = @import("std");
const assert = std.debug.assert;

/// Which levers are on. A field is a brief's name in docs/perf_research
/// (`04-levers-cpu.md`, `05-levers-gpu.md`, `08-placement.md`,
/// `09-after-the-levers.md`); the
/// default is the shipped path.
pub const Levers = packed struct(u32) {
    /// Supernode panels in the refactor replay.
    c1: bool = false,
    /// Linear circuits: one confirm per factor.
    c3: bool = false,
    /// The bypass: review rule, key, first iterate, cheap hit.
    c4: bool = false,
    /// Measurement only, with `c4`: the bypass review never turns a batch
    /// off, so a run shows the bypass's ceiling. Deleted with C4's verdict.
    c4h: bool = false,
    /// Lanes past eight, and what idle lanes burn.
    c6: bool = false,
    /// One reduce pass that also forms A.
    c7: bool = false,
    /// The operating point's LU: the kept reordering (`lu_reorder.decide`).
    c8: bool = false,
    /// The dense tail as a tiled factorization on every lane.
    n1: bool = false,
    /// One charge evaluation per accepted step.
    n3: bool = false,
    /// Step bookkeeping outside the Newton phases.
    n7: bool = false,
    /// Lane-affine staging.
    n8: bool = false,
    /// Lane groups: host work on the pool.
    g1: bool = false,
    /// The device refactor: shorter chain steps, supernode chunks.
    g2: bool = false,
    /// Operating-point pivot epochs stay on the host.
    g3: bool = false,
    /// The tail of the device solves.
    g7: bool = false,
    /// Placement: the price as a pure function of the calibration file
    /// and the deck (`--backend auto`).
    p1: bool = false,
    _: u16 = 0,

    /// Every lever on.
    pub const all: Levers = blk: {
        var l: Levers = .{};
        const s = @typeInfo(Levers).@"struct";
        for (s.field_names, s.field_types) |name, T| {
            if (T == bool) @field(l, name) = true;
        }
        break :blk l;
    };

    /// Parses `ESPICE_PERF`: a comma list of lever names, `all`, `none`,
    /// and `-name` to turn one off again, applied left to right
    /// (`all,-c4`). Null or empty turns nothing on.
    /// `error.UnknownLever` on any other name: a typo must not run the
    /// shipped path under a lever's label.
    pub fn parse(text: ?[]const u8) error{UnknownLever}!Levers {
        var l: Levers = .{};
        var it = std.mem.tokenizeScalar(u8, text orelse return l, ',');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (tok.len == 0) continue;
            const off = tok[0] == '-';
            const name = tok[@intFromBool(off)..];
            if (std.mem.eql(u8, name, "all")) {
                l = if (off) .{} else all;
            } else if (!off and std.mem.eql(u8, name, "none")) {
                l = .{};
            } else if (!set(&l, name, !off)) return error.UnknownLever;
        }
        assert(l._ == 0);
        return l;
    }

    /// Whether any lever is on.
    pub fn any(l: Levers) bool {
        assert(l._ == 0);
        return @as(u32, @bitCast(l)) != 0;
    }

    /// Sets the lever called `name`; false when there is none.
    fn set(l: *Levers, name: []const u8, on: bool) bool {
        const s = @typeInfo(Levers).@"struct";
        inline for (s.field_names, s.field_types) |field, T| {
            if (T == bool and std.mem.eql(u8, field, name)) {
                @field(l, field) = on;
                return true;
            }
        }
        return false;
    }
};

// Oracle: hand-written expectations for each rule of the grammar.
test "Levers.parse" {
    const t = std.testing;
    try t.expectEqual(Levers{}, try Levers.parse(null));
    try t.expectEqual(Levers{}, try Levers.parse(""));
    try t.expectEqual(Levers{ .c1 = true, .n3 = true }, try Levers.parse("c1, n3"));
    try t.expectEqual(Levers.all, try Levers.parse("all"));
    var but_c4 = Levers.all;
    but_c4.c4 = false;
    try t.expectEqual(but_c4, try Levers.parse("all,-c4"));
    try t.expectEqual(Levers{ .c3 = true }, try Levers.parse("all,none,c3"));
    try t.expectEqual(Levers{}, try Levers.parse("c1,-all"));
    for ([_][]const u8{ "c9", "c1,c9", "C1", "-none", "c1;c3", "c2", "c5", "n6", "_" }) |bad|
        try t.expectError(error.UnknownLever, Levers.parse(bad));
    try t.expect(!(Levers{}).any());
    try t.expect(Levers.all.any());
    try t.expectEqual(@as(u16, 0), Levers.all._);
    try t.expectEqual(@as(u32, 16), @popCount(@as(u32, @bitCast(Levers.all))));
}

// Oracle: docs/perf_research/18-lever-verdicts.md, "Verdicts": these five
// bits had no reader and were deleted on 2026-11-11. A run that names one
// stops; it never runs the shipped path under the lever's label.
test "Levers.parse: the deleted bits n2, n4, n9, g8, g9 are unknown" {
    for ([_][]const u8{ "n2", "n4", "n9", "g8", "g9", "c1,g9", "all,-n2" }) |gone|
        try std.testing.expectError(error.UnknownLever, Levers.parse(gone));
}
