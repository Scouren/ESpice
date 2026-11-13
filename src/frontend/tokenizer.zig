//! A deck's bytes to logical lines to tokens, built as Zig's own tokenizer
//! is: a `Token` is a tag and the bytes it spans, `Tokenizer.next` is one
//! state machine, and the keywords are one `StaticStringMap`. In: a deck's
//! bytes. Out: the bytes lowercased (`normalize`); its logical lines
//! (`Lines`: `*` comments, `$`/`;` tails, `+` and `\\` continuation); and a
//! line's tokens: `=`, `(`, `)` and `,` are one byte each, a `{...}` or
//! quoted token keeps its delimiters, and anything else is a word. A dot
//! card's word (`tran` of `.tran`) is a keyword: `Token.getKeyword` names
//! its `Card`.
//! Cites: Zig lib/std/zig/tokenizer.zig; tests/frontend/grammar/ngspice_lines.peg
//! (the line spec); dev/research/ngspice-syntax.md §1.3, §1.5, §1.6, §2.2;
//! dev/research/{ngspice,hspice,spectre}-syntax.md (D1, X4, D4; #121).
//!
//! Contents:
//! - `pub const Token = struct`
//! - `pub const Loc = struct`
//! - `pub const Tag`
//! - `pub const keywords`
//! - `pub fn getKeyword(bytes: []const u8) ?Card`
//! - `pub const Card`
//! - `pub const CondCard = enum { @"if", elseif, @"else", endif }`
//! - `pub const Split = Tokenizer("'", true)`
//! - `pub const Lines = struct`
//! - `pub fn next(self: *Lines) Allocator.Error!?[]const u8`
//! - `pub fn Tokenizer(comptime quotes: []const u8, comptime braces: bool) type`
//! - `pub fn init(line: []const u8) Self`
//! - `pub fn next(self: *Self) Token`
//! - `pub fn slice(self: Self, token: Token) []const u8`
//! - `pub fn field(self: *Self) ?[]const u8`
//! - `pub fn peek(self: Self) ?[]const u8`
//! - `pub fn rest(self: Self) []const u8`
//! - `pub fn nextByte(self: *Self) ?u8`
//! - `pub fn takeEq(self: *Self) bool`
//! - `pub fn isWord(f: []const u8) bool`
//! - `pub fn isQuote(c: u8) bool`
//! - `pub fn body(f: []const u8) []const u8`
//! - `pub fn normalize(dst: []u8, src: []const u8) usize`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Kind = @import("core").query.Kind;

/// One token of a logical line: what it is and where it sits.
pub const Token = struct {
    tag: Tag,
    loc: Loc,

    /// Byte range in the tokenizer's line; `end` is one past the last byte.
    pub const Loc = struct { start: usize, end: usize };

    /// `quote` and `brace` span their delimiters; `eof` is the line's end.
    pub const Tag = enum { word, equal, l_paren, r_paren, comma, quote, brace, eof };

    /// Every dot card ESPice accepts, by the word after its dot, lowercased.
    /// A card that only renames one of these is SpiceRack's to translate,
    /// never a second entry: `.sn`, `.snac`, `.snnoise`, `.snxf`, `.snosc`,
    /// `.hbosc`, `.acphasenoise`, `.power`, `.stimuli` and `.jitter` are
    /// unknown cards (spicerack.zig `detect` names them).
    pub const keywords = std.StaticStringMap(Card).initComptime(.{
        .{ "end", .end },                   .{ "ends", .ends },                 .{ "subckt", .subckt },
        // `.macro`/`.eom` and `.parameter(s)`: ngspice 44.2 reads them too
        // (measured), so they stay (#121).
        .{ "macro", .subckt },              .{ "eom", .ends },                  .{ "parameter", .param },
        .{ "parameters", .param },          .{ "func", .func },                 .{ "param", .param },
        .{ "model", .model },               .{ "include", .include },           .{ "hdl", .include },
        .{ "osdi_include", .osdi_include }, .{ "pre_osdi", .pre_osdi },         .{ "verilog", .verilog },
        .{ "option", .options },            .{ "options", .options },           .{ "opt", .options },
        .{ "opts", .options },              .{ "ic", .ic },                     .{ "ac", an(.ac) },
        .{ "dc", an(.dc) },                 .{ "dcmatch", an(.dcmatch) },       .{ "disto", an(.disto) },
        .{ "envelope", an(.envelope) },     .{ "four", an(.four) },             .{ "hb", an(.hb) },
        .{ "matex", an(.matex) },           .{ "hbac", an(.hbac) },             .{ "hbnoise", an(.hbnoise) },
        .{ "hbxf", an(.hbxf) },             .{ "phasenoise", an(.phasenoise) }, .{ "mc", an(.mc) },
        .{ "noise", an(.noise) },           .{ "op", an(.op) },                 .{ "pac", an(.pac) },
        .{ "pnoise", an(.pnoise) },         .{ "pss", an(.pss) },               .{ "pxf", an(.pxf) },
        .{ "pz", an(.pz) },                 .{ "qpss", an(.qpss) },             .{ "sens", an(.sens) },
        .{ "sp", an(.sp) },                 .{ "stb", an(.stb) },               .{ "temp", an(.temp) },
        .{ "tf", an(.tf) },                 .{ "fft", an(.fft) },               .{ "ptdnoise", an(.pnoise) },
        .{ "tran", an(.tran) },             .{ "trannoise", an(.tran_noise) },  .{ "lstb", an(.lstb) },
        .{ "acxf", an(.acxf) },             .{ "dcxf", an(.dcxf) },             .{ "dcinc", an(.dcinc) },
        .{ "lin", an(.sp) },                .{ "acmatch", an(.acmatch) },       .{ "dcsens", an(.dcsens) },
        .{ "hblin", an(.hblin) },           .{ "net", an(.sp) },                .{ "if", cond(.@"if") },
        .{ "elseif", cond(.elseif) },       .{ "else", cond(.@"else") },        .{ "endif", cond(.endif) },
        .{ "meas", .meas },                 .{ "measure", .meas },              .{ "save", .save },
        .{ "nodeset", .nodeset },           .{ "global", .global },             .{ "connect", .connect },
        .{ "store", .store },               .{ "sample", .sample },             .{ "mosra", .mosra },
        .{ "appendmodel", .appendmodel },   .{ "check", .meas },                .{ "dout", .meas },
        .{ "biaschk", .meas },              .{ "pat", .ignored },               .{ "stim", .meas },
        .{ "control", .control },           .{ "endc", .endc },                 .{ "print", .ignored },
        .{ "plot", .ignored },              .{ "probe", .ignored },             .{ "graph", .ignored },
        .{ "width", .ignored },             .{ "title", .ignored },             .{ "protect", .ignored },
        .{ "unprotect", .ignored },         .{ "prot", .ignored },              .{ "unprot", .ignored },
        .{ "csparam", .ignored },
        // Sweep and variation cards (variants.zig), and `.wcd` (#240).
                  .{ "step", .step },                 .{ "data", .data },
        .{ "enddata", .enddata },           .{ "variation", .variation },       .{ "end_variation", .end_variation },
        .{ "wcd", .wcd },
    });

    /// The card a dot card's word names (`tran` of `.tran`), in any case;
    /// null for any other word.
    pub fn getKeyword(bytes: []const u8) ?Card {
        var buf: [keyword_len_max]u8 = undefined;
        if (bytes.len > buf.len) return null;
        return keywords.get(std.ascii.lowerString(buf[0..bytes.len], bytes));
    }

    fn an(kind: Kind) Card {
        return .{ .analysis = kind };
    }

    fn cond(c: CondCard) Card {
        return .{ .cond = c };
    }
};

/// What a logical line is: a device card, a dot card no keyword names
/// (`unknown`), or the dot card its keyword names. `ignored`: a card that
/// only shapes printed output, which ESPice writes in full anyway, or only
/// feeds ngspice's `.control` interpreter, which a batch run skips:
/// `.csparam` makes vectors in its `const` plot and is then commented out
/// (inp.c:1104-1131).
pub const Card = union(enum) { device, unknown, end, ends, subckt, param, func, model, include, osdi_include, pre_osdi, verilog, control, endc, options, ic, nodeset, global, connect, save, store, sample, meas, ignored, mosra, appendmodel, step, data, enddata, variation, end_variation, wcd, analysis: Kind, cond: CondCard };

/// The cards of an `.if` chain.
pub const CondCard = enum { @"if", elseif, @"else", endif };

/// The tokenizer over one logical line of a deck.
pub const Split = Tokenizer("'", true);

/// Logical-line iterator; a joined line is allocated in `arena`.
/// tests/frontend/grammar/ngspice_lines.peg is the spec; section numbers cite
/// dev/research/ngspice-syntax.md.
pub const Lines = struct {
    rest: []const u8,
    arena: Allocator,

    /// The next logical line, continuations joined; null at the end.
    /// The line borrows `rest`'s text, or lives in `arena` when it joins
    /// continuations. Fails only with `OutOfMemory` while joining.
    pub fn next(self: *Lines) Allocator.Error!?[]const u8 {
        var glued: bool = undefined;
        var head: []const u8 = undefined;
        while (true) {
            const raw = nextPhysicalLine(&self.rest) orelse return null;
            const t = std.mem.trim(u8, raw, " \t");
            if (t.len == 0 or isCommentLead(t[0]) or isLoneControl(t)) continue;
            // §1.3: a line starting with `@` ends the file.
            if (t[0] == '@') {
                self.rest = "";
                return null;
            }
            // §1.6: a `+` line with nothing to continue is ignored.
            if (t[0] == '+') continue;
            glued = endsGlued(t);
            head = stripComment(if (glued) unglued(t) else t);
            // §1.5: a line holding only an end-of-line comment (`//x`)
            // becomes a comment line, so a `+` after it continues nothing.
            if (!glued and head.len == 0) continue;
            break;
        }
        var joined: ?std.ArrayList(u8) = null;
        // Each pass consumes a physical line or ends the statement.
        const passes_max = self.rest.len + 1;
        var passes: usize = 0;
        while (true) : (passes += 1) {
            assert(passes <= passes_max);
            if (!glued and startsStatement(self.rest, "+*#$")) break;
            const save = self.rest;
            const raw = nextPhysicalLine(&self.rest) orelse break;
            var u = std.mem.trim(u8, raw, " \t");
            if (glued) {
                // §1.6: the line after a `\\` continues the statement as is.
            } else if (u.len > 0 and u[0] == '+') {
                u = u[1..];
            } else if (u.len == 0 or u[0] == '*' or u[0] == '#' or u[0] == '$') {
                continue;
            } else {
                self.rest = save;
                break;
            }
            glued = endsGlued(u);
            try join(self.arena, &joined, head, " ", stripComment(if (glued) unglued(u) else u));
        }
        return if (joined) |j| j.items else head;
    }

    // ---- private ----

    /// A first byte that makes the line a comment [§1.5]: `*`, `#`, `$`,
    /// `;` silently, and the punctuation ngspice rewrites to `*` with a
    /// warning.
    fn isCommentLead(c: u8) bool {
        return std.mem.indexOfScalar(u8, "*#$;=[]?()&%\"!:,\x0c", c) != null;
    }

    /// True when `t` is one control byte alone or before a blank, as a DOS
    /// end-of-file `^Z`: ngspice rewrites that card to a comment
    /// (inpcom.c:3515-3520, `inp_casefix`).
    fn isLoneControl(t: []const u8) bool {
        return !std.ascii.isWhitespace(t[0]) and !std.ascii.isPrint(t[0]) and
            (t.len == 1 or std.ascii.isWhitespace(t[1]));
    }

    /// `line` up to its end-of-line comment [§1.5], trimmed: `;` or `//`
    /// anywhere, `$` at the start or after a blank, tab or comma, all
    /// outside quotes (a backslash escapes a quote). Braces do not
    /// protect. One scalar pass: cards are short, and stdlib vector
    /// scans cost more in setup than they save.
    fn stripComment(line: []const u8) []const u8 {
        const special = comptime blk: {
            var t: [256]bool = @splat(false);
            for ("'\";/$") |c| t[c] = true;
            break :blk t;
        };
        var quote: u8 = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            // Most bytes are none of the switch's: skip them in a tight loop.
            if (quote == 0) {
                while (i < line.len and !special[line[i]]) i += 1;
            }
            if (i == line.len) break;
            const c = line[i];
            if (quote != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '\'', '"' => quote = c,
                ';' => break,
                '/' => if (i + 1 < line.len and line[i + 1] == '/') break,
                '$' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == ',') break,
                else => {},
            }
        }
        return std.mem.trim(u8, line[0..@min(i, line.len)], " \t");
    }

    /// True when `line` ends in `\\` and blanks [§1.6]: it continues on
    /// the next line, whatever comment sits before the backslashes.
    fn endsGlued(line: []const u8) bool {
        return std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t"), "\\\\");
    }

    /// `line` without its trailing `\\` and blanks.
    fn unglued(line: []const u8) []const u8 {
        const t = std.mem.trimEnd(u8, line, " \t");
        return t[0 .. t.len - 2];
    }
};

/// The longest keyword; `getKeyword` lowercases into a buffer this long.
const keyword_len_max = 16;

/// A tokenizer over one line. `quotes` are the quote bytes, `braces`
/// keeps `{...}` whole. A comptime generic (axis: the quoting; two cases
/// today: ngspice's cards, `Tokenizer("'", true)`, and the include
/// reader's file names, `Tokenizer("\"'", false)`).
pub fn Tokenizer(comptime quotes: []const u8, comptime braces: bool) type {
    return struct {
        line: []const u8,
        pos: usize = 0,

        const Self = @This();

        /// A tokenizer at the start of `line`; tokens borrow `line`.
        pub fn init(line: []const u8) Self {
            return .{ .line = line };
        }

        /// Consumes and returns the next token; `eof` at the end of the
        /// line, and again on every call after. An unterminated quote or
        /// brace runs to the end of the line.
        pub fn next(self: *Self) Token {
            const line = self.line;
            var result: Token = .{ .tag = undefined, .loc = .{ .start = self.pos, .end = undefined } };
            state: switch (State.start) {
                .start => {
                    if (self.pos >= line.len) return .{ .tag = .eof, .loc = .{ .start = line.len, .end = line.len } };
                    switch (line[self.pos]) {
                        ' ', '\t' => {
                            self.pos += 1;
                            result.loc.start = self.pos;
                            continue :state .start;
                        },
                        '=' => {
                            result.tag = .equal;
                            self.pos += 1;
                        },
                        '(' => {
                            result.tag = .l_paren;
                            self.pos += 1;
                        },
                        ')' => {
                            result.tag = .r_paren;
                            self.pos += 1;
                        },
                        ',' => {
                            result.tag = .comma;
                            self.pos += 1;
                        },
                        else => |c| {
                            if (isQuote(c)) continue :state .quote;
                            if (braces and c == '{') continue :state .brace;
                            continue :state .word;
                        },
                    }
                },
                .word => {
                    result.tag = .word;
                    while (self.pos < line.len and !breaks[line[self.pos]]) self.pos += 1;
                    assert(self.pos > result.loc.start);
                },
                .quote => {
                    result.tag = .quote;
                    const close = std.mem.indexOfScalarPos(u8, line, self.pos + 1, line[self.pos]) orelse line.len;
                    self.pos = @min(close + 1, line.len);
                },
                .brace => {
                    result.tag = .brace;
                    var depth: usize = 0;
                    while (self.pos < line.len) : (self.pos += 1) {
                        if (line[self.pos] == '{') depth += 1;
                        if (line[self.pos] == '}') {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                    }
                    self.pos = @min(self.pos + 1, line.len);
                },
            }
            result.loc.end = self.pos;
            return result;
        }

        /// The bytes of `token`.
        pub fn slice(self: Self, token: Token) []const u8 {
            return self.line[token.loc.start..token.loc.end];
        }

        /// `next` as its bytes, null at the end of the line.
        // ponytail: for the readers that tell a token's kind by its first
        // byte (`isWord`, `t[0] == ','`); move one to `next` and its tag
        // when it is next edited.
        pub fn field(self: *Self) ?[]const u8 {
            const token = self.next();
            return if (token.tag == .eof) null else self.slice(token);
        }

        /// The next field, without consuming it.
        pub fn peek(self: Self) ?[]const u8 {
            var copy = self;
            return copy.field();
        }

        /// The unread part of the line, blank-trimmed.
        pub fn rest(self: Self) []const u8 {
            return std.mem.trim(u8, self.line[self.pos..], " \t");
        }

        /// First byte of the next token, skipping blanks but not consuming it.
        pub fn nextByte(self: *Self) ?u8 {
            while (self.pos < self.line.len and (self.line[self.pos] == ' ' or self.line[self.pos] == '\t')) self.pos += 1;
            return if (self.pos < self.line.len) self.line[self.pos] else null;
        }

        /// Consumes a `=` token if one is next: the word just read is a key.
        pub fn takeEq(self: *Self) bool {
            if (self.nextByte() != '=') return false;
            self.pos += 1;
            return true;
        }

        /// True unless `f` is a punctuation, quoted or braced field.
        /// Asserts `f` is non-empty, as every field is.
        pub fn isWord(f: []const u8) bool {
            assert(f.len > 0);
            return !breaks[f[0]];
        }

        /// True for this dialect's quote bytes.
        pub fn isQuote(c: u8) bool {
            inline for (quotes) |q| if (c == q) return true;
            return false;
        }

        /// A `{...}` or quoted field without its delimiters; an unterminated
        /// one loses only its opening byte. Asserts `f` is non-empty.
        pub fn body(f: []const u8) []const u8 {
            assert(f.len > 0);
            const close: u8 = if (f[0] == '{') '}' else f[0];
            return if (f.len >= 2 and f[f.len - 1] == close) f[1 .. f.len - 1] else f[1..];
        }

        // ---- private ----

        const State = enum { start, word, quote, brace };

        /// The bytes that end a word.
        const breaks: [256]bool = blk: {
            var t: [256]bool = @splat(false);
            for (" \t=(),") |c| t[c] = true;
            for (quotes) |q| t[q] = true;
            if (braces) t['{'] = true;
            break :blk t;
        };
    };
}

/// Copies `src` lowercased into `dst` (at least as long) and returns its
/// newline count, in one pass over 32-byte blocks.
// ponytail: hand vectors on purpose; a plain map plus `countScalar`
// vectorizes too, but measured 0.07 against 0.05 ns/byte (two passes).
pub fn normalize(dst: []u8, src: []const u8) usize {
    assert(dst.len >= src.len);
    const V = @Vector(32, u8);
    var lines: usize = 0;
    var i: usize = 0;
    while (i + 32 <= src.len) : (i += 32) {
        const v: V = src[i..][0..32].*;
        const upper = (v >= @as(V, @splat('A'))) & (v <= @as(V, @splat('Z')));
        dst[i..][0..32].* = v | @select(u8, upper, @as(V, @splat(0x20)), @as(V, @splat(0)));
        lines += @popCount(@as(u32, @bitCast(v == @as(V, @splat('\n')))));
    }
    for (src[i..], dst[i..src.len]) |c, *d| d.* = c | @as(u8, @intFromBool(c -% 'A' < 26)) << 5;
    return lines + std.mem.countScalar(u8, src[i..], '\n');
}

// ---- private ----

/// Appends `sep` and a continuation piece to a logical line, copying
/// `head` on first use.
fn join(arena: Allocator, joined: *?std.ArrayList(u8), head: []const u8, sep: []const u8, piece: []const u8) Allocator.Error!void {
    if (joined.* == null) {
        joined.* = .empty;
        try joined.*.?.appendSlice(arena, head);
    }
    try joined.*.?.appendSlice(arena, sep);
    try joined.*.?.appendSlice(arena, piece);
}

/// The next physical line without its `\r`, advancing `rest`.
fn nextPhysicalLine(rest: *[]const u8) ?[]const u8 {
    const src = rest.*;
    if (src.len == 0) return null;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const line = std.mem.trimEnd(u8, src[0..nl], "\r");
    rest.* = if (nl == src.len) src[nl..] else src[nl + 1 ..];
    assert(rest.len < src.len);
    return line;
}

/// Whether the next physical line in `rest` starts a new statement for
/// certain: its first byte past blanks is neither a line end nor one of
/// `keep`, the bytes after which a continuation check must read the line.
/// Lets that check leave the line unread instead of splitting it twice.
fn startsStatement(rest: []const u8, comptime keep: []const u8) bool {
    var k: usize = 0;
    while (k < rest.len and (rest[k] == ' ' or rest[k] == '\t')) k += 1;
    if (k == rest.len) return false;
    return switch (rest[k]) {
        '\r', '\n' => false,
        else => |c| std.mem.indexOfScalar(u8, keep, c) == null, // else: any other byte is text
    };
}

/// Oracle: spec examples. `source`'s tokens have `expected`'s tags, then `eof` at its end.
fn testTokenize(source: []const u8, expected: []const Token.Tag) !void {
    var tokenizer = Tokenizer("'", true).init(source);
    for (expected) |tag| try std.testing.expectEqual(tag, tokenizer.next().tag);
    for (0..2) |_| {
        const last = tokenizer.next();
        try std.testing.expectEqual(Token.Tag.eof, last.tag);
        try std.testing.expectEqual(source.len, last.loc.start);
        try std.testing.expectEqual(source.len, last.loc.end);
    }
}

test "tags" {
    try testTokenize("", &.{});
    try testTokenize("  \t ", &.{});
    try testTokenize("r1 a=1 'x y' {a {b}} (c,d)", &.{ .word, .word, .equal, .word, .quote, .brace, .l_paren, .word, .comma, .word, .r_paren });
    // A `"` is a name byte on a card, and a `}` outside braces too.
    try testTokenize("a\"b\" }x", &.{ .word, .word });
    // Unterminated quotes and braces run to the end of the line.
    try testTokenize("'abc = (", &.{.quote});
    try testTokenize("{a {b} c = (", &.{.brace});
    try testTokenize("w=2*(a+b)", &.{ .word, .equal, .word, .l_paren, .word, .r_paren });
}

test "keywords" {
    try std.testing.expectEqual(Card{ .analysis = .tran }, Token.getKeyword("TRAN").?);
    try std.testing.expectEqual(Card{ .cond = .elseif }, Token.getKeyword("elseif").?);
    try std.testing.expectEqual(Card.wcd, Token.getKeyword("wcd").?);
    try std.testing.expectEqual(null, Token.getKeyword("tranx"));
    try std.testing.expectEqual(null, Token.getKeyword("a_word_longer_than_any_keyword"));
    // `getKeyword` finds every row: each fits its buffer and is lowercase.
    for (Token.keywords.keys()) |k| {
        try std.testing.expect(k.len <= keyword_len_max);
        for (k) |c| try std.testing.expect(!std.ascii.isUpper(c));
    }
}

test "fields" {
    const F = Tokenizer("'", true);
    var f = F.init("r1 a=1 'x y' {a {b}} (c,d)");
    try std.testing.expectEqualStrings("r1", f.peek().?);
    for ([_][]const u8{ "r1", "a", "=", "1", "'x y'", "{a {b}}", "(", "c", ",", "d", ")" }) |want|
        try std.testing.expectEqualStrings(want, f.field().?);
    try std.testing.expectEqual(null, f.field());
    try std.testing.expectEqual(null, f.peek());
    f = F.init("'abc");
    try std.testing.expectEqualStrings("abc", F.body(f.field().?));
    f = F.init("{a {b} c");
    try std.testing.expectEqualStrings("a {b} c", F.body(f.field().?));
    try std.testing.expectEqualStrings("", F.body("'"));
    try std.testing.expectEqualStrings("", F.body("''"));
    f = F.init("k = v  ");
    try std.testing.expectEqualStrings("k", f.field().?);
    try std.testing.expect(f.takeEq());
    try std.testing.expectEqualStrings("v", f.rest());
    try std.testing.expect(!f.takeEq());
    try std.testing.expectEqual('v', f.nextByte());
    try std.testing.expect(F.isWord("abc") and !F.isWord("=") and !F.isWord("'x'") and !F.isWord("{x}"));
    // The include reader's: `"` quotes too, and braces are name bytes.
    const H = Tokenizer("'\"", false);
    var h = H.init("{a+b} {a b} \"b c\"");
    try std.testing.expectEqualStrings("{a+b}", h.field().?);
    try std.testing.expectEqualStrings("{a", h.field().?);
    try std.testing.expectEqualStrings("b}", h.field().?);
    try std.testing.expect(H.isWord("{x}"));
    try std.testing.expectEqualStrings("\"b c\"", h.field().?);
    try std.testing.expect(H.isQuote('"') and !F.isQuote('"'));
}

test normalize {
    var buf: [40]u8 = undefined;
    const src = "R1 A b\nC1 X 0 1P\nV1 IN 0 PWL(0 0 1N 1)\n";
    try std.testing.expectEqual(3, normalize(&buf, src));
    try std.testing.expectEqualStrings("r1 a b\nc1 x 0 1p\nv1 in 0 pwl(0 0 1n 1)\n", buf[0..src.len]);
    var rest: []const u8 = "a\r\n\n b";
    try std.testing.expectEqualStrings("a", nextPhysicalLine(&rest).?);
    try std.testing.expect(!startsStatement(rest, "+"));
    try std.testing.expectEqualStrings("", nextPhysicalLine(&rest).?);
    try std.testing.expect(startsStatement(rest, "+"));
    try std.testing.expectEqualStrings(" b", nextPhysicalLine(&rest).?);
    try std.testing.expectEqual(null, nextPhysicalLine(&rest));
}
