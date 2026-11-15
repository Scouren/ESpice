//! Stage 4 of the ESPice language: checked statements as legacy text. In:
//! an `Ast`. Out: the legacy cards the existing reader reads, one logical
//! line per statement, blocks as their open and close cards, the top
//! file's title first; and a coded row for every statement the table does
//! not know, refuses, or cannot lower faithfully.
//! Cites: docs/using/language.md (each statement's Legacy entry);
//! contract items 1, 5, 6.
//!
//! Contents:
//! - `pub const Role`
//! - `pub const Lowerer`: `put`, `print`, `endCard`, `putName`, `putProbe`,
//!   `putHead`, `unitOfParam`, `setParamUnit`, `block`
//! - `pub fn run(l: *Lowerer) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const number = @import("number.zig");
const schema = @import("schema.zig");
const check = @import("check.zig");
const instance = @import("instance.zig");
const Ast = ast.Ast;
const Index = ast.Index;
const Directive = schema.Directive;

/// Whether the file is the deck (its first lowered line is the title) or
/// a file an `.include` or `.lib` reads (no title line).
pub const Role = enum(u1) { top, include };

/// The lowering's state: the tree it reads, the text it writes, the rows
/// it reports, and the parameters whose literal carried a unit.
pub const Lowerer = struct {
    a: *const Ast,
    /// Scratch for the whole lowering: bound slots, lowercased names.
    arena: Allocator,
    diags: *diag.Diags,
    role: Role,
    out: std.ArrayList(u8) = .empty,
    /// Lowercased `.param` names to the unit of their literal.
    units: std.StringHashMapUnmanaged(number.Unit) = .empty,
    /// The directive before and after the statement being lowered, among
    /// its siblings: `.if` chains and `.alter` runs read them.
    prev: ?Directive = null,
    next: ?Directive = null,
    /// Statement-block nesting of the statement being lowered.
    depth: u32 = 0,
    /// A `.title` was lowered.
    titled: bool = false,

    /// Appends `s` to the output.
    pub fn put(l: *Lowerer, s: []const u8) Allocator.Error!void {
        try l.out.appendSlice(l.arena, s);
    }

    /// Appends formatted text to the output.
    pub fn print(l: *Lowerer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try l.out.print(l.arena, fmt, args);
    }

    /// Ends the current card.
    pub fn endCard(l: *Lowerer) Allocator.Error!void {
        try l.out.append(l.arena, '\n');
    }

    /// Appends a name (a word, a quoted name's body, or a node number) as written.
    pub fn putName(l: *Lowerer, node: Index) Allocator.Error!void {
        try l.put(l.a.name(node));
    }

    /// Appends a probe, `v(a,b)` or `i(name)`, its arguments as names.
    pub fn putProbe(l: *Lowerer, node: Index) Allocator.Error!void {
        const a = l.a;
        if (a.tag(node) != .call) return l.diags.add(.wrong_kind, a.at(node), a.text(node));
        try l.put(a.callee(node));
        try l.put("(");
        for (a.children(node), 0..) |c, i| {
            if (i > 0) try l.put(",");
            switch (a.tag(c)) {
                .word, .string, .number => try l.putName(c),
                else => try l.diags.add(.wrong_kind, a.at(c), a.text(c)),
            }
        }
        try l.put(")");
    }

    /// Appends a device head: `name` alone when its first letter is
    /// already `letter`, as a legacy card names it, else `letter@name`.
    pub fn putHead(l: *Lowerer, letter: u8, name: []const u8) Allocator.Error!void {
        assert(std.ascii.isLower(letter));
        if (name.len > 0 and std.ascii.toLower(name[0]) == letter) return l.put(name);
        try l.print("{c}@{s}", .{ letter, name });
    }

    /// The unit a same-file `.param` gave `name`, if its value was a literal with one.
    pub fn unitOfParam(l: *const Lowerer, name: []const u8) ?number.Unit {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) return null;
        return l.units.get(std.ascii.lowerString(&buf, name));
    }

    /// Records that `name` was defined from a literal with `unit`.
    pub fn setParamUnit(l: *Lowerer, name: []const u8, unit: ?number.Unit) Allocator.Error!void {
        const key = try std.ascii.allocLowerString(l.arena, name);
        if (unit) |u| try l.units.put(l.arena, key, u) else _ = l.units.remove(key);
    }

    /// Lowers the statements of `r`, a file's root or a block.
    pub fn block(l: *Lowerer, r: ast.Range) Allocator.Error!void {
        const stmts = l.a.span(r);
        l.depth += 1;
        defer l.depth -= 1;
        var prev: ?Directive = null;
        // ponytail: per block; a name repeated across an .if branch and
        // its enclosing block is left to the reader.
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (stmts, 0..) |s, i| {
            if (l.a.tag(s) == .instance) {
                const name = l.a.tokenText(l.a.node(s).main);
                const key = try std.ascii.allocLowerString(l.arena, if (name.len >= 2 and name[0] == '"') name[1 .. name.len - 1] else name);
                if ((try names.getOrPut(l.arena, key)).found_existing) try l.diags.add(.duplicate_instance, l.a.at(s), name);
            }
            const next = if (i + 1 < stmts.len) directiveOf(l.a, stmts[i + 1]) else null;
            l.prev = prev;
            l.next = next;
            try statement(l, s);
            prev = directiveOf(l.a, s);
        }
    }
};

/// Legacy directives with no statement in the language ("Not in the language").
const retired = std.StaticStringMap(void).initComptime(.{
    .{"end"},          .{"print"},    .{"plot"},      .{"graph"},   .{"width"},   .{"protect"},
    .{"unprotect"},    .{"csparam"},  .{"control"},   .{"endc"},    .{"store"},   .{"temp"},
    .{"macro"},        .{"eom"},      .{"parameter"}, .{"options"}, .{"measure"}, .{"inc"},
    .{"osdi_include"}, .{"pre_osdi"}, .{"ends"},      .{"endl"},    .{"endif"},   .{"enddata"},
    .{"espice"},
});

/// Lowers the whole file into `l.out`.
pub fn run(l: *Lowerer) Allocator.Error!void {
    const a = l.a;
    if (l.role == .top) {
        for (a.span(a.root)) |s| if (directiveOf(a, s) == .title) {
            const items = a.span(a.statement(s).items);
            if (items.len == 1 and a.tag(items[0]) == .string) try l.put(a.name(items[0]));
            break;
        };
        try l.endCard();
    }
    try l.block(a.root);
}

// ---- private ----

fn directiveOf(a: *const Ast, s: Index) ?Directive {
    if (a.tag(s) != .directive) return null;
    return schema.directive(a.text(s)[1..]);
}

fn statement(l: *Lowerer, s: Index) Allocator.Error!void {
    const a = l.a;
    switch (a.tag(s)) {
        .instance => return instance.lower(l, s),
        .row => return l.diags.add(.misplaced, a.at(s), a.text(s)),
        .directive => {},
        else => unreachable,
    }
    const word = a.text(s)[1..];
    const d = schema.directive(word) orelse {
        const code: diag.Code = if (retired.has(word)) .retired else .unknown_directive;
        return l.diags.add(code, a.at(s), a.text(s));
    };
    const row = schema.rows.get(d);
    const st = a.statement(s);
    // The parser opens a statement block for exactly the owners.
    if (row.block and !st.has_block) try l.diags.add(.misplaced, a.at(s), "a block statement without its { }");
    const b = try check.bind(l, s, row);
    if (st.sweep != ast.none and !row.sweeps) return l.diags.add(.sweep_not_lowered, a.at(st.sweep), a.text(st.sweep));
    try row.lower.?(l, b);
}
