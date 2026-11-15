//! The ESPice netlist language's front end. In: a file whose first line
//! is `.espice 1`. Out: the same deck as legacy cards (the dialect the
//! existing reader reads), or coded rows (`path:line:col`, `E....`) for
//! every problem in the file and `error.ParseError`. Stages: lexer.zig,
//! parse.zig (rows in ast.zig), check.zig against the schema.zig table,
//! lower.zig and the per-area lowerings.
//! Cites: docs/using/language.md (the spec); the implementation contract
//! (lowering to legacy text, per-file gate, coded diagnostics).
//!
//! Contents:
//! - `pub const Role = lower.Role`
//! - `pub const diag`
//! - `pub const Lowered`
//! - `pub fn detect(src: []const u8) bool`
//! - `pub fn lowerRows(gpa: Allocator, arena: Allocator, src: []const u8, role: Role) Allocator.Error!Lowered`
//! - `pub fn lower(gpa: Allocator, arena: Allocator, src: []const u8, path: []const u8, role: Role) error{ OutOfMemory, ParseError }![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const parse = @import("lang/parse.zig");
const lower_ = @import("lang/lower.zig");

/// The diagnostic catalogue, for the tests and the docs.
pub const diag = @import("lang/diag.zig");

/// Whether the file is the deck or one an `.include` or `.lib` reads.
pub const Role = lower_.Role;

/// A lowering's result: the legacy text and every row, both in the
/// caller's arena. The text is meaningful only when no row is an error.
pub const Lowered = struct { text: []const u8, diags: []const diag.Diag };

/// Whether `src` is in the language: its first line is `.espice`, then a
/// blank or the line's end (a version other than 1 is refused later).
pub fn detect(src: []const u8) bool {
    const head = ".espice";
    if (!std.mem.startsWith(u8, src, head)) return false;
    return src.len == head.len or std.mem.indexOfScalar(u8, " \t\r\n", src[head.len]) != null;
}

/// Lexes, parses, checks and lowers `src`. `gpa` holds the scratch, all
/// freed before return; the result lives in `arena`. Fails only with
/// `OutOfMemory`.
pub fn lowerRows(gpa: Allocator, arena: Allocator, src: []const u8, role: Role) Allocator.Error!Lowered {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var diags: diag.Diags = .{ .gpa = scratch.allocator() };
    var tree = try parse.parse(scratch.allocator(), src, &diags);
    var l: lower_.Lowerer = .{ .a = &tree, .arena = scratch.allocator(), .diags = &diags, .role = role };
    try lower_.run(&l);
    std.sort.insertion(diag.Diag, diags.rows.items, {}, struct {
        fn lessThan(_: void, x: diag.Diag, y: diag.Diag) bool {
            return x.at < y.at;
        }
    }.lessThan);
    return .{ .text = try arena.dupe(u8, l.out.items), .diags = try arena.dupe(diag.Diag, diags.rows.items) };
}

/// The one entry every reader of a file goes through: `src` itself when
/// it is not in the language; else `lowerRows`, its rows rendered with
/// `path`, failing with `ParseError` when any is an error. Returns the
/// legacy text in `arena`; `gpa` holds the scratch.
pub fn lower(gpa: Allocator, arena: Allocator, src: []const u8, path: []const u8, role: Role) error{ OutOfMemory, ParseError }![]const u8 {
    if (!detect(src)) return src;
    const got = try lowerRows(gpa, arena, src, role);
    diag.render(src, path, got.diags);
    if (diag.hasError(got.diags)) return error.ParseError;
    return got.text;
}

test {
    _ = diag;
    _ = @import("lang/number.zig");
    _ = @import("tests/lang.zig");
    _ = @import("tests/lang_lower.zig");
    _ = @import("tests/lang_twin.zig");
    _ = @import("tests/lang_spec.zig");
    _ = @import("tests/lang_fuzz.zig");
    _ = @import("tests/lang_meas.zig");
    _ = @import("tests/lang_stats.zig");
    _ = @import("tests/lang_devices.zig");
    _ = @import("tests/lang_analyses.zig");
    _ = @import("tests/lang_sweeps.zig");
}
