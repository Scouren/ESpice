//! A deck as rows, laid out as Zig's `std.zig.Ast` lays out a file: every
//! card's tokens stored once, and one row per card saying what it is. In:
//! a deck's bytes. Out: `Ast`, and `Cursor`, a reader's place in one
//! card's tokens. A stage reads a card through a cursor and never splits
//! its text again.
//! Cites: Zig lib/std/zig/Ast.zig (`TokenList`, `parse`); tokenizer.zig
//! (the tokens); Parse.zig (the parser).
//!
//! Contents:
//! - `pub const Tokens = std.MultiArrayList(struct { tag: Token.Tag, end: u32 })`
//! - `pub const Cards = std.MultiArrayList(struct { tag: Card, line: []const u8, first: u32 })`
//! - `pub const Error = Allocator.Error || error{ ParseError, UnsupportedCard, CircuitTooLarge }`
//! - `pub const Cursor = struct`
//! - `pub const isWord = Split.isWord`
//! - `pub const isQuote = Split.isQuote`
//! - `pub const body = Split.body`
//! - `pub fn initLine(arena: Allocator, text: []const u8) Allocator.Error!Cursor`
//! - `pub fn next(c: *Cursor) Token`
//! - `pub fn field(c: *Cursor) ?[]const u8`
//! - `pub fn peek(c: Cursor) ?[]const u8`
//! - `pub fn rest(c: Cursor) []const u8`
//! - `pub fn nextByte(c: Cursor) ?u8`
//! - `pub fn takeEq(c: *Cursor) bool`
//! - `pub fn seek(c: *Cursor, arena: Allocator, pos: usize) Allocator.Error!void`
//! - `pub const Mode = enum { deck, cards }`
//! - `pub fn parse(arena: Allocator, src: []const u8, mode: Mode) Error!Ast`
//! - `pub fn joinedAt(ast: *const Ast, byte: [*]const u8) bool`
//! - `pub fn written(ast: *const Ast, text: []const u8) []const u8`
//! - `pub fn inSource(ast: *const Ast, text: []const u8) bool`
//! - `pub fn len(ast: *const Ast) u32`
//! - `pub fn lines(ast: *const Ast) []const []const u8`
//! - `pub fn line(ast: *const Ast, card: u32) []const u8`
//! - `pub fn cursor(ast: *const Ast, card: u32) Cursor`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const Parse = @import("Parse.zig");
const Token = tokenizer.Token;
const Card = tokenizer.Card;
const Split = tokenizer.Split;

/// A token is its tag and the byte after its last, in its card's line. Zig
/// stores a token's start and lexes its end again; a card's tokens are read
/// in order, so this stores the end: a token starts at the first non-blank
/// byte after the token before it. An `eof` row ends each card's tokens.
pub const Tokens = std.MultiArrayList(struct { tag: Token.Tag, end: u32 });

/// A card is what it is (`tag`), its logical line, and its first token's row.
pub const Cards = std.MultiArrayList(struct { tag: Card, line: []const u8, first: u32 });

/// Every way `parse` fails: memory, a PAT source it cannot rewrite
/// (`ParseError` malformed, `UnsupportedCard` unsupported), and a deck of
/// 4 GiB or more (`CircuitTooLarge`).
pub const Error = Allocator.Error || error{ ParseError, UnsupportedCard, CircuitTooLarge };

/// What `parse` reads: a `deck`, whose first line is its title, or `cards`
/// alone (analysis cards added to a built circuit), which also keep a PAT
/// source as written.
pub const Mode = enum { deck, cards };

/// A reader's place in one card's tokens. `pos` is one past the last byte
/// read, so `line[start..pos]` between two reads is the text read.
pub const Cursor = struct {
    line: []const u8,
    /// The unread tokens' rows, up to the card's `eof` row.
    tags: [*]const Token.Tag,
    ends: [*]const u32,
    pos: usize = 0,

    /// True unless a field is a punctuation, quoted or braced one.
    pub const isWord = Split.isWord;
    /// True for a quote byte.
    pub const isQuote = Split.isQuote;
    /// A `{...}` or quoted field without its delimiters.
    pub const body = Split.body;

    /// A cursor at the start of `text`, a card no `Ast` holds (one a stage
    /// rewrote); its token rows live in `arena`.
    pub fn initLine(arena: Allocator, text: []const u8) Allocator.Error!Cursor {
        return initAt(arena, text, 0);
    }

    /// Consumes and returns the next token; `eof` at the card's end, and
    /// again on every call after.
    pub fn next(c: *Cursor) Token {
        const tag = c.tags[0];
        if (tag == .eof) return .{ .tag = .eof, .loc = .{ .start = c.line.len, .end = c.line.len } };
        const token: Token = .{ .tag = tag, .loc = .{ .start = c.start(), .end = c.ends[0] } };
        c.pos = token.loc.end;
        c.tags += 1;
        c.ends += 1;
        return token;
    }

    /// `next` as its bytes, null at the card's end.
    // ponytail: for the readers that tell a token's kind by its first
    // byte (`isWord`, `t[0] == ','`); move one to `next` and its tag
    // when it is next edited.
    pub fn field(c: *Cursor) ?[]const u8 {
        const token = c.next();
        return if (token.tag == .eof) null else c.line[token.loc.start..token.loc.end];
    }

    /// The next field, without consuming it.
    pub fn peek(c: Cursor) ?[]const u8 {
        return if (c.tags[0] == .eof) null else c.line[c.start()..c.ends[0]];
    }

    /// The unread part of the card, blank-trimmed.
    pub fn rest(c: Cursor) []const u8 {
        return std.mem.trim(u8, c.line[c.pos..], " \t");
    }

    /// First byte of the next token, without consuming it.
    pub fn nextByte(c: Cursor) ?u8 {
        return if (c.tags[0] == .eof) null else c.line[c.start()];
    }

    /// Consumes a `=` token if one is next: the word just read is a key.
    pub fn takeEq(c: *Cursor) bool {
        if (c.tags[0] != .equal) return false;
        _ = c.next();
        return true;
    }

    /// Moves to byte `pos`, where a reader of the card's text stopped (an
    /// expression's end). A `pos` inside a token, or before the last one
    /// read, starts a token there, as the tokenizer would: the rest of the
    /// line is split again, in `arena`.
    pub fn seek(c: *Cursor, arena: Allocator, pos: usize) Allocator.Error!void {
        assert(pos <= c.line.len);
        if (pos >= c.pos) {
            while (c.tags[0] != .eof and c.ends[0] <= pos) _ = c.next();
            const inside = c.tags[0] != .eof and c.start() < pos;
            c.pos = pos;
            if (!inside) return;
        }
        c.* = try initAt(arena, c.line, pos);
    }

    // ---- private ----

    /// A cursor at byte `pos` of `text`, over the tokens from there on.
    fn initAt(arena: Allocator, text: []const u8, pos: usize) Allocator.Error!Cursor {
        var tokens: Tokens = .empty;
        try tokens.ensureTotalCapacity(arena, text.len - pos + 1);
        _ = Parse.tokenize(text[pos..], @intCast(pos), tokens.slice(), 0);
        const rows = tokens.slice();
        return .{ .line = text, .tags = rows.items(.tag).ptr, .ends = rows.items(.end).ptr, .pos = pos };
    }

    /// Where the next token starts. Asserts there is one.
    fn start(c: Cursor) usize {
        assert(c.tags[0] != .eof);
        var s = c.pos;
        while (c.line[s] == ' ' or c.line[s] == '\t') s += 1;
        return s;
    }
};

tokens: Tokens.Slice = .empty,
cards: Cards.Slice = .empty,
/// The deck lowercased, byte for byte where the deck has it but for the
/// cards `joined` names.
source: []const u8 = "",
/// The deck as written: what `source` lowercases. Borrowed from `parse`'s
/// `src`.
orig: []const u8 = "",
/// A deck's first line as written, blank-trimmed.
title: []const u8 = "",
/// The byte ranges of `source` that hold a card joined in place from its
/// continuation lines, in text order: the text there is no longer where
/// the deck spells it.
joined: []const [2]u32 = &.{},

const Ast = @This();

/// Splits `src` into cards and tokenizes each once (Parse.zig). Cards are
/// case-insensitive, so they are read off a lowercased copy. Everything
/// returned lives in `arena` but `orig` and `title`, which borrow `src`.
pub fn parse(arena: Allocator, src: []const u8, mode: Mode) Error!Ast {
    return Parse.parse(arena, src, mode);
}

/// Whether the byte at `byte` sits in a card of `source` joined in place.
pub fn joinedAt(ast: *const Ast, byte: [*]const u8) bool {
    if (@intFromPtr(byte) < @intFromPtr(ast.source.ptr)) return false;
    const at = @intFromPtr(byte) - @intFromPtr(ast.source.ptr);
    const after = std.sort.partitionPoint([2]u32, ast.joined, at, struct {
        fn startsBy(pos: usize, range: [2]u32) bool {
            return range[0] <= pos;
        }
    }.startsBy);
    return after > 0 and at < ast.joined[after - 1][1];
}

/// `text` as the deck spells it: the original case when `text` is a slice
/// of `source` that sits where the deck has it, else (a card joined from
/// continuation lines, a rewritten one) the text as read.
pub fn written(ast: *const Ast, text: []const u8) []const u8 {
    if (!ast.inSource(text) or ast.joinedAt(text.ptr)) return text;
    return ast.orig[@intFromPtr(text.ptr) - @intFromPtr(ast.source.ptr) ..][0..text.len];
}

/// Whether `text` is a slice of `source`: bytes that stay put, unchanged,
/// for as long as the `Ast` lives.
pub fn inSource(ast: *const Ast, text: []const u8) bool {
    const at = @intFromPtr(text.ptr);
    const base = @intFromPtr(ast.source.ptr);
    return at >= base and at + text.len <= base + ast.source.len;
}

/// The number of cards.
pub fn len(ast: *const Ast) u32 {
    return @intCast(ast.cards.len);
}

/// Every card's logical line, in deck order.
pub fn lines(ast: *const Ast) []const []const u8 {
    return ast.cards.items(.line);
}

/// Card `card`'s logical line.
pub fn line(ast: *const Ast, card: u32) []const u8 {
    return ast.cards.items(.line)[card];
}

/// A cursor at the start of card `card`.
pub fn cursor(ast: *const Ast, card: u32) Cursor {
    const first = ast.cards.items(.first)[card];
    return .{ .line = ast.cards.items(.line)[card], .tags = ast.tokens.items(.tag).ptr + first, .ends = ast.tokens.items(.end).ptr + first };
}

// ---- private ----

test "seek" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "m1 d g s b w = 2*a +1 l=3 x}y z";
    var c: Cursor = try .initLine(arena, text);
    var want: Split = .init(text);
    var all = c;
    while (want.field()) |t| try std.testing.expectEqualStrings(t, all.field().?);
    try std.testing.expectEqual(null, all.field());
    // To a token boundary: the tokens after it are read as they are.
    while (!c.takeEq()) _ = c.field();
    try c.seek(arena, std.mem.indexOf(u8, text, " l=").?);
    try std.testing.expectEqualStrings("l", c.field().?);
    // Into a token: a token starts there.
    try c.seek(arena, std.mem.indexOf(u8, text, "}y").?);
    try std.testing.expectEqualStrings("}y", c.field().?);
    try std.testing.expectEqualStrings("z", c.field().?);
    try std.testing.expectEqual(null, c.field());
    try std.testing.expectEqual(Token.Tag.eof, c.next().tag);
    // Backwards: the tokens from there on, again.
    try c.seek(arena, std.mem.indexOf(u8, text, "*a").?);
    try std.testing.expectEqualStrings("*a", c.field().?);
    try std.testing.expectEqualStrings("+1", c.field().?);
}
