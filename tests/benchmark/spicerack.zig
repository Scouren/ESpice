//! A deck in another dialect, translated once before any espice column times
//! it. In: the deck, its dialect, the `spice2rack` binary, the fixture's
//! scratch directory. Out: the translated ngspice entry and SpiceRack's wall
//! time, or why it failed. The espice columns time the entry, so SpiceRack's
//! time is never inside ESPice's number; the report gives it its own column
//! (`SpiceRack ms`).
//! Cites: SpiceRack's `spice2rack --dialect D --to espice --kit -o DIR DECK`
//! contract (src/spicerack.zig; ledger row P1-062).
//!
//! Contents:
//! - `pub const Translation = struct`
//! - `pub fn translate(a: Allocator, io: Io, exe: []const u8, dialect: []const u8, deck: []const u8, scratch: []const u8) !Translation`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One translation. `refused` non-empty means it failed and `entry` is empty.
pub const Translation = struct {
    /// The translated deck in the kit directory: SpiceRack's stdout line.
    entry: []const u8 = "",
    /// SpiceRack's wall time, by the monotonic clock; 0 when it never started.
    ms: f64 = 0,
    /// Non-empty: why no espice column can run the deck.
    refused: []const u8 = "",
};

/// Runs `exe --dialect DIALECT --to espice --kit -o SCRATCH/kit DECK` once.
/// Every string is allocated in `a`. A binary that cannot start, a non-zero
/// exit, or a stdout that is not one existing path is a refusal that says
/// so, never an error: the reference columns still run the deck. Fails only
/// when the kit directory cannot be made or on allocation. Asserts that
/// `dialect` is not ngspice.
// ponytail: no timeout; a hung spice2rack hangs the bench. Add one when a
// SpiceRack release needs it.
pub fn translate(a: Allocator, io: Io, exe: []const u8, dialect: []const u8, deck: []const u8, scratch: []const u8) !Translation {
    assert(!std.mem.eql(u8, dialect, "ngspice"));
    assert(deck.len != 0 and exe.len != 0);
    const dir = try std.fmt.allocPrint(a, "{s}/kit", .{scratch});
    try Io.Dir.cwd().createDirPath(io, dir);
    const start = Io.Timestamp.now(io, .awake);
    const result = std.process.run(a, io, .{ .argv = &.{ exe, "--dialect", dialect, "--to", "espice", "--kit", "-o", dir, deck } }) catch |err|
        return .{ .refused = try std.fmt.allocPrint(a, "spicerack: {s} did not start: {s}", .{ exe, @errorName(err) }) };
    const ms = @as(f64, @floatFromInt(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds)) / 1e6;
    if (!result.term.success()) {
        // SpiceRack's coded diagnostics go to stderr; the last one names the refusal.
        const notes = std.mem.trim(u8, result.stderr, " \t\r\n");
        const last = notes[if (std.mem.lastIndexOfScalar(u8, notes, '\n')) |i| i + 1 else 0..];
        return .{ .ms = ms, .refused = try std.fmt.allocPrint(a, "spicerack refused the deck: {s}", .{last}) };
    }
    const entry = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (entry.len == 0 or std.mem.indexOfScalar(u8, entry, '\n') != null) return .{ .ms = ms, .refused = "spicerack: no single entry path on stdout" };
    Io.Dir.cwd().access(io, entry, .{}) catch return .{ .ms = ms, .refused = "spicerack: its entry path does not exist" };
    return .{ .entry = entry, .ms = ms };
}
