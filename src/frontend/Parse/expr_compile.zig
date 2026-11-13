//! Expression text to postfix. In: expression text in ngspice's syntax.
//! Out: `Op` rows, constants and
//! names appended to a `Scratch`; names and probe arguments stay indices
//! into `Scratch.names` until reader_subst.zig `subst` splices parameters in.
//! A recursive-descent parser bounded by `max_depth`.
//! Cites: dev/research/ngspice-syntax.md §2.2, §2.6; ngspice xpressn.c.
//!
//! Contents:
//! - `pub const max_depth = 512`
//! - `pub fn compile(gpa: Allocator, s: *Scratch, text: []const u8, pos: usize) Error!usize`
//! - `pub fn compileAll(gpa: Allocator, s: *Scratch, text: []const u8) Error!void`
//! - `pub fn numberLen(text: []const u8) usize`
//! - `pub fn isOperator(c: u8) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const expr_ops = @import("expr_ops.zig");
const spice_number = @import("spice_number.zig");
const Error = expr_ops.Error;
const Scratch = expr_ops.Scratch;
const Op = expr_ops.Op;
const Code = expr_ops.Code;
const Fn = expr_ops.Fn;
const none = expr_ops.none;

/// Recursion bound of `compile`, in parser calls: a level of parentheses,
/// quotes or call arguments costs two, a ternary branch one, a unary
/// operator one or two. Deeper input is a ParseError rather than a stack overflow.
pub const max_depth = 512;

const Compiler = struct {
    text: []const u8,
    pos: usize = 0,
    gpa: Allocator,
    s: *Scratch,
    depth: u16 = 0,

    const P = @This();

    fn peek(p: *P) ?u8 {
        while (p.pos < p.text.len and (p.text[p.pos] == ' ' or p.text[p.pos] == '\t')) p.pos += 1;
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn emit(p: *P, op: Op) Error!void {
        try p.s.ops.append(p.gpa, op);
    }

    fn name(p: *P, n: []const u8) Error!u32 {
        try p.s.names.append(p.gpa, n);
        return @intCast(p.s.names.items.len - 1);
    }

    fn bin(p: *P, min_prec: u8) Error!void {
        if (p.depth == max_depth) return error.ParseError;
        p.depth += 1;
        defer p.depth -= 1;
        try p.unary();
        while (true) {
            const c = p.peek() orelse break;
            if (c == '?' and min_prec == 0) {
                p.pos += 1;
                try p.bin(0);
                if (p.peek() != ':') return error.ParseError;
                p.pos += 1;
                try p.bin(0);
                try p.emit(.{ .code = .call, .a = @backingInt(Fn.ternary), .b = 3 });
                continue;
            }
            const power = c == '*' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '*';
            const prec: u8 = switch (c) {
                '|' => 1,
                '&' => 2,
                '<', '>', '=', '!' => 3,
                '+', '-' => 4,
                '*', '/', '%', '\\' => if (power) 6 else 5,
                '^' => 6,
                else => break,
            };
            if (prec < min_prec) break;
            p.pos += 1;
            var code: Code = switch (c) {
                '|' => .@"or",
                '&' => .@"and",
                '<' => .lt,
                '>' => .gt,
                '=' => .eq,
                '!' => .ne,
                '+' => .add,
                '-' => .sub,
                '*' => if (power) .pow else .mul,
                '/' => .div,
                '%' => .mod,
                '\\' => .idiv,
                else => .pow,
            };
            if (p.pos < p.text.len) {
                const next = p.text[p.pos];
                if (power) p.pos += 1;
                if (next == '=' and (c == '<' or c == '>' or c == '=' or c == '!')) {
                    if (c == '<') code = .le;
                    if (c == '>') code = .ge;
                    p.pos += 1;
                } else if (c == '<' and next == '>') {
                    // `<>` is `!=` in numparam and B sources (§2.2, §2.6).
                    code = .ne;
                    p.pos += 1;
                } else if (c == '=' or c == '!') return error.ParseError;
                if (c == '&' or c == '|') {
                    if (next != c) return error.ParseError;
                    p.pos += 1;
                }
            }
            try p.bin(prec + 1);
            try p.emit(.{ .code = code });
        }
    }

    // Every recursion passes through `bin` or `unary`, so the guard in
    // both bounds them all.
    fn unary(p: *P) Error!void {
        if (p.depth == max_depth) return error.ParseError;
        p.depth += 1;
        defer p.depth -= 1;
        const c = p.peek() orelse return error.ParseError;
        switch (c) {
            '-' => {
                p.pos += 1;
                try p.bin(6);
                try p.emit(.{ .code = .neg });
            },
            '+' => {
                p.pos += 1;
                try p.bin(6);
            },
            '!' => {
                p.pos += 1;
                try p.unary();
                try p.emit(.{ .code = .not });
            },
            else => try p.atom(),
        }
    }

    /// A probe argument: up to `,` `)` or a blank, kept as a name (node
    /// `10` is a node, and a node `1n` must not read as 1e-9).
    fn nodeArg(p: *P) Error![]const u8 {
        _ = p.peek();
        const start = p.pos;
        while (p.pos < p.text.len) : (p.pos += 1) {
            const ch = p.text[p.pos];
            if (ch == ',' or ch == ')' or ch == ' ' or ch == '\t') break;
        }
        if (p.pos == start) return error.ParseError;
        return p.text[start..p.pos];
    }

    fn atom(p: *P) Error!void {
        const c = p.peek() orelse return error.ParseError;
        if (c == '"' or c == '\'' or c == '(') {
            p.pos += 1;
            try p.bin(0);
            const close: u8 = if (c == '(') ')' else c;
            if (p.peek() != close) return error.ParseError;
            p.pos += 1;
            return;
        }
        if (std.ascii.isDigit(c) or c == '.') {
            const start = p.pos;
            p.pos += numberLen(p.text[start..]);
            const n = spice_number.spiceNumber(p.text[start..p.pos]) orelse return error.ParseError;
            try p.s.consts.append(p.gpa, n);
            return p.emit(.{ .code = .num, .a = @intCast(p.s.consts.items.len - 1) });
        }
        if (!std.ascii.isAlphabetic(c) and c != '_') return error.ParseError;
        const start = p.pos;
        while (p.pos < p.text.len) : (p.pos += 1) {
            const ch = p.text[p.pos];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) break;
        }
        const word = p.text[start..p.pos];
        if (p.peek() != '(') return p.emit(.{ .code = .ident, .a = try p.name(word) });
        p.pos += 1;
        const probe: ?Code = if (word.len != 1) null else switch (word[0]) {
            'v', 'V' => .vprobe,
            'i', 'I' => .iprobe,
            else => null,
        };
        var args: [2]u32 = .{ none, none };
        var argc: u32 = 0;
        if (p.peek() != ')') while (true) {
            if (probe != null) {
                const node = try p.nodeArg();
                if (argc < 2) args[argc] = try p.name(node);
            } else try p.bin(0);
            argc += 1;
            if ((p.peek() orelse return error.ParseError) != ',') break;
            p.pos += 1;
        };
        if (p.peek() != ')') return error.ParseError;
        p.pos += 1;
        if (probe) |code| return p.emit(.{ .code = code, .a = args[0], .b = args[1] });
        // numparam's `limit` takes two arguments; any other count goes
        // to reader_subst.zig `inline_`, which refuses PSPICE's clamp.
        if (expr_ops.fns.get(word)) |f| if (f != .limit or argc == 2) return p.emit(.{ .code = .call, .a = @backingInt(f), .b = argc });
        try p.emit(.{ .code = .ucall, .a = try p.name(word), .b = argc });
    }
};

/// Compiles the expression starting at `text[pos]` into `s` and returns
/// where it ends. Grammar: ternary `?:` loosest, then `||`, `&&`,
/// comparisons, `+ -`, `* /`, `^`/`**` (all left associative); unary `-`/`+`
/// bind below power; `%` and `\` are numparam's remainder and integer
/// division. A single `|` or `&`, and a unary `~`, are PSPICE's, which
/// plain ngspice-44.2 refuses ("Syntax error"): a ParseError, as is a `{`
/// inside the text, which ngspice reads three ways (a syntax error in a
/// `.param`, stripped as text in a B, E or G expression and a `.func`
/// body, a group in a value only while the deck has a `.param`;
/// src/tests/expressions.zig), and nesting deeper than `max_depth`.
/// Invalidates slices of `s`'s tables, which grow in `gpa`.
pub fn compile(gpa: Allocator, s: *Scratch, text: []const u8, pos: usize) Error!usize {
    var p: Compiler = .{ .text = text, .pos = pos, .gpa = gpa, .s = s };
    try p.bin(0);
    assert(p.pos >= pos);
    assert(p.depth == 0);
    return p.pos;
}

/// `compile` over the whole of `text`; trailing input is a ParseError.
/// Invalidates slices of `s`'s tables, which grow in `gpa`.
pub fn compileAll(gpa: Allocator, s: *Scratch, text: []const u8) Error!void {
    var p: Compiler = .{ .text = text, .gpa = gpa, .s = s };
    try p.bin(0);
    assert(p.depth == 0);
    if (p.peek() != null) return error.ParseError;
}

/// Length of the number literal `text` starts with: digits and dots, an
/// exponent, then a letter suffix (`2.5e-3`, `10meg`). `E` is an exponent
/// too, as `lines.zig` reads it.
pub fn numberLen(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (std.ascii.isDigit(ch) or ch == '.') continue;
        if ((ch == 'e' or ch == 'E') and i + 1 < text.len and
            (std.ascii.isDigit(text[i + 1]) or
                ((text[i + 1] == '-' or text[i + 1] == '+') and i + 2 < text.len and std.ascii.isDigit(text[i + 2]))))
        {
            i += 1;
            if (text[i] == '+' or text[i] == '-') i += 1;
            continue;
        }
        break;
    }
    while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
    return i;
}

/// A byte that continues an expression after an operand: the binary and
/// ternary operator bytes, numparam's `%` and `\` included.
pub fn isOperator(c: u8) bool {
    return switch (c) {
        '|', '&', '<', '>', '=', '!', '+', '-', '*', '/', '%', '\\', '^', '?' => true,
        else => false,
    };
}

// ---- private ----
