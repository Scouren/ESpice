//! Stage 2 of the ESPice language. In: a file's bytes. Out: `Ast` rows for
//! the whole grammar (instances, directives with subjects and settings,
//! settings and statement blocks, sweep clauses, rows, expressions) and a
//! coded row per syntax error; a statement that fails is skipped to its
//! line's end and the next one is read. Nesting is capped at `depth_max`
//! with a coded row, so recursion stays bounded on any input.
//! Cites: docs/using/language.md "Files and statements", "Expressions";
//! compiler-construction rules 1, 5, 6, 7.
//!
//! Contents:
//! - `pub const depth_max`
//! - `pub fn parse(gpa: Allocator, src: []const u8, diags: *Diags) Allocator.Error!Ast`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const Diags = diag.Diags;
const Code = diag.Code;
const Ast = ast.Ast;
const Index = ast.Index;
const Range = ast.Range;
const Tag = lexer.Tag;

/// Expression and block nesting past this many levels is refused with
/// `too_deep`: the parser recurses once per level.
pub const depth_max = 256;

const Err = error{ OutOfMemory, Syntax };

/// The directives whose `{` opens a block of statements; any other
/// statement's `{` opens a block of settings.
const block_owners = std.StaticStringMap(void).initComptime(.{
    .{".subckt"}, .{".lib"}, .{".if"}, .{".elseif"}, .{".else"}, .{".alter"}, .{".variation"}, .{".data"},
});

const P = struct {
    gpa: Allocator,
    src: []const u8,
    tags: []const Tag,
    starts: []const u32,
    diags: *Diags,
    pos: u32 = 0,
    /// Open `(`, `[` and settings `{`: newlines inside them are blanks.
    nest: u32 = 0,
    /// Recursion depth, capped at `depth_max`.
    depth: u32 = 0,
    nodes: std.MultiArrayList(ast.Node) = .empty,
    extra: std.ArrayList(u32) = .empty,
    /// Lists being collected; each user restores its length on exit.
    scratch: std.ArrayList(u32) = .empty,

    fn header(p: *P) Allocator.Error!void {
        const ok = p.tags[0] == .directive and std.mem.eql(u8, p.tokText(0), ".espice") and
            p.tags[1] == .number and std.mem.eql(u8, p.tokText(1), "1") and
            (p.tags[2] == .newline or p.tags[2] == .eof);
        if (ok) {
            p.pos = 2;
            return;
        }
        try p.diags.add(.bad_header, 0, p.src[0 .. std.mem.indexOfScalar(u8, p.src, '\n') orelse p.src.len]);
        while (p.tags[p.pos] != .newline and p.tags[p.pos] != .eof) p.pos += 1;
    }

    /// Statements up to `}` (when `open`, the block's `{`, is set) or the
    /// end of the file, as an `extra` range.
    fn statements(p: *P, open: ?u32) Err!Range {
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        const nest = p.nest;
        p.nest = 0;
        defer p.nest = nest;
        while (true) {
            while (p.tags[p.pos] == .newline) p.pos += 1;
            switch (p.tags[p.pos]) {
                .eof => {
                    if (open) |o| try p.diags.add(.unclosed, p.starts[o], "{");
                    break;
                },
                .r_brace => {
                    p.pos += 1;
                    if (open != null) {
                        if (!p.atLineEnd()) try p.diags.add(.block_line, p.starts[p.pos], p.tokText(p.pos));
                        break;
                    }
                    try p.diags.add(.stray_close, p.starts[p.pos - 1], "}");
                },
                else => {
                    const s = p.statement() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Syntax => {
                            p.nest = 0;
                            while (p.tags[p.pos] != .newline and p.tags[p.pos] != .eof) p.pos += 1;
                            continue;
                        },
                    };
                    try p.scratch.append(p.gpa, s);
                },
            }
        }
        return p.commit(top);
    }

    fn statement(p: *P) Err!Index {
        try p.enter();
        defer p.depth -= 1;
        const first = p.pos;
        var s: [8]u32 = .{ ast.none, ast.none, 0, 0, ast.none, 0, 0, 0 };
        const tag: ast.Tag = switch (p.tags[first]) {
            .directive => .directive,
            .word, .string => if (p.tags[first + 1] == .l_paren) .instance else .row,
            .number, .minus => .row,
            else => return p.fail(.unexpected, first),
        };
        if (tag == .directive) p.pos += 1;
        if (tag == .instance) {
            p.pos += 1;
            s[0] = try p.group();
            const m = p.peek();
            if (m != .word and m != .string) return p.fail(.unexpected, p.pos);
            s[1] = try p.leaf(if (m == .word) .word else .string);
        }
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.items(tag == .row, &s[4]);
        if (p.tags[p.pos] == .l_brace) {
            const brace = p.pos;
            p.pos += 1;
            s[7] = 1;
            const owner = tag == .row or (tag == .directive and block_owners.has(p.tokText(first)));
            if (owner) {
                if (!p.atLineEnd()) return p.fail(.block_line, p.pos);
                const block = try p.statements(brace);
                s[5] = block.start;
                s[6] = block.end;
            } else {
                p.nest += 1;
                try p.items(false, &s[4]);
                if (p.peek() != .r_brace) return p.fail(.unclosed, brace);
                p.nest -= 1;
                p.pos += 1;
            }
        }
        if (!p.atLineEnd()) return p.fail(if (p.tags[p.pos] == .r_brace) .block_line else .unexpected, p.pos);
        const r = try p.commit(top);
        s[2] = r.start;
        s[3] = r.end;
        const payload: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.gpa, &s);
        return p.add(tag, first, payload, 0);
    }

    /// Items up to the line's end, `{` or `}`, onto the scratch list. A
    /// bare `sweep` takes the item after it, an expression or a setting
    /// (`sweep rval=lin(...)`), as the clause.
    fn items(p: *P, row: bool, sweep: *u32) Err!void {
        while (true) {
            const t = p.peek();
            switch (t) {
                .newline, .eof, .l_brace, .r_brace => return,
                .comma => if (row) {
                    p.pos += 1;
                    continue;
                },
                .word => if (std.mem.eql(u8, p.tokText(p.pos), "sweep") and p.tags[p.pos + 1] != .equal) {
                    p.pos += 1;
                    if (sweep.* != ast.none) return p.fail(.unexpected, p.pos - 1);
                    sweep.* = try p.item();
                    continue;
                },
                else => {},
            }
            try p.scratch.append(p.gpa, try p.item());
        }
    }

    /// An expression, or `key = value` when `=` follows it.
    fn item(p: *P) Err!Index {
        const key = try p.expr();
        if (p.peek() != .equal) return key;
        const eq = p.pos;
        p.pos += 1;
        return p.add(.setting, eq, key, try p.expr());
    }

    fn expr(p: *P) Err!Index {
        try p.enter();
        defer p.depth -= 1;
        const cond = try p.binary(1);
        if (p.peek() != .question) return cond;
        const q = p.pos;
        p.pos += 1;
        const yes = try p.expr();
        if (p.peek() != .colon) return p.fail(.unexpected, p.pos);
        p.pos += 1;
        const no = try p.expr();
        const e: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.gpa, &.{ yes, no });
        return p.add(.ternary, q, cond, e);
    }

    fn binary(p: *P, min: u8) Err!Index {
        var lhs = try p.unary();
        while (true) {
            const op = p.peek();
            const prec = precedence(op) orelse return lhs;
            if (prec < min) return lhs;
            const at = p.pos;
            p.pos += 1;
            const rhs = try p.binary(prec + 1);
            lhs = try p.add(.binary, at, lhs, rhs);
        }
    }

    /// A prefix operator's operand, then `**`, which binds tighter than a
    /// prefix on its left and takes one on its right (`-2**-1` is -(2**(-1))).
    fn unary(p: *P) Err!Index {
        try p.enter();
        defer p.depth -= 1;
        const t = p.peek();
        if (t == .minus or t == .plus or t == .bang) {
            const at = p.pos;
            p.pos += 1;
            return p.add(.unary, at, try p.unary(), 0);
        }
        const base = try p.primary();
        if (p.peek() != .star_star) return base;
        const at = p.pos;
        p.pos += 1;
        return p.add(.binary, at, base, try p.unary());
    }

    fn primary(p: *P) Err!Index {
        return switch (p.peek()) {
            .number => p.leaf(.number),
            .string => p.leaf(.string),
            .word => if (p.tags[p.pos + 1] == .l_paren and p.starts[p.pos + 1] == lexer.tokenEnd(p.src, .word, p.starts[p.pos])) p.call() else p.leaf(.word),
            .l_paren => p.group(),
            .l_bracket => p.list(),
            else => p.fail(.unexpected, p.pos),
        };
    }

    /// `( items )`: none or comma-separated is a `tuple`, one expression a
    /// `paren`, blank-separated items (or one setting) a `group`.
    fn group(p: *P) Err!Index {
        const open = p.pos;
        assert(p.tags[open] == .l_paren);
        p.pos += 1;
        p.nest += 1;
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        var comma = false;
        while (true) switch (p.peek()) {
            .r_paren => break,
            .eof => return p.fail(.unclosed, open),
            .comma => {
                comma = true;
                p.pos += 1;
            },
            else => try p.scratch.append(p.gpa, try p.item()),
        };
        p.nest -= 1;
        p.pos += 1;
        const got = p.scratch.items[top..];
        if (got.len == 1 and !comma and p.nodes.items(.tag)[got[0]] != .setting) return p.add(.paren, open, got[0], 0);
        const r = try p.commit(top);
        return p.add(if (comma or got.len == 0) .tuple else .group, open, r.start, r.end);
    }

    fn list(p: *P) Err!Index {
        const open = p.pos;
        p.pos += 1;
        p.nest += 1;
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        while (true) switch (p.peek()) {
            .r_bracket => break,
            .eof => return p.fail(.unclosed, open),
            .comma => p.pos += 1,
            else => try p.scratch.append(p.gpa, try p.expr()),
        };
        p.nest -= 1;
        p.pos += 1;
        const r = try p.commit(top);
        return p.add(.list, open, r.start, r.end);
    }

    /// `name(args)`: positional arguments, then keyed ones.
    fn call(p: *P) Err!Index {
        const name = p.pos;
        p.pos += 2;
        p.nest += 1;
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        var keyed = false;
        while (true) switch (p.peek()) {
            .r_paren => break,
            .eof => return p.fail(.unclosed, name + 1),
            .comma => p.pos += 1,
            else => {
                const at = p.pos;
                const arg = try p.item();
                const is_key = p.nodes.items(.tag)[arg] == .setting;
                if (keyed and !is_key) try p.diags.add(.positional_after_key, p.starts[at], p.tokText(at));
                keyed = keyed or is_key;
                try p.scratch.append(p.gpa, arg);
            },
        };
        p.nest -= 1;
        p.pos += 1;
        const r = try p.commit(top);
        return p.add(.call, name, r.start, r.end);
    }

    fn leaf(p: *P, tag: ast.Tag) Err!Index {
        p.pos += 1;
        return p.add(tag, p.pos - 1, 0, 0);
    }

    fn add(p: *P, tag: ast.Tag, main: u32, lhs: u32, rhs: u32) Allocator.Error!Index {
        try p.nodes.append(p.gpa, .{ .tag = tag, .main = main, .lhs = lhs, .rhs = rhs });
        return @intCast(p.nodes.len - 1);
    }

    /// Moves `scratch[top..]` to `extra` and returns its range.
    fn commit(p: *P, top: usize) Allocator.Error!Range {
        const start: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.gpa, p.scratch.items[top..]);
        return .{ .start = start, .end = @intCast(p.extra.items.len) };
    }

    /// The current token, newlines skipped inside brackets.
    fn peek(p: *P) Tag {
        if (p.nest > 0) while (p.tags[p.pos] == .newline) {
            p.pos += 1;
        };
        return p.tags[p.pos];
    }

    fn atLineEnd(p: *const P) bool {
        return p.tags[p.pos] == .newline or p.tags[p.pos] == .eof;
    }

    fn enter(p: *P) Err!void {
        if (p.depth == depth_max) return p.fail(.too_deep, p.pos);
        p.depth += 1;
    }

    fn fail(p: *P, code: Code, tok: u32) Err {
        try p.diags.add(code, p.starts[tok], if (p.tags[tok] == .newline) "end of line" else if (p.tags[tok] == .eof) "end of file" else p.tokText(tok));
        return error.Syntax;
    }

    fn tokText(p: *const P, t: u32) []const u8 {
        return p.src[p.starts[t]..lexer.tokenEnd(p.src, p.tags[t], p.starts[t])];
    }
};

/// Lexes and parses `src`, which starts with the `.espice 1` header line.
/// Every problem becomes a row in `diags`; the tree holds every statement
/// that parsed. The caller owns the result (`Ast.deinit`). Fails only with
/// `OutOfMemory`.
pub fn parse(gpa: Allocator, src: []const u8, diags: *Diags) Allocator.Error!Ast {
    var tokens = try lexer.lex(gpa, src, diags);
    errdefer tokens.deinit(gpa);
    var p: P = .{ .gpa = gpa, .src = src, .tags = tokens.items(.tag), .starts = tokens.items(.start), .diags = diags };
    defer p.scratch.deinit(gpa);
    errdefer p.nodes.deinit(gpa);
    errdefer p.extra.deinit(gpa);
    try p.header();
    const root = p.statements(null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => unreachable, // statements recovers per statement
    };
    assert(p.tags[p.pos] == .eof);
    return .{
        .src = src,
        .tokens = tokens.slice(),
        .nodes = p.nodes.toOwnedSlice(),
        .extra = try p.extra.toOwnedSlice(gpa),
        .root = root,
    };
}

// ---- private ----

fn precedence(t: Tag) ?u8 {
    return switch (t) {
        .pipe_pipe => 1,
        .amp_amp => 2,
        .eq_eq, .bang_eq => 3,
        .lt, .lt_eq, .gt, .gt_eq => 4,
        .plus, .minus => 5,
        .star, .slash, .percent => 6,
        else => null,
    };
}
