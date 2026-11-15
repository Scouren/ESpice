//! A deck in another dialect, translated once before any espice column times
//! it. In: the deck, its dialect, the `sprack` binary, the fixture's scratch
//! directory. Out: the translated ngspice deck and SpiceRack's wall time, or
//! why it failed. The espice columns time the translation, so SpiceRack's
//! time is never inside ESPice's number; the report gives it its own column
//! (`SpiceRack ms`).
//! Cites: SpiceRack's `sprack translate --from A --to B [file]` contract (the
//! netlist on stdout, the report on stderr, exit 1 if anything could not be
//! expressed).
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
    /// The translated deck, `<scratch>/translated.sp`.
    entry: []const u8 = "",
    /// SpiceRack's wall time, by the monotonic clock; 0 when it never started.
    ms: f64 = 0,
    /// Non-empty: why no espice column can run the deck.
    refused: []const u8 = "",
};

/// Runs `exe translate --from DIALECT --to espice DECK` once and writes its
/// stdout to `<scratch>/translated.sp`. Every string is allocated in `a`. A
/// binary that cannot start, a non-zero exit, or an empty stdout is a
/// refusal that says so, never an error: the reference columns still run
/// the deck. Fails only when the file cannot be written or on allocation.
/// Asserts that `dialect` is not ngspice.
// ponytail: no timeout; a hung sprack hangs the bench. Add one when a
// SpiceRack release needs it.
pub fn translate(a: Allocator, io: Io, exe: []const u8, dialect: []const u8, deck: []const u8, scratch: []const u8) !Translation {
    assert(!std.mem.eql(u8, dialect, "ngspice"));
    assert(deck.len != 0 and exe.len != 0);
    const start = Io.Timestamp.now(io, .awake);
    const result = std.process.run(a, io, .{
        .argv = &.{ exe, "translate", "--from", dialect, "--to", "espice", std.fs.path.basename(deck) },
        .cwd = .{ .path = std.fs.path.dirname(deck) orelse "." },
        .stdout_limit = .limited(64 * 1024 * 1024),
    }) catch |err|
        return .{ .refused = try std.fmt.allocPrint(a, "sprack: {s} did not start: {s}", .{ exe, @errorName(err) }) };
    const ms = @as(f64, @floatFromInt(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds)) / 1e6;
    if (!result.term.success()) {
        // The report goes to stderr; its last line names the refusal.
        const notes = std.mem.trim(u8, result.stderr, " \t\r\n");
        const last = notes[if (std.mem.lastIndexOfScalar(u8, notes, '\n')) |i| i + 1 else 0..];
        return .{ .ms = ms, .refused = try std.fmt.allocPrint(a, "sprack refused the deck: {s}", .{last}) };
    }
    if (result.stdout.len == 0) return .{ .ms = ms, .refused = "sprack: no netlist on stdout" };
    const entry = try std.fmt.allocPrint(a, "{s}/translated.sp", .{scratch});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = entry, .data = result.stdout });
    return .{ .entry = entry, .ms = ms };
}
