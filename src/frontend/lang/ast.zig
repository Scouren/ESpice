//! The ESPice language's syntax tree, as rows. In: what parse.zig
//! appends. Out: `Ast`, node rows (`tag`, `main`, `lhs`, `rhs`), one
//! `extra` array for lists and wide payloads, the tokens and the source,
//! read by the checker and the lowering through the accessors below.
//! Cites: compiler-construction rule 1 (Zig's `std.zig.Ast`).
//!
//! Contents:
//! - `pub const Index`
//! - `pub const none`
//! - `pub const Tag`
//! - `pub const Node`
//! - `pub const Range`
//! - `pub const Statement`
//! - `pub const Ast`: `deinit`, `node`, `tag`, `tokenText`, `tokenTag`, `at`,
//!   `text`, `span`, `children`, `statement`, `name`, `callee`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");

/// A node's row number.
pub const Index = u32;

/// No node: an absent sweep clause or optional child.
pub const none: Index = std.math.maxInt(u32);

/// What a node is, and how to read its `main`, `lhs` and `rhs`.
pub const Tag = enum(u8) {
    /// `main` is the number token.
    number,
    /// `main` is the word token.
    word,
    /// `main` is the string token: a quoted name or a string value.
    string,
    /// `main` is the operator token, `lhs` the operand.
    unary,
    /// `main` is the operator token, `lhs` and `rhs` the operands.
    binary,
    /// `main` is `?`, `lhs` the condition, `extra[rhs..][0..2]` the two branches.
    ternary,
    /// `main` is the function's word, `extra[lhs..rhs]` the arguments
    /// (expressions, then `setting` nodes for keyed ones).
    call,
    /// `main` is `[`, `extra[lhs..rhs]` the elements.
    list,
    /// `main` is `(`, `extra[lhs..rhs]` the comma-separated elements (or none).
    tuple,
    /// `main` is `(`, `lhs` the one expression it groups.
    paren,
    /// `main` is `(`, `extra[lhs..rhs]` blank-separated items: a port list.
    group,
    /// `main` is `=`, `lhs` the key (a word, or a call such as `v(out)`),
    /// `rhs` the value, or `none` for a key with no value (never built).
    setting,
    /// A statement: `main` is its first token, `lhs` its `Statement` row in `extra`.
    instance,
    /// A statement: `main` is the directive token, `lhs` its `Statement` row.
    directive,
    /// A statement that is neither (a `.data` or `.variation` row):
    /// `main` its first token, `lhs` its `Statement` row.
    row,
};

/// One node row.
pub const Node = struct { tag: Tag, main: u32, lhs: u32, rhs: u32 };

/// Rows `extra[start..end]`.
pub const Range = struct { start: u32, end: u32 };

/// A statement's payload in `extra`, eight words: for an instance, the
/// port list node and the master node; the items (positional values and
/// `setting` nodes, in order, settings block included); the sweep clause
/// or `none`; the statement block's statements.
pub const Statement = struct {
    ports: Index,
    master: Index,
    items: Range,
    sweep: Index,
    block: Range,
    /// Whether a `{` block followed (a statement block or a settings block).
    has_block: bool,
};

/// A parsed file. Borrows `src`; owns its rows.
pub const Ast = struct {
    src: []const u8,
    tokens: lexer.Tokens.Slice,
    nodes: std.MultiArrayList(Node).Slice,
    extra: []const u32,
    /// The top-level statements.
    root: Range,

    /// Frees the rows.
    pub fn deinit(a: *Ast, gpa: Allocator) void {
        a.tokens.deinit(gpa);
        a.nodes.deinit(gpa);
        gpa.free(a.extra);
        a.* = undefined;
    }

    /// The node row `i`.
    pub fn node(a: *const Ast, i: Index) Node {
        return a.nodes.get(i);
    }

    /// The tag of node `i`.
    pub fn tag(a: *const Ast, i: Index) Tag {
        return a.nodes.items(.tag)[i];
    }

    /// The text of token `t`.
    pub fn tokenText(a: *const Ast, t: u32) []const u8 {
        const start = a.tokens.items(.start)[t];
        return a.src[start..lexer.tokenEnd(a.src, a.tokens.items(.tag)[t], start)];
    }

    /// The tag of token `t`.
    pub fn tokenTag(a: *const Ast, t: u32) lexer.Tag {
        return a.tokens.items(.tag)[t];
    }

    /// The byte offset node `i` is reported at: its main token's.
    pub fn at(a: *const Ast, i: Index) u32 {
        return a.tokens.items(.start)[a.nodes.items(.main)[i]];
    }

    /// The text of a leaf (`number`, `word`, `string` with its quotes).
    pub fn text(a: *const Ast, i: Index) []const u8 {
        return a.tokenText(a.nodes.items(.main)[i]);
    }

    /// The node indices `r` names.
    pub fn span(a: *const Ast, r: Range) []const u32 {
        return a.extra[r.start..r.end];
    }

    /// The children of a `call`, `list`, `tuple` or `group`.
    pub fn children(a: *const Ast, i: Index) []const u32 {
        const n = a.node(i);
        assert(n.tag == .call or n.tag == .list or n.tag == .tuple or n.tag == .group);
        return a.extra[n.lhs..n.rhs];
    }

    /// The payload of a statement node.
    pub fn statement(a: *const Ast, i: Index) Statement {
        const n = a.node(i);
        assert(n.tag == .instance or n.tag == .directive or n.tag == .row);
        const e = a.extra[n.lhs..][0..8];
        return .{
            .ports = e[0],
            .master = e[1],
            .items = .{ .start = e[2], .end = e[3] },
            .sweep = e[4],
            .block = .{ .start = e[5], .end = e[6] },
            .has_block = e[7] != 0,
        };
    }

    /// The name a word or string leaf spells, quotes stripped.
    pub fn name(a: *const Ast, i: Index) []const u8 {
        const t = a.text(i);
        return if (a.tag(i) == .string) t[1 .. t.len - 1] else t;
    }

    /// The function name of a `call`.
    pub fn callee(a: *const Ast, i: Index) []const u8 {
        assert(a.tag(i) == .call);
        return a.text(i);
    }
};

comptime {
    assert(@sizeOf(Tag) == 1);
}
