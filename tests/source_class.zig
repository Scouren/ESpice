//! The source-waveform class (SpiceRack P8-060). Each waveform has one deck,
//! tran/source_t0_<name>.sp, that samples V and I sources with TD = 0 and
//! TD > 0 at t = 0 and just past TD against ngspice 44.2. The test compares
//! name lists, never counts: the waveforms expected to match ngspice are
//! every waveform less the named gaps, and only the gaps' decks carry
//! `* KNOWN GAP:`. The corpus run then holds each unmarked deck to PASS and
//! each marked one to XFAIL, by name in tests/VERDICTS.tsv.
const std = @import("std");
const catalog = @import("fixture_catalog");

/// Every source waveform ngspice draws. src/frontend/Circuit/net_waves.zig checks
/// its `Wave` tags against the same list.
const waveforms = [_][]const u8{ "am", "exp", "pulse", "pwl", "sffm", "sin", "trnoise", "trrandom" };
/// Waveforms espice refuses (#72).
const gaps = [_][]const u8{ "trnoise", "trrandom" };
const prefix = "conformance/tests/netlist/tran/source_t0_";

fn isIn(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

// Oracle: the decks' ngspice 44.2 values, through the corpus verdicts; this
// test fixes which names those verdicts may excuse.
test "every source waveform has its t = 0 class deck, and only gaps are excused" {
    var wrong = false;
    inline for (waveforms) |name| {
        // A missing deck is a compile error here, naming the path.
        const deck = @embedFile(prefix ++ name ++ ".sp");
        const excused = std.mem.indexOf(u8, deck, "* KNOWN GAP:") != null;
        if (excused != comptime isIn(&gaps, name)) {
            std.debug.print("source class: {s} is {s} in gaps but its deck is {s}\n", .{
                name,
                if (comptime isIn(&gaps, name)) "listed" else "not listed",
                if (excused) "marked KNOWN GAP" else "unmarked",
            });
            wrong = true;
        }
    }
    for (catalog.spice_files) |path| {
        const rest = std.mem.cutPrefix(u8, path, prefix) orelse continue;
        const name = rest[0 .. rest.len - ".sp".len];
        if (!isIn(&waveforms, name)) {
            std.debug.print("source class: {s} names no waveform in tests/source_class.zig\n", .{path});
            wrong = true;
        }
    }
    try std.testing.expect(!wrong);
}
