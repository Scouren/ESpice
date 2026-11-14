//! The card parser, as Zig's `std.zig.Parse` is its file parser: the state
//! of one `Ast.parse`. In: a deck's bytes. Out: the `Ast`'s token and card
//! rows. A card whose lines hold no quote, comment or glue is read off the
//! text in one scan, its `+` lines joined in place; any other goes through
//! tokenizer.zig's line splitter, whose rules both paths follow.
//! Cites: Zig lib/std/zig/Parse.zig; tokenizer.zig (the line rules);
//! pattern.zig (HSPICE PAT sources).
//!
//! Contents:
//! - `pub fn parse(arena: Allocator, src: []const u8, mode: Mode) Error!Ast`
//! - `pub fn tokenize(text: []const u8, base: u32, rows: Tokens.Slice, at: usize) u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const pattern = @import("Parse/pattern.zig");
const Ast = @import("Ast.zig");
const Token = tokenizer.Token;
const Card = tokenizer.Card;
const Split = tokenizer.Split;
const Tokens = Ast.Tokens;
const Cards = Ast.Cards;
const Cursor = Ast.Cursor;
const Error = Ast.Error;
const Mode = Ast.Mode;

tokens: Tokens = .empty,
cards: Cards = .empty,
/// `Ast.joined`, as it grows.
joined: std.ArrayList([2]u32) = .empty,
/// The continuation lines of the card being read: their text's bounds.
pieces: std.ArrayList([2]usize) = .empty,

const Parse = @This();

/// The most tokens a card read off the deck text in one scan holds; a
/// longer card takes the line splitter's path.
const plain_tokens_max = 255;

/// What a byte is to the one-scan card reader (`plainPiece`).
const Class = enum(u8) { word, blank, punct, brace, slash, eol, cr, bail };

/// `bail`: a byte the line rules give a meaning the scan does not follow
/// (a quote, a `;` or `$` comment, a `\\` glue). `slash` is one before a
/// second `/`, `cr` unless a newline follows.
const classes: [256]Class = blk: {
    var t: [256]Class = @splat(.word);
    for (" \t") |c| t[c] = .blank;
    for ("=(),") |c| t[c] = .punct;
    for ("'\";$\\") |c| t[c] = .bail;
    t['{'] = .brace;
    t['/'] = .slash;
    t['\n'] = .eol;
    t['\r'] = .cr;
    break :blk t;
};

/// What a physical line's first byte past its blanks makes of the line.
const Head = enum(u8) { card, skip, slow };

/// `skip`: a comment line (tokenizer.zig `isCommentLead`), a `+` with
/// nothing to continue, or a blank line. `slow`: a line the splitter reads
/// (`@`, a control byte, a byte `classes` bails on).
const heads: [256]Head = blk: {
    var t: [256]Head = @splat(.slow);
    for (0x21..0x7f) |c| t[c] = .card;
    for ("*#$;=[]?()&%\"!:,\x0c+\n") |c| t[c] = .skip;
    for ("@'/\\") |c| t[c] = .slow;
    break :blk t;
};

/// A physical line `plainPiece` read: its token count, its text's bounds
/// (blank-trimmed; `start == end` for a blank one), and where the next
/// physical line starts.
const Piece = struct { tokens: u32, start: usize, end: usize, next: usize };

/// What follows a plain card's physical line: the next statement, at
/// `resume_at`, or a `+` line that continues the card, its `+` at `plus`.
const After = union(enum) { resume_at: usize, plus: usize };

/// Splits `src` into cards and tokenizes each once. Cards are
/// case-insensitive, so they are read off a lowercased copy. A card whose
/// lines hold no quote, comment or glue is read in one scan (`plainPiece`),
/// its `+` lines joined in place; any other is split by tokenizer.zig,
/// whose rules both follow. A deck's HSPICE PAT sources are rewritten
/// (pattern.zig). Everything returned lives in `arena` but `title`, which
/// borrows `src`.
pub fn parse(arena: Allocator, src: []const u8, mode: Mode) Error!Ast {
    if (src.len >= std.math.maxInt(u32)) return error.CircuitTooLarge;
    const source = try arena.allocSentinel(u8, src.len, '\n');
    const line_hint = tokenizer.normalize(source, src);
    // A deck's first line is its title, not a card. Case folding keeps
    // byte positions, so the title is `src`'s.
    const title_end = if (mode == .deck) std.mem.indexOfScalar(u8, source, '\n') orelse source.len else 0;
    const text = source[if (mode == .deck) @min(title_end + 1, source.len) else 0..];
    const text_at = source.len - text.len;
    // A card starts on a physical line of its own.
    var parser: Parse = .{};
    const cards = &parser.cards;
    const tokens = &parser.tokens;
    const joined = &parser.joined;
    const pieces = &parser.pieces;
    try cards.ensureTotalCapacity(arena, line_hint + 1);
    // About one row per three bytes; a deck denser than that grows it.
    try tokens.ensureTotalCapacity(arena, text.len / 3 + plain_tokens_max + 1);
    var split: tokenizer.Lines = .{ .rest = text, .arena = arena };
    var any_pat = false;
    var at: usize = 0;
    while (at < text.len) {
        var q = at;
        while (text[q] == ' ' or text[q] == '\t') q += 1;
        const head = heads[text[q]];
        if (head == .skip) {
            at = lineEnd(text, q) + 1;
            continue;
        }
        const first: u32 = @intCast(tokens.len);
        var l: []const u8 = undefined;
        read: {
            if (head == .card) plain: {
                try tokens.ensureUnusedCapacity(arena, plain_tokens_max + 1);
                var rows = tokens.slice();
                // Inlined here, where every card of a flat deck is read.
                var piece = @call(.always_inline, plainPiece, .{ text, q, 0, rows, first }) orelse break :plain;
                tokens.len += piece.tokens;
                // Where the card's text ends once its lines are joined.
                var end = piece.end;
                var next = piece.next;
                // The usual next line starts a card at its first byte.
                if (heads[text[next]] != .card) {
                    pieces.clearRetainingCapacity();
                    while (true) switch (nextStatement(text, piece.next)) {
                        .resume_at => |p| {
                            next = p;
                            break;
                        },
                        // A continuation line's text follows one blank.
                        .plus => |k| {
                            try tokens.ensureUnusedCapacity(arena, plain_tokens_max + 1);
                            rows = tokens.slice();
                            piece = plainPiece(text, k + 1, @intCast(end + 1 - q), rows, tokens.len) orelse break :plain;
                            tokens.len += piece.tokens;
                            try pieces.append(arena, .{ piece.start, piece.end });
                            end += 1 + (piece.end - piece.start);
                        },
                    };
                    // Each continuation moves down to one blank after the
                    // text before it: its `+` and the newline before that
                    // make room.
                    var w = end;
                    for (pieces.items) |p| w -= 1 + (p[1] - p[0]);
                    for (pieces.items) |p| {
                        assert(w + 1 < p[0] or p[0] == p[1]);
                        text[w] = ' ';
                        std.mem.copyForwards(u8, text[w + 1 ..][0 .. p[1] - p[0]], text[p[0]..p[1]]);
                        w += 1 + (p[1] - p[0]);
                    }
                    assert(w == end);
                    if (pieces.items.len > 0) try joined.append(arena, .{ @intCast(text_at + q), @intCast(text_at + end) });
                }
                assert(tokens.len < tokens.capacity);
                rows.items(.tag).ptr[tokens.len] = .eof;
                rows.items(.end).ptr[tokens.len] = @intCast(end - q);
                tokens.len += 1;
                l = text[q..end];
                at = next;
                break :read;
            }
            tokens.len = first;
            split.rest = text[at..];
            l = try split.next() orelse break;
            at = text.len - split.rest.len;
            // A line left blank (`\\` glued to a blank line, or a lone
            // `\\` at the end) is no card (#164, #38).
            if (std.mem.trim(u8, l, " \t").len == 0) continue;
            try tokens.ensureUnusedCapacity(arena, l.len + 1);
            tokens.len += tokenize(l, 0, tokens.slice(), first);
        }
        any_pat = any_pat or switch (l[0]) {
            'v', 'i' => std.mem.indexOf(u8, l, "pat") != null,
            '.' => std.mem.startsWith(u8, l, ".pat "),
            else => false,
        };
        const tag: Card = if (l[0] != '.') .device else Token.getKeyword(l[1..tokens.items(.end)[first]]) orelse .unknown;
        cards.appendAssumeCapacity(.{ .tag = tag, .line = l, .first = first });
    }
    // Only a `.pat` card or a V or I card holding `pat` makes `rewrite`
    // do anything; the cards it rewrites get new rows after the rest.
    if (any_pat and mode == .deck) {
        const all = cards.items(.line);
        const before = try arena.dupe([]const u8, all);
        pattern.rewrite(arena, all) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidPattern => error.ParseError,
            error.UnsupportedPattern => error.UnsupportedCard,
        };
        for (all, before, cards.items(.first)) |l, old, *first| {
            if (l.ptr == old.ptr and l.len == old.len) continue;
            try tokens.ensureUnusedCapacity(arena, l.len + 1);
            first.* = @intCast(tokens.len);
            tokens.len += tokenize(l, 0, tokens.slice(), tokens.len);
        }
    }
    return .{ .tokens = tokens.slice(), .cards = cards.slice(), .source = source, .orig = src, .title = std.mem.trim(u8, src[0..title_end], " \t\r"), .joined = joined.items };
}

/// Writes `text`'s tokens and their `eof` row to `rows` from row `at` on,
/// each end `base` bytes further, and returns the row count. Asserts
/// `rows` has room for a row per byte of `text` and one more.
pub fn tokenize(text: []const u8, base: u32, rows: Tokens.Slice, at: usize) u32 {
    assert(rows.capacity - at > text.len);
    const tags = rows.items(.tag).ptr + at;
    const ends = rows.items(.end).ptr + at;
    var n: u32 = 0;
    var t: Split = .init(text);
    while (true) : (n += 1) {
        const token = t.next();
        tags[n] = token.tag;
        ends[n] = base + @as(u32, @intCast(token.loc.end));
        if (token.tag == .eof) return n + 1;
    }
}

// ---- private ----

/// The physical line from `text[from]` on, tokenized into `rows` from row
/// `at` on as `tokenize` would its trimmed text, each end `base` bytes
/// further; null when the line holds a byte the line rules read (`bail`),
/// an open brace, or more than `plain_tokens_max` tokens, with `rows`
/// then holding nothing to keep. Asserts `rows` has room for
/// `plain_tokens_max` rows.
fn plainPiece(text: [:'\n']const u8, from: usize, base: u32, rows: Tokens.Slice, at: usize) ?Piece {
    assert(rows.capacity - at >= plain_tokens_max);
    const tags = rows.items(.tag).ptr + at;
    const ends = rows.items(.end).ptr + at;
    var n: u32 = 0;
    var i = from;
    while (text[i] == ' ' or text[i] == '\t') i += 1;
    const start = i;
    // Where the card's byte 0 would sit were this line its head.
    const origin = start - base;
    const next_line: usize = while (true) {
        const c = text[i];
        switch (classes[c]) {
            .blank => {
                i += 1;
                continue;
            },
            .eol => break i + 1,
            .cr => if (text[i + 1] == '\n') break i + 2 else return null,
            .bail => return null,
            .punct => {
                tags[n] = switch (c) {
                    '=' => .equal,
                    '(' => .l_paren,
                    ')' => .r_paren,
                    else => .comma, // else: the fourth `punct` byte
                };
                i += 1;
            },
            .word, .slash => {
                tags[n] = .word;
                while (true) : (i += 1) {
                    while (classes[text[i]] == .word) i += 1;
                    if (text[i] != '/') break;
                    if (text[i + 1] == '/') return null;
                }
            },
            .brace => {
                tags[n] = .brace;
                var depth: usize = 0;
                while (true) : (i += 1) switch (classes[text[i]]) {
                    .brace => depth += 1,
                    .word => if (text[i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    .slash => if (text[i + 1] == '/') return null,
                    .eol, .cr, .bail => return null,
                    .blank, .punct => {},
                };
                i += 1;
            },
        }
        ends[n] = @intCast(i - origin);
        n += 1;
        if (n == plain_tokens_max) return null;
    };
    return .{ .tokens = n, .start = start, .end = if (n == 0) start else origin + ends[n - 1], .next = @min(next_line, text.len) };
}

/// What follows a plain card's physical line, `from` being the start of
/// the line after it: blank and comment lines are passed over, as the
/// line splitter passes them looking for a `+`.
fn nextStatement(text: [:'\n']const u8, from: usize) After {
    var p = from;
    while (p < text.len) {
        var k = p;
        while (text[k] == ' ' or text[k] == '\t') k += 1;
        switch (text[k]) {
            '+' => return .{ .plus = k },
            '\n' => p = k + 1,
            '*', '#', '$' => p = lineEnd(text, k) + 1,
            '\r' => {
                while (text[k] == '\r') k += 1;
                if (text[k] != '\n') return .{ .resume_at = p };
                p = k + 1;
            },
            else => return .{ .resume_at = p }, // else: a statement's first byte
        }
    }
    return .{ .resume_at = text.len };
}

/// The newline that ends the physical line holding `text[from]`, or
/// `text.len`.
fn lineEnd(text: [:'\n']const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
}

/// Oracle: the tokenizer itself. A cursor over `text`'s rows reads the
/// fields `Split` reads, and `rest` agrees after each.
fn expectSameFields(c_in: Cursor, text: []const u8) !void {
    var c = c_in;
    var t: Split = .init(text);
    while (true) {
        try std.testing.expectEqual(t.nextByte(), c.nextByte());
        const want = t.field();
        const got = c.field();
        if (want == null) return try std.testing.expectEqual(null, got);
        try std.testing.expectEqualStrings(want.?, got.?);
        try std.testing.expectEqualStrings(t.rest(), c.rest());
    }
}

/// Oracle: the reference implementation `parse` shortcuts. `src`'s cards
/// are the non-blank logical lines tokenizer.zig splits, rewritten by
/// pattern.zig, each tokenized as `Split` tokenizes it.
fn expectSameAsSplitter(arena: Allocator, src: []const u8) !void {
    var want: std.ArrayList([]const u8) = .empty;
    var split: tokenizer.Lines = .{ .rest = try arena.dupe(u8, src), .arena = arena };
    while (try split.next()) |l| {
        if (std.mem.trim(u8, l, " \t").len > 0) try want.append(arena, l);
    }
    const got = parse(arena, try std.mem.concat(arena, u8, &.{ "a title\n", src }), .deck);
    pattern.rewrite(arena, want.items) catch |err| return std.testing.expectError(switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPattern => error.ParseError,
        error.UnsupportedPattern => error.UnsupportedCard,
    }, got);
    const ast = try got;
    try std.testing.expectEqual(want.items.len, ast.len());
    for (want.items, 0..) |l, i| {
        const card: u32 = @intCast(i);
        try std.testing.expectEqualStrings(l, ast.line(card));
        try expectSameFields(ast.cursor(card), l);
        var head: Split = .init(l);
        const tag: Card = if (l[0] != '.') .device else Token.getKeyword(head.field().?[1..]) orelse .unknown;
        try std.testing.expectEqual(tag, ast.cards.items(.tag)[card]);
    }
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "r1 a b 1k\n.tran 1n 1u\n+ uic\n.bogus x\n* note\nx1 (a, b) sub w = {2*k} 'q r\n";
    const ast = try parse(arena, text, .cards);
    try std.testing.expectEqual(4, ast.len());
    const tags = ast.cards.items(.tag);
    try std.testing.expectEqual(Card.device, tags[0]);
    try std.testing.expectEqual(Card{ .analysis = .tran }, tags[1]);
    try std.testing.expectEqual(Card.unknown, tags[2]);
    try std.testing.expectEqual(Card.device, tags[3]);
    try std.testing.expectEqualStrings(".tran 1n 1u uic", ast.line(1));
    try expectSameAsSplitter(arena, text);
    // A deck's first line is its title, as written; cards read lowercased.
    const deck = try parse(arena, " My Title \r\nR1 A b 1K\n", .deck);
    try std.testing.expectEqualStrings("My Title", deck.title);
    try std.testing.expectEqual(1, deck.len());
    try std.testing.expectEqualStrings("r1 a b 1k", deck.line(0));
    try std.testing.expect(!deck.joinedAt(deck.line(0).ptr));
    try std.testing.expect(ast.joinedAt(ast.line(1).ptr) and !ast.joinedAt(ast.line(0).ptr) and !ast.joinedAt(ast.line(2).ptr));
}

test "parse reads what the line splitter and the tokenizer read" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // More tokens than one scan holds.
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(arena, "r1");
    for (0..300) |_| try many.appendSlice(arena, " a");
    try many.appendSlice(arena, "\nr2 a b 1\n");
    for ([_][]const u8{
        "",                                          "\n",                                                         "   ",
        "r1 a b 1",                                  "r1 a b 1\r\nr2 b c 2\r\n\r\n* c\r\n+ 3\r\n",                 "r1 a b 1\n \r\r\n+ 2\n",
        "r1 a b 1\n \rx\n",                          "r1 a b 1\r\r\nr2 a b 1\rx\n",                                "r1 a b {x / /y}\nr2 a b {x //y}\n",
        "r1 a/b c 1 // z\nr2 a b 1/\n",              "r1 a b 1 $ c\nr2 a$b c 1\n",                                 "r1 a b 1 \\\\\n 2\nr3 a b \\ 1\n",
        "{a\nr1 a b {c {d} e} f}g\n",                "r1 a b 1\n\n* c\n# d\n$ e\n+ 1\n",                           "@\nr1 a b 1\n",
        "r1 a b 1\n@ stop\nr2 a b 1\n",              "b1 a 0 v='1 ; $x' ; tail\n",                                 "r1 a b \"1 ; 2\" 3\n",
        ".param a = 1 b={a*2}\n.if (a>1)\n.endif\n", ".\n.x\n. tran\n+\n",                                         "\x1a x\nr1 a 0 1\n\x1ar2 a 0 1\n",
        "v1 a 0 pat (1 0 0 1n 1n 5n b1011)\n",       ".pat p = b01\nv1 a 0 pat (1 0 0 1n 1n 5n p)\nipath a 0 1\n", "v1 a 0 pat\n",
        many.items,
    }) |src| try expectSameAsSplitter(arena, src);
    // Seeded byte soup over the bytes the line rules and the tokenizer
    // tell apart: every card boundary and token must agree.
    const alphabet = "rvi.pat1k0 \t  \n\n\n\n\r\r+*#$;//\\\\'\"{}()=,@\x0c\x01\x80";
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var buf: [48]u8 = undefined;
    for (0..20_000) |_| {
        const src = buf[0..random.uintLessThan(usize, buf.len + 1)];
        for (src) |*b| b.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        expectSameAsSplitter(arena, src) catch |err| {
            std.debug.print("differs on: {f}\n", .{std.ascii.hexEscape(src, .lower)});
            return err;
        };
        _ = arena_state.reset(.retain_capacity);
    }
}
