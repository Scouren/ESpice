//! Diagnostics as rows. In: what a stage cannot read or skips, and the card
//! it came from. Out: one `Row` per diagnostic in `Reader.diag.rows`, in the
//! order the stages met them, and `render`, which logs them all once, spelled
//! as the deck spells each card.
//! Cites: #144 (a refusal names its card); compiler-construction rule 5.
//!
//! Contents:
//! - `pub const Code = enum(u8)`
//! - `pub const Row = struct`
//! - `pub fn failed(r: *Reader, line: []const u8, err: Error) Error`
//! - `pub fn unsupported(r: *Reader, line: []const u8, what: []const u8) Error`
//! - `pub fn note(r: *Reader, row: Row) Allocator.Error!void`
//! - `pub fn render(r: *const Reader) void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const Reader = reader.Reader;
const Error = card_rows.Error;

/// What a row says. `malformed` and `refused` are refusals: they name the
/// card that stopped the read, so the spine's "cannot read the card"
/// fallback stays silent once one is logged. The rest log their own line.
pub const Code = enum(u8) {
    /// `text` is the error's name: "netlist: ParseError: <card>".
    malformed,
    /// `text` says what ESPice cannot run: "netlist: <text>: <card>".
    refused,
    /// No refusal named the card the read stopped on.
    unreadable,
    /// `text` is the caller's live name that no global `.param` defines.
    live_unknown,
    /// `text` is the X card's head.
    nest_depth,
    live_outside,
    /// Warnings below. `text` is the `.control` command.
    control_ignored,
    meas_skipped,
    store_ignored,
    /// `text` is the `.probe` item.
    probe_skipped,
    /// `text` is the dropped key, `letter` the card's (lowercase) letter.
    rcl_dropped,
};

/// One diagnostic. `subject` is the card as the deck spells it (or a text a
/// stage rewrote, as read); a slice, not a card index, since some subjects
/// are no AST card (a rewritten line, a `.param` value).
pub const Row = struct { code: Code, subject: []const u8 = "", text: []const u8 = "", letter: u8 = 0 };

/// Records `line` as malformed (`ParseError`) or unrunnable
/// (`UnsupportedCard`), named by `err`, and returns `err`.
pub fn failed(r: *Reader, line: []const u8, err: Error) Error {
    try refusal(r, .{ .code = .malformed, .subject = r.ast.written(line), .text = @errorName(err) });
    return err;
}

/// Records `line` as `what` ESPice cannot run; returns `UnsupportedCard`.
pub fn unsupported(r: *Reader, line: []const u8, what: []const u8) Error {
    try refusal(r, .{ .code = .refused, .subject = r.ast.written(line), .text = what });
    return error.UnsupportedCard;
}

/// Records a diagnostic that is no refusal (a warning, or an error that
/// logs its own line). Its `subject` is already as the deck spells it.
pub fn note(r: *Reader, row: Row) Allocator.Error!void {
    std.debug.assert(row.code != .malformed and row.code != .refused);
    try r.diag.rows.append(r.arena, row);
}

/// Logs every row, in order. The test runner fails any test that logs an
/// error, so a test logs nothing; it reads `r.diag.rows`.
pub fn render(r: *const Reader) void {
    if (@import("builtin").is_test) return;
    const log = std.log;
    for (r.diag.rows.items) |d| switch (d.code) {
        .malformed, .refused => log.err("netlist: {s}: {s}", .{ d.text, d.subject }),
        .unreadable => {
            // A card with no visible byte prints escaped, never blank.
            const blank = for (d.subject) |c| {
                if (c > ' ' and c < 0x7f) break false;
            } else true;
            if (blank) log.err("netlist: cannot read the card: {f}", .{std.ascii.hexEscape(d.subject, .lower)}) else log.err("netlist: cannot read the card: {s}", .{d.subject});
        },
        .live_unknown => log.err("netlist: live parameter '{s}': no global .param defines it", .{d.text}),
        .nest_depth => log.err("netlist: '{s}': subcircuits nest more than 32 levels", .{d.text}),
        .live_outside => log.err("netlist: a swept parameter is read outside a device or model value", .{}),
        .control_ignored => log.warn("netlist: .control command '{s}' ignored", .{d.text}),
        .meas_skipped => log.warn("netlist: skipped, as ngspice skips an incomplete .meas card or one of an analysis it does not measure (measure.c:286-311): {s}", .{d.subject}),
        .store_ignored => log.warn("netlist: .store: checkpoints are not written; the run is not restartable", .{}),
        .probe_skipped => log.warn("netlist: .probe item '{s}' skipped, as ngspice skips it (inpc_probe.c:118-128): {s}", .{ d.text, d.subject }),
        .rcl_dropped => log.warn("netlist: ignoring unsupported parameter '{s}' of a behavioural {c}, as ngspice drops it: {s}", .{ d.text, std.ascii.toUpper(d.letter), d.subject }),
    };
}

// ---- private ----

/// Appends refusal `row`, counting it only once it is stored.
fn refusal(r: *Reader, row: Row) Allocator.Error!void {
    try r.diag.rows.append(r.arena, row);
    r.diag.refusals += 1;
}

test "rows: refusals count apart from notes, in the order met, spelled as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Ast = @import("../Ast.zig");
    var r: Reader = try .init(arena.allocator(), try Ast.parse(arena.allocator(), "t\nR1 A 0 1K\n.end\n", .deck));
    try note(&r, .{ .code = .store_ignored });
    try std.testing.expectEqual(0, r.diag.refusals);
    try std.testing.expectEqual(error.ParseError, failed(&r, r.ast.line(0), error.ParseError));
    try std.testing.expectEqual(error.UnsupportedCard, unsupported(&r, "made up", "a thing"));
    try std.testing.expectEqual(2, r.diag.refusals);
    const rows = r.diag.rows.items;
    try std.testing.expectEqual(3, rows.len);
    try std.testing.expectEqual(Code.store_ignored, rows[0].code);
    try std.testing.expectEqual(Code.malformed, rows[1].code);
    try std.testing.expectEqualStrings("ParseError", rows[1].text);
    // A card of the deck is named as the deck spells it; other text as read.
    try std.testing.expectEqualStrings("R1 A 0 1K", rows[1].subject);
    try std.testing.expectEqualStrings("made up", rows[2].subject);
}
