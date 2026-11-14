//! `.if` chains. In: an `.if`/`.elseif`/`.else`/`.endif` card and the frame it
//! is read under. Out: the open chains' state, the kept branch live.
//! Cites: ngspice inp.c recifeval; numparam xpressn.c (`=` as equality).
//!
//! Contents:
//! - `pub fn branch(r: *Reader, b: *Branches, card: CondCard, f: *F, frame: *const Frame) Error!void`
//! - `pub fn condition(r: *Reader, f: *F, frame: *const Frame) Error!bool`
//! - `pub fn loneEqualsDoubled(arena: Allocator, text: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const Ast = @import("../Ast.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_values = @import("reader_values.zig");
const tokenizer = @import("../tokenizer.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const CondCard = tokenizer.CondCard;
const Branches = card_table.Branches;
const Frame = reader_frame.Frame;
const Allocator = std.mem.Allocator;

/// Applies one `.if`/`.elseif`/`.else`/`.endif` card to `b`. A
/// condition is the rest of the line, evaluated under `frame` only
/// when its branch could still be taken; nonzero is true.
pub fn branch(r: *Reader, b: *Branches, card: CondCard, f: *F, frame: *const Frame) Error!void {
    if (card == .@"if") {
        if (b.depth == Branches.max) return error.ParseError;
        b.open[b.depth] = if (!b.active()) .spent else if (try condition(r, f, frame)) .live else .pending;
        b.depth += 1;
        return;
    }
    if (b.depth == 0) return error.ParseError;
    const top = &b.open[b.depth - 1];
    switch (card) {
        .@"if" => unreachable,
        .elseif => top.* = if (top.* != .pending) .spent else if (try condition(r, f, frame)) .live else .pending,
        .@"else" => top.* = if (top.* == .pending) .live else .spent,
        .endif => b.depth -= 1,
    }
}

pub fn condition(r: *Reader, f: *F, frame: *const Frame) Error!bool {
    // A condition is folded here and never re-read.
    var own = frame.*;
    own.keep_live = false;
    if (frame.sub == null) try r.decl.cond_texts.append(r.arena, f.rest());
    const text = try loneEqualsDoubled(r.arena, f.rest());
    return switch (try reader_values.exprValue(r, text, &own, false)) {
        .num => |n| n != 0,
        else => error.ParseError,
    };
}

/// `text` with each lone `=` doubled: numparam reads `=` and `==` as one
/// equality operator (xpressn.c:709-710, 728-730, 819), and `.if
/// (select2 = 2)` is an ngspice condition.
pub fn loneEqualsDoubled(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '=') == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(arena, 2 * text.len);
    for (text, 0..) |c, i| {
        out.appendAssumeCapacity(c);
        const paired = (i > 0 and std.mem.indexOfScalar(u8, "=<>!", text[i - 1]) != null) or
            (i + 1 < text.len and text[i + 1] == '=');
        if (c == '=' and !paired) out.appendAssumeCapacity('=');
    }
    return out.items;
}

// ---- private ----
