//! Bytes to logical lines to fields, plus SPICE number literals. In: a
//! deck's bytes. Out: ngspice's comptime syntax: its line iterator, field
//! splitter, number reader and expression flags (lines_ngspice.zig), over
//! the physical-line layer (physical_lines.zig). Other dialects reach the
//! library translated by SpiceRack (src/spicerack.zig).
//! Cites: tests/frontend/grammar/ngspice_lines.peg;
//! dev/research/ngspice-syntax.md; ngspice inpeval.c.
//!
//! Contents:
//! - `pub const ngspice` (lines_ngspice.zig)
//! - `pub const Fields` (fields.zig)
//! - `pub const plainNumber` (spice_number.zig)
//! - `pub const normalize` (physical_lines.zig)

const std = @import("std");
const fields = @import("fields.zig");
const spice_number = @import("spice_number.zig");
const physical_lines = @import("physical_lines.zig");

/// ngspice: title line, case folded, `*` comments, `$`/`;` tails, `+` continuation.
pub const ngspice = @import("lines_ngspice.zig");
/// A field splitter over one line (fields.zig).
pub const Fields = fields.Fields;
/// A plain decimal or scientific number (spice_number.zig).
pub const plainNumber = spice_number.plainNumber;
/// Lowercases a deck and counts its newlines (physical_lines.zig).
pub const normalize = physical_lines.normalize;

test "number literals read as ngspice's INPevaluate" {
    const n = ngspice.parseNum;
    try std.testing.expectEqual(1e7, n("10meg").?);
    try std.testing.expectEqual(1e-10, n("0.1n").?); // not parseFloat("0.1") * 1e-9
    try std.testing.expectEqual(1e-3, n("1m").?);
    try std.testing.expectEqual(1e-3, n("1ms").?);
    try std.testing.expectEqual(1000, n("1k").?);
    try std.testing.expectEqual(1000, n("1e3").?);
    try std.testing.expectEqual(1, n("1e-3k").?);
    try std.testing.expectEqual(0.5, n("+.5").?);
    try std.testing.expectEqual(-3, n("-3").?);
    try std.testing.expectEqual(5, n("5v").?); // an unknown suffix scales by 1
    try std.testing.expectEqual(2e-18, n("2a").?); // atto (#121)
    try std.testing.expectEqual(1000, n("1d3").?); // `d` exponent (#121)
    try std.testing.expectEqual(1, n("1x").?);
    try std.testing.expectApproxEqRel(25.4e-6, n("1mil").?, 1e-15);
    try std.testing.expectEqual(1.0000000000000001e23, n("1e23").?); // glibc's pow(10, 23)
    try std.testing.expect(1.0000000000000001e23 != 1e23);
    // Past +-40 the exponent reads exactly too, as glibc's pow does (#36).
    try std.testing.expectEqual(1e-300, n("1e-300").?);
    try std.testing.expectEqual(1e300, n("1e300").?);
    try std.testing.expectEqual(@as(f64, 3) * @as(f64, 1e45), n("3e45").?); // 3 * pow(10, 45), as inpeval.c
    try std.testing.expectEqual(1.0000000000000001e210, n("1e210").?);
    try std.testing.expectEqual(0, n("1e-331").?);
    try std.testing.expectEqual(0, n("0e400").?);
    try std.testing.expect(std.math.isInf(n("1e400").?));
    for ([_][]const u8{ "", "-", ".", "abc", "e5", "1e+" }) |bad| try std.testing.expectEqual(null, n(bad));
}

test {
    _ = fields;
    _ = spice_number;
    _ = physical_lines;
}
