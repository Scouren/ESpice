//! Stage 1 of the ESPice language. In: a file's bytes. Out: `Tokens`, one
//! SoA row per token (`tag`, `start`), the end re-lexed on demand, and
//! coded rows for every byte that is no token. Newlines are tokens: a
//! statement ends at one unless brackets are open (the parser skips them
//! there). `//` comments and blanks make no token.
//! Cites: docs/using/language.md "Files and statements", "Names",
//! "Numbers and units", "Expressions"; compiler-construction rule 1.
//!
//! Contents:
//! - `pub const Tag`
//! - `pub const Token`
//! - `pub const Tokens`
//! - `pub fn lex(gpa: Allocator, src: []const u8, diags: *Diags) Allocator.Error!Tokens`
//! - `pub fn tokenEnd(src: []const u8, tag: Tag, start: u32) u32`
//! - `pub fn isNameStart(c: u8) bool`
//! - `pub fn isNameChar(src: []const u8, i: usize) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag.zig");
const number = @import("number.zig");
const Diags = diag.Diags;

/// What a token is. Operators are named for their spelling.
pub const Tag = enum(u8) {
    /// A name: a letter or `_`, then letters, digits and `_ . $ # !`.
    word,
    /// `.` and a word: a directive's name, the dot included.
    directive,
    /// Digits, fraction, exponent, prefix and unit in one run (number.zig reads it).
    number,
    /// `"..."` on one line, quotes included.
    string,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    equal,
    plus,
    minus,
    star,
    star_star,
    slash,
    percent,
    eq_eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    amp_amp,
    pipe_pipe,
    bang,
    question,
    colon,
    newline,
    eof,
};

/// One token row: its tag and the byte its text starts at.
pub const Token = struct { tag: Tag, start: u32 };

/// A file's tokens; the last row is always `eof`.
pub const Tokens = std.MultiArrayList(Token);

comptime {
    assert(@sizeOf(Tag) == 1);
}

/// Splits `src` into tokens, appending a coded row to `diags` for each
/// byte run that is no token and going on after it. The caller owns the
/// result (`deinit(gpa)`). Fails only with `OutOfMemory`. Asserts `src`
/// fits a `u32` offset.
pub fn lex(gpa: Allocator, src: []const u8, diags: *Diags) Allocator.Error!Tokens {
    assert(src.len < std.math.maxInt(u32));
    var out: Tokens = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, src.len / 4 + 1);
    var i: u32 = 0;
    while (i < src.len) {
        const c = src[i];
        const start = i;
        const tag: ?Tag = switch (c) {
            ' ', '\t', '\r' => null,
            '\n' => .newline,
            '/' => if (at(src, i + 1) == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            } else .slash,
            '"' => blk: {
                const close = std.mem.indexOfAnyPos(u8, src, i + 1, "\"\n") orelse src.len;
                if (close == src.len or src[close] == '\n') {
                    try diags.add(.unterminated_string, start, src[start..close]);
                    i = @intCast(close);
                    continue;
                }
                break :blk .string;
            },
            '0'...'9' => .number,
            '.' => if (at(src, i + 1) != null and std.ascii.isAlphabetic(src[i + 1])) .directive else null,
            '(' => .l_paren,
            ')' => .r_paren,
            '[' => .l_bracket,
            ']' => .r_bracket,
            '{' => .l_brace,
            '}' => .r_brace,
            ',' => .comma,
            '+' => .plus,
            '-' => .minus,
            '%' => .percent,
            '?' => .question,
            ':' => .colon,
            '*' => if (at(src, i + 1) == '*') .star_star else .star,
            '=' => if (at(src, i + 1) == '=') .eq_eq else .equal,
            '!' => if (at(src, i + 1) == '=') .bang_eq else .bang,
            '<' => if (at(src, i + 1) == '>') null else if (at(src, i + 1) == '=') .lt_eq else .lt,
            '>' => if (at(src, i + 1) == '=') .gt_eq else .gt,
            '&' => if (at(src, i + 1) == '&') .amp_amp else null,
            '|' => if (at(src, i + 1) == '|') .pipe_pipe else null,
            else => if (isNameStart(c)) .word else null,
        };
        if (tag) |t| {
            try out.append(gpa, .{ .tag = t, .start = start });
            i = tokenEnd(src, t, start);
            if (t == .number) if (number.read(src[start..i]).code) |code| try diags.add(code, start, src[start..i]);
            continue;
        }
        switch (c) {
            ' ', '\t', '\r' => i += 1,
            // `<>`, `^`, `\` and `'`: the legacy spellings, named.
            '<', '^', '\\', '\'' => {
                const n: u32 = if (c == '<') 2 else 1;
                try diags.add(.legacy_operator, start, src[start .. start + n]);
                i += n;
            },
            else => {
                try diags.add(.unknown_char, start, src[start .. start + 1]);
                i += 1;
            },
        }
    }
    try out.append(gpa, .{ .tag = .eof, .start = @intCast(src.len) });
    return out;
}

/// The byte after the token of `tag` starting at `start`: the re-lex the
/// rows leave out.
pub fn tokenEnd(src: []const u8, tag: Tag, start: u32) u32 {
    var i: usize = start;
    switch (tag) {
        .word => {
            i += 1;
            while (i < src.len and isNameChar(src, i)) i += 1;
        },
        .directive => {
            i += 1;
            while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
        },
        .number => {
            while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            if (at(src, i) == '.' and at(src, i + 1) != null and std.ascii.isDigit(src[i + 1])) {
                i += 1;
                while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            }
            if (at(src, i) == 'e' or at(src, i) == 'E') {
                var j = i + 1;
                if (at(src, j) == '+' or at(src, j) == '-') j += 1;
                if (at(src, j) != null and std.ascii.isDigit(src[j])) {
                    i = j;
                    while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
                }
            }
            while (i < src.len and std.ascii.isAlphabetic(src[i])) i += 1;
            if (at(src, i) == '%') i += 1;
        },
        .string => i = std.mem.indexOfScalarPos(u8, src, i + 1, '"').? + 1,
        .star_star, .eq_eq, .bang_eq, .lt_eq, .gt_eq, .amp_amp, .pipe_pipe => i += 2,
        .eof => {},
        else => i += 1,
    }
    return @intCast(i);
}

/// Whether `c` can start a name.
pub fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Whether `src[i]` continues a name. A `!` before `=` does not: `a!=b`
/// is `a != b`.
pub fn isNameChar(src: []const u8, i: usize) bool {
    const c = src[i];
    if (c == '!') return at(src, i + 1) != '=';
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$' or c == '#';
}

// ---- private ----

fn at(src: []const u8, i: usize) ?u8 {
    return if (i < src.len) src[i] else null;
}
