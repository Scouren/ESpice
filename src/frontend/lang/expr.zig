//! Expressions of the ESPice language as legacy text. In: an expression
//! node and the context it stands in. Out: the legacy expression whose
//! value is the language's: `**` and `pow` the real power, `pwr`
//! sign(x)·|x|^y, `idiv`, `int`, `sqr` and `%` written so each legacy
//! context (numparam in a `.param` or value, the B parser in a
//! behavioural source, either in a `.func` body) gives that value; and a
//! value quoted as its card needs it.
//! Cites: docs/using/language.md "Expressions" and its Legacy note;
//! docs/using/reference.md "Expressions"; src/frontend/Parse/expr.zig
//! (numparam's pow is C's, pwr |x|^y, `\` trunc(|a/b|), `%` a-b·trunc(a/b);
//! the B parser's pow |x|^y, pwr sign·|x|^y, and no int or sqr; `**` is
//! |x|^y in both).
//!
//! Contents:
//! - `pub const Ctx`
//! - `pub fn write(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void`
//! - `pub fn writeValue(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void`
//! - `pub fn readsCircuit(a: *const Ast, node: Index) bool`
//! - `pub fn isLiteral(a: *const Ast, node: Index) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const number = @import("number.zig");
const lexer = @import("lexer.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Ast = ast.Ast;
const Index = ast.Index;

/// Which legacy parser reads the expression.
pub const Ctx = enum(u2) {
    /// numparam: a `.param`, an instance or model value, a directive's argument.
    param,
    /// The B parser: a `bsource`, a behavioural passive.
    behavioural,
    /// A `.func` body, which either parser may expand.
    func,
};

/// The words only a behavioural source reads.
const circuit_words = std.StaticStringMap(void).initComptime(.{ .{"time"}, .{"temper"}, .{"hertz"} });

/// The functions only a behavioural source reads.
const circuit_calls = std.StaticStringMap(void).initComptime(.{
    .{"v"},   .{"i"},   .{"u"},   .{"uramp"}, .{"u2"},  .{"eq0"}, .{"ne0"},
    .{"gt0"}, .{"lt0"}, .{"ge0"}, .{"le0"},   .{"pwl"}, .{"ddt"},
});

/// Writes `node` as a legacy expression read in `ctx`, unquoted. A name
/// that reads the circuit in a `param` context is a coded row.
pub fn write(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void {
    const a = l.a;
    const n = a.node(node);
    switch (n.tag) {
        .number => try writeNumber(l, a.text(node)),
        .word => {
            const w = a.text(node);
            if (ctx == .param and circuit_words.has(w)) try l.diags.add(.reads_circuit, a.at(node), w);
            try l.put(w);
        },
        .unary => {
            try l.put(a.tokenText(n.main));
            try grouped(l, n.lhs, ctx);
        },
        .binary => if (a.tokenTag(n.main) == .star_star) try power(l, n.lhs, n.rhs, ctx) else try binary(l, node, ctx),
        .ternary => {
            // The legacy `?:` binds loosest and nests to the right, as here.
            const branches = a.extra[n.rhs..][0..2];
            try side(l, n.lhs, 0, false, ctx);
            try l.put("?");
            try side(l, branches[0], 0, false, ctx);
            try l.put(":");
            try write(l, branches[1], ctx);
        },
        .paren => {
            try l.put("(");
            try write(l, n.lhs, ctx);
            try l.put(")");
        },
        .call => try call(l, node, ctx),
        .string, .list, .tuple, .group, .setting, .instance, .directive, .row => {
            try l.diags.add(.wrong_kind, a.at(node), a.text(node));
            try l.put("0");
        },
    }
}

/// Writes `node` as a card value: a literal or a name bare, anything else
/// quoted as its context's card needs, `'...'` for numparam and `{...}`
/// for the B parser and a `.func` body.
pub fn writeValue(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void {
    if (isLiteral(l.a, node) or l.a.tag(node) == .word) return write(l, node, ctx);
    try l.put(if (ctx == .param) "'" else "{");
    try write(l, node, ctx);
    try l.put(if (ctx == .param) "'" else "}");
}

/// Whether the expression reads the circuit: `v()`, `i()`, `time`,
/// `temper`, `hertz` or a behavioural-only function. Recursion is bounded
/// by the parser's depth cap.
pub fn readsCircuit(a: *const Ast, node: Index) bool {
    const n = a.node(node);
    return switch (n.tag) {
        .word => circuit_words.has(a.text(node)),
        .call => circuit_calls.has(a.callee(node)) or for (a.children(node)) |c| {
            if (readsCircuit(a, if (a.tag(c) == .setting) a.node(c).rhs else c)) break true;
        } else false,
        .unary, .paren => readsCircuit(a, n.lhs),
        .binary => readsCircuit(a, n.lhs) or readsCircuit(a, n.rhs),
        .ternary => readsCircuit(a, n.lhs) or readsCircuit(a, a.extra[n.rhs]) or readsCircuit(a, a.extra[n.rhs + 1]),
        .list, .tuple, .group => for (a.children(node)) |c| {
            if (readsCircuit(a, c)) break true;
        } else false,
        .number, .string, .setting, .instance, .directive, .row => false,
    };
}

/// Whether `node` is a number, or a sign and a number.
pub fn isLiteral(a: *const Ast, node: Index) bool {
    return switch (a.tag(node)) {
        .number => true,
        .unary => a.tokenTag(a.node(node).main) != .bang and a.tag(a.node(node).lhs) == .number,
        else => false,
    };
}

// ---- private ----

/// The legacy reader's binding level of each binary operator
/// (expr_compile.zig `bin`): every comparison shares one.
fn level(t: lexer.Tag) u8 {
    return switch (t) {
        .pipe_pipe => 1,
        .amp_amp => 2,
        .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => 3,
        .plus, .minus => 4,
        .star, .slash, .percent => 5,
        else => unreachable,
    };
}

fn writeNumber(l: *Lowerer, text: []const u8) Allocator.Error!void {
    // A number that does not read was reported by the lexer.
    const n = number.read(text).number orelse return l.put("0");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    number.writeLegacy(n, &w) catch return l.put(n.mantissa);
    try l.put(w.buffered());
}

fn binary(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void {
    const a = l.a;
    const n = a.node(node);
    const op = a.tokenTag(n.main);
    if (op == .percent and ctx != .param) {
        // a - b·trunc(a/b), trunc(x) = sgn(x)·floor(|x|): the B parser
        // refuses `%` on a probe.
        try l.put("(");
        try grouped(l, n.lhs, ctx);
        try l.put("-");
        try grouped(l, n.rhs, ctx);
        try l.put("*sgn(");
        try quotient(l, n.lhs, n.rhs, ctx);
        try l.put(")*floor(abs(");
        try quotient(l, n.lhs, n.rhs, ctx);
        return l.put(")))");
    }
    const lv = level(op);
    try side(l, n.lhs, lv, false, ctx);
    try l.put(a.tokenText(n.main));
    try side(l, n.rhs, lv, true, ctx);
}

/// An operand of a binary operator at level `lv`, in parentheses when
/// the legacy reader would otherwise bind it differently.
fn side(l: *Lowerer, node: Index, lv: u8, right: bool, ctx: Ctx) Allocator.Error!void {
    const a = l.a;
    const wrap = switch (a.tag(node)) {
        .ternary => true,
        .binary => blk: {
            const op = a.tokenTag(a.node(node).main);
            if (op == .star_star) break :blk false;
            if (op == .percent and ctx != .param) break :blk false;
            const child = level(op);
            break :blk child < lv or (right and child == lv);
        },
        else => false,
    };
    if (wrap) try l.put("(");
    try write(l, node, ctx);
    if (wrap) try l.put(")");
}

/// `node` bare when it is a leaf or a call, else in parentheses.
fn grouped(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void {
    const a = l.a;
    const bare = switch (a.tag(node)) {
        .number, .word, .call, .paren => true,
        // Written as a call, or already in parentheses.
        .binary => a.tokenTag(a.node(node).main) == .star_star or (a.tokenTag(a.node(node).main) == .percent and ctx != .param),
        else => false,
    };
    if (!bare) try l.put("(");
    try write(l, node, ctx);
    if (!bare) try l.put(")");
}

fn quotient(l: *Lowerer, x: Index, y: Index, ctx: Ctx) Allocator.Error!void {
    try grouped(l, x, ctx);
    try l.put("/");
    try grouped(l, y, ctx);
}

/// The real power x^y. numparam's `pow` is C's; the B parser's `pow` is
/// |x|^y and its `pwr` sign(x)·|x|^y; `**` is |x|^y in both. A literal
/// exponent picks the form; a computed one picks it by parity at run time.
fn power(l: *Lowerer, x: Index, y: Index, ctx: Ctx) Allocator.Error!void {
    if (ctx == .param) return powCall(l, "pow", x, y, ctx);
    const parity: ?bool = if (isLiteral(l.a, y)) blk: {
        const v = literalValue(l.a, y);
        break :blk if (v != @trunc(v)) null else @rem(v, 2) != 0;
    } else null;
    if (isLiteral(l.a, y)) {
        const odd = parity orelse false;
        if (ctx == .behavioural) return powCall(l, if (odd) "pwr" else "pow", x, y, ctx);
        return if (odd) signedPower(l, x, y, ctx) else starPower(l, x, y, ctx);
    }
    // y - 2·floor(y/2) is 0 exactly for an even whole y.
    try l.put("((");
    try write(l, y, ctx);
    try l.put(")-2*floor((");
    try write(l, y, ctx);
    try l.put(")/2)==0?");
    if (ctx == .behavioural) try powCall(l, "pow", x, y, ctx) else try starPower(l, x, y, ctx);
    try l.put(":");
    if (ctx == .behavioural) try powCall(l, "pwr", x, y, ctx) else try signedPower(l, x, y, ctx);
    try l.put(")");
}

fn powCall(l: *Lowerer, f: []const u8, x: Index, y: Index, ctx: Ctx) Allocator.Error!void {
    try l.put(f);
    try l.put("(");
    try write(l, x, ctx);
    try l.put(",");
    try write(l, y, ctx);
    try l.put(")");
}

/// |x|^y, the same in every legacy context.
fn starPower(l: *Lowerer, x: Index, y: Index, ctx: Ctx) Allocator.Error!void {
    try l.put("(");
    try grouped(l, x, ctx);
    try l.put("**");
    try grouped(l, y, ctx);
    try l.put(")");
}

/// sign(x)·|x|^y, the same in every legacy context.
fn signedPower(l: *Lowerer, x: Index, y: Index, ctx: Ctx) Allocator.Error!void {
    try l.put("(sgn(");
    try write(l, x, ctx);
    try l.put(")*");
    try grouped(l, x, ctx);
    try l.put("**");
    try grouped(l, y, ctx);
    try l.put(")");
}

fn literalValue(a: *const Ast, node: Index) f64 {
    assert(isLiteral(a, node));
    if (a.tag(node) == .number) return if (number.read(a.text(node)).number) |n| n.value else 0;
    const v = literalValue(a, a.node(node).lhs);
    return if (a.tokenTag(a.node(node).main) == .minus) -v else v;
}

fn call(l: *Lowerer, node: Index, ctx: Ctx) Allocator.Error!void {
    const a = l.a;
    const f = a.callee(node);
    const args = a.children(node);
    for (args) |arg| if (a.tag(arg) == .setting) {
        try l.diags.add(.wrong_kind, a.at(arg), "a keyed argument in an expression");
        return l.put("0");
    };
    if (ctx == .param and circuit_calls.has(f)) try l.diags.add(.reads_circuit, a.at(node), f);
    if (std.mem.eql(u8, f, "ternary_fcn")) try l.diags.add(.retired, a.at(node), f);
    const Rewrite = enum { pow, pwr, idiv, int, sqr };
    const rewrite = std.meta.stringToEnum(Rewrite, f) orelse return plainCall(l, f, args, ctx);
    const want: usize = switch (rewrite) {
        .pow, .pwr, .idiv => 2,
        .int, .sqr => 1,
    };
    if (args.len != want) {
        try l.diags.add(.arity, a.at(node), f);
        return l.put("0");
    }
    switch (rewrite) {
        .pow => try power(l, args[0], args[1], ctx),
        .pwr => try signedPower(l, args[0], args[1], ctx),
        .idiv => if (ctx == .param) {
            try l.put("(");
            try grouped(l, args[0], ctx);
            try l.put("\\");
            try grouped(l, args[1], ctx);
            try l.put(")");
        } else {
            // numparam's `\` is trunc(|a/b|), which is floor(|a/b|).
            try l.put("floor(abs(");
            try quotient(l, args[0], args[1], ctx);
            try l.put("))");
        },
        .int => if (ctx == .param) try plainCall(l, f, args, ctx) else {
            try l.put("(sgn(");
            try write(l, args[0], ctx);
            try l.put(")*floor(abs(");
            try write(l, args[0], ctx);
            try l.put(")))");
        },
        .sqr => if (ctx == .param) try plainCall(l, f, args, ctx) else {
            try l.put("(");
            try grouped(l, args[0], ctx);
            try l.put("*");
            try grouped(l, args[0], ctx);
            try l.put(")");
        },
    }
}

fn plainCall(l: *Lowerer, f: []const u8, args: []const u32, ctx: Ctx) Allocator.Error!void {
    try l.put(f);
    try l.put("(");
    for (args, 0..) |arg, i| {
        if (i > 0) try l.put(",");
        try write(l, arg, ctx);
    }
    try l.put(")");
}
