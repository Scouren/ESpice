//! Differential tests for expr.zig: a random expression tree, printed as
//! ngspice text with only the parentheses its precedence needs, compiled
//! and folded by expr.zig, against the tree's value computed by a naive
//! recursive f64 evaluator written from expr.zig's doc comments (operator
//! meanings, `%`/`\`, `nint`'s half-to-even). Equal means both NaN, `==`, or at most 1 ULP apart. Also:
//! raw bytes through `compileAll` and `fold` (no panic, only the declared
//! errors), allocation failure through `compileAll` and `fold`, and the
//! generator's function names against expr_ops.zig `fns`.
const std = @import("std");
const expr = @import("../Parse/expr.zig");
const expr_ops = @import("../Parse/expr_ops.zig");
const spice_number = @import("../Parse/spice_number.zig");
const Smith = std.testing.Smith;
const Seeded = @import("seeded.zig").Seeded;

/// Generator recursion bound; trees stay under `nodes_max` nodes.
const depth_max = 6;
const nodes_max = 1 << 12;
const text_max = 1 << 15;

/// Plain decimal literals; the reference reads them with `std.fmt.parseFloat`.
const literals = [_][]const u8{ "0", "1", "2", "3", "7", "10", "0.5", "2.5", ".25", "0.1", "1e3", "2.5e-3", "1e-300", "1e300", "123.456" };

const BinOp = struct { text: []const u8, prec: u8 };
/// Every binary operator `compile` reads.
const bin_ops = [_]BinOp{
    .{ .text = "||", .prec = 1 }, .{ .text = "&&", .prec = 2 }, .{ .text = "<", .prec = 3 },  .{ .text = ">", .prec = 3 },
    .{ .text = "<=", .prec = 3 }, .{ .text = ">=", .prec = 3 }, .{ .text = "==", .prec = 3 }, .{ .text = "!=", .prec = 3 },
    .{ .text = "<>", .prec = 3 }, .{ .text = "+", .prec = 4 },  .{ .text = "-", .prec = 4 },  .{ .text = "*", .prec = 5 },
    .{ .text = "/", .prec = 5 },  .{ .text = "^", .prec = 6 },  .{ .text = "**", .prec = 6 }, .{ .text = "%", .prec = 5 },
    .{ .text = "\\", .prec = 5 },
};

const Func = struct { name: []const u8, arity: u8 };
const funcs = [_]Func{
    .{ .name = "sqrt", .arity = 1 },  .{ .name = "abs", .arity = 1 },         .{ .name = "min", .arity = 2 },    .{ .name = "max", .arity = 2 },
    .{ .name = "pow", .arity = 2 },   .{ .name = "pwr", .arity = 2 },         .{ .name = "exp", .arity = 1 },    .{ .name = "ln", .arity = 1 },
    .{ .name = "log", .arity = 1 },   .{ .name = "log10", .arity = 1 },       .{ .name = "sin", .arity = 1 },    .{ .name = "cos", .arity = 1 },
    .{ .name = "tan", .arity = 1 },   .{ .name = "atan", .arity = 1 },        .{ .name = "arctan", .arity = 1 }, .{ .name = "floor", .arity = 1 },
    .{ .name = "ceil", .arity = 1 },  .{ .name = "ternary_fcn", .arity = 3 }, .{ .name = "tanh", .arity = 1 },   .{ .name = "sqr", .arity = 1 },
    .{ .name = "int", .arity = 1 },   .{ .name = "nint", .arity = 1 },        .{ .name = "sgn", .arity = 1 },    .{ .name = "sinh", .arity = 1 },
    .{ .name = "cosh", .arity = 1 },  .{ .name = "asin", .arity = 1 },        .{ .name = "acos", .arity = 1 },   .{ .name = "asinh", .arity = 1 },
    .{ .name = "acosh", .arity = 1 }, .{ .name = "atanh", .arity = 1 },       .{ .name = "agauss", .arity = 3 }, .{ .name = "gauss", .arity = 2 },
    .{ .name = "unif", .arity = 2 },  .{ .name = "aunif", .arity = 4 },       .{ .name = "limit", .arity = 2 },
};

const Tag = enum { num, neg, plus, not, bin, tern, call };
/// `op`: the literal, `bin_ops` or `funcs` index; `kids[0..n]` the operands.
const Node = struct { tag: Tag, op: u8 = 0, n: u8 = 0, kids: [4]u16 = undefined };

const Tree = struct {
    nodes: [nodes_max]Node = undefined,
    len: u16 = 0,

    fn add(t: *Tree, n: Node) u16 {
        t.nodes[t.len] = n;
        t.len += 1;
        return t.len - 1;
    }

    /// `src` is a `*Smith` or a `*Seeded`.
    fn gen(t: *Tree, src: anytype, depth: u8) u16 {
        if (depth == depth_max or t.len + 8 > nodes_max or src.eosWeightedSimple(2, 1))
            return t.add(.{ .tag = .num, .op = @intCast(src.index(literals.len)) });
        const tags = [_]Tag{ .neg, .plus, .not, .bin, .bin, .bin, .bin, .tern, .call, .call };
        const tag = tags[src.index(tags.len)];
        var n: Node = .{ .tag = tag };
        switch (tag) {
            .num => unreachable,
            .neg, .plus, .not => n.n = 1,
            .bin => {
                n.op = @intCast(src.index(bin_ops.len));
                n.n = 2;
            },
            .tern => n.n = 3,
            .call => {
                n.op = @intCast(src.index(funcs.len));
                n.n = funcs[n.op].arity;
            },
        }
        for (n.kids[0..n.n]) |*k| k.* = t.gen(src, depth + 1);
        return t.add(n);
    }

    /// Whether `child` needs parentheses as operand `side` of `parent`,
    /// read off `compile`'s grammar: a unary operator's operand reaches to
    /// the next operator looser than a power, `!`'s to the next operator,
    /// and the ternary's condition is everything before its `?`.
    fn paren(parent: Node, side: usize, child: Node) bool {
        const unary = child.tag == .neg or child.tag == .plus or child.tag == .not;
        const prec: u8 = switch (child.tag) {
            .num, .call => 10,
            .neg, .plus, .not => 8,
            .bin => bin_ops[child.op].prec,
            .tern => 0,
        };
        return switch (parent.tag) {
            .num => unreachable,
            .neg, .plus => prec < 6,
            .not => prec < 8,
            .bin => blk: {
                const p = bin_ops[parent.op].prec;
                if (unary) break :blk p == 6;
                break :blk if (side == 0) prec < p else prec <= p;
            },
            .tern => side == 0 and prec == 0,
            .call => false,
        };
    }

    fn print(t: *const Tree, w: *std.Io.Writer, src: anytype, i: u16) !void {
        const n = t.nodes[i];
        const sp: []const u8 = if (src.eosWeightedSimple(3, 1)) " " else "";
        switch (n.tag) {
            .num => return w.writeAll(literals[n.op]),
            .neg => try w.writeAll("-"),
            .plus => try w.writeAll("+"),
            .not => try w.writeAll("!"),
            .call => {
                try w.print("{s}(", .{funcs[n.op].name});
                for (n.kids[0..n.n], 0..) |k, a| {
                    if (a > 0) try w.print("{s},{s}", .{ sp, sp });
                    try t.print(w, src, k);
                }
                return w.writeAll(")");
            },
            .bin, .tern => {},
        }
        for (n.kids[0..n.n], 0..) |k, side| {
            if (side > 0) try w.print("{s}{s}{s}", .{ sp, switch (n.tag) {
                .bin => bin_ops[n.op].text,
                .tern => if (side == 1) "?" else ":",
                .num, .neg, .plus, .not, .call => "",
            }, sp });
            const p = paren(n, side, t.nodes[k]);
            if (p) try w.writeAll("(");
            try t.print(w, src, k);
            if (p) try w.writeAll(")");
        }
    }

    /// The reference: recursive, straight from the operator definitions.
    fn value(t: *const Tree, i: u16) f64 {
        const n = t.nodes[i];
        var v: [4]f64 = undefined;
        for (n.kids[0..n.n], v[0..n.n]) |k, *o| o.* = t.value(k);
        return switch (n.tag) {
            .num => std.fmt.parseFloat(f64, literals[n.op]) catch unreachable,
            .neg => -v[0],
            .plus => v[0],
            .not => if (v[0] == 0) 1 else 0,
            .tern => if (v[0] == 0) v[2] else v[1],
            .bin => binary(bin_ops[n.op].text, v[0], v[1]),
            .call => call(funcs[n.op].name, v[0..n.n]),
        };
    }
};

// ---- private ----

fn truth(b: bool) f64 {
    return if (b) 1 else 0;
}

fn binary(op: []const u8, x: f64, y: f64) f64 {
    const eq = std.mem.eql;
    if (eq(u8, op, "||")) return truth(x != 0 or y != 0);
    if (eq(u8, op, "&&")) return truth(x != 0 and y != 0);
    if (eq(u8, op, "<")) return truth(x < y);
    if (eq(u8, op, ">")) return truth(x > y);
    if (eq(u8, op, "<=")) return truth(x <= y);
    if (eq(u8, op, ">=")) return truth(x >= y);
    if (eq(u8, op, "==")) return truth(x == y);
    if (eq(u8, op, "!=") or eq(u8, op, "<>")) return truth(x != y);
    if (eq(u8, op, "+")) return x + y;
    if (eq(u8, op, "-")) return x - y;
    if (eq(u8, op, "*")) return x * y;
    if (eq(u8, op, "/")) return x / y;
    if (eq(u8, op, "%")) return x - y * @trunc(x / y);
    if (eq(u8, op, "\\")) return @trunc(@abs(x / y));
    // `^` and `**`: |x|^y, as ngspice's PTpower.
    return std.math.pow(f64, @abs(x), y);
}

fn call(name: []const u8, a: []const f64) f64 {
    const eq = std.mem.eql;
    const x = a[0];
    const m = std.math;
    if (eq(u8, name, "sqrt")) return @sqrt(x);
    if (eq(u8, name, "abs")) return @abs(x);
    if (eq(u8, name, "min")) return @min(x, a[1]);
    if (eq(u8, name, "max")) return @max(x, a[1]);
    // numparam's pow is C's pow, its pwr |x|^y (xpressn.c XFU_POW, XFU_PWR).
    if (eq(u8, name, "pow")) return m.pow(f64, x, a[1]);
    if (eq(u8, name, "pwr")) return m.pow(f64, @abs(x), a[1]);
    if (eq(u8, name, "exp")) return @exp(x);
    if (eq(u8, name, "ln") or eq(u8, name, "log")) return @log(x);
    if (eq(u8, name, "log10")) return @log10(x);
    if (eq(u8, name, "sin")) return @sin(x);
    if (eq(u8, name, "cos")) return @cos(x);
    if (eq(u8, name, "tan")) return @tan(x);
    if (eq(u8, name, "atan") or eq(u8, name, "arctan")) return m.atan(x);
    if (eq(u8, name, "floor")) return @floor(x);
    if (eq(u8, name, "ceil")) return @ceil(x);
    if (eq(u8, name, "ternary_fcn")) return if (x == 0) a[2] else a[1];
    if (eq(u8, name, "tanh")) return m.tanh(x);
    if (eq(u8, name, "sqr")) return x * x;
    if (eq(u8, name, "int")) return @trunc(x);
    if (eq(u8, name, "nint")) {
        // Half to even, from the floor rather than `@round`; a zero keeps
        // x's sign, as IEEE roundToIntegralTiesToEven does.
        if (!m.isFinite(x)) return x;
        const f = @floor(x);
        const d = x - f;
        const r = if (d < 0.5) f else if (d > 0.5) f + 1 else if (@mod(f, 2) == 0) f else f + 1;
        return if (r == 0) m.copysign(@as(f64, 0), x) else r;
    }
    // numparam's sgn: 0 for anything neither above nor below 0, NaN included.
    if (eq(u8, name, "sgn")) return if (x > 0) 1 else if (x < 0) -1 else 0;
    if (eq(u8, name, "sinh")) return m.sinh(x);
    if (eq(u8, name, "cosh")) return m.cosh(x);
    if (eq(u8, name, "asin")) return m.asin(x);
    if (eq(u8, name, "acos")) return m.acos(x);
    if (eq(u8, name, "asinh")) return m.asinh(x);
    if (eq(u8, name, "acosh")) return m.acosh(x);
    if (eq(u8, name, "atanh")) return m.atanh(x);
    // Distributions and `limit` fold to their nominal.
    return x;
}

/// Both NaN, equal (+0 == -0), or at most one ULP apart.
fn same(a: f64, b: f64) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.isNan(a) and std.math.isNan(b);
    if (a == b) return true;
    const key = struct {
        fn of(v: f64) i64 {
            const i: i64 = @bitCast(v);
            return i ^ ((i >> 63) & 0x7fff_ffff_ffff_ffff);
        }
    }.of;
    return @abs(@as(i128, key(a)) - key(b)) <= 1;
}

fn checkOne(src: anytype) !void {
    var tree: Tree = .{};
    const root = tree.gen(src, 0);
    var buf: [text_max]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    tree.print(&w, src, root) catch return; // Too long for `buf`: skip.
    const text = w.buffered();
    const want = tree.value(root);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: expr.Scratch = .{};
    expr.compileAll(a, &s, text) catch |err| {
        std.debug.print("{s} for `{s}`\n", .{ @errorName(err), text });
        return err;
    };
    var stack: std.ArrayList(expr.Val) = .empty;
    const folded = try expr.fold(a, &stack, s.ops.items, s.consts.items, false, &.{});
    const evaluated = try expr.eval(a, &stack, s.ops.items, s.consts.items, &.{}, null);
    if (!folded.known or !same(folded.num, want) or !same(evaluated, want)) {
        // An unknown fold holds no number: its `num` is a 0 nothing reads.
        if (folded.known)
            std.debug.print("`{s}`: reference {e}, fold {e}, eval {e}\n", .{ text, want, folded.num, evaluated })
        else
            std.debug.print("`{s}`: reference {e}, fold left it unknown, eval {e}\n", .{ text, want, evaluated });
        return error.TestUnexpectedResult;
    }
    // The whole postfix is one subtree.
    try std.testing.expectEqual(0, expr.subtreeStart(s.ops.items, s.ops.items.len - 1));
}

fn fuzzReference(_: void, s: *Smith) anyerror!void {
    try checkOne(s);
}

fn rawCheck(gpa: std.mem.Allocator, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var s: expr.Scratch = .{};
    expr.compileAll(a, &s, text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseError => return,
    };
    // A compiled expression is one complete postfix tree.
    var stack: std.ArrayList(expr.Val) = .empty;
    _ = try expr.fold(a, &stack, s.ops.items, s.consts.items, true, &.{});
    _ = try expr.eval(a, &stack, s.ops.items, s.consts.items, &.{}, null);
    try std.testing.expectEqual(0, expr.subtreeStart(s.ops.items, s.ops.items.len - 1));
}

fn fuzzRaw(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 12]u8 = undefined;
    try rawCheck(std.testing.allocator, buf[0..s.slice(&buf)]);
}

fn compileFold(gpa: std.mem.Allocator, text: []const u8) !void {
    var s: expr.Scratch = .{};
    defer {
        s.ops.deinit(gpa);
        s.consts.deinit(gpa);
        s.names.deinit(gpa);
    }
    try expr.compileAll(gpa, &s, text);
    var stack: std.ArrayList(expr.Val) = .empty;
    defer stack.deinit(gpa);
    _ = try expr.fold(gpa, &stack, s.ops.items, s.consts.items, false, &.{});
    _ = try expr.eval(gpa, &stack, s.ops.items, s.consts.items, &.{}, null);
}

test "fuzz expr: fold and eval against a recursive reference evaluator" {
    try std.testing.fuzz({}, fuzzReference, .{});
}

test "expr: 5000 seeded expressions match the reference evaluator" {
    var prng: std.Random.DefaultPrng = .init(0xe4b5_0001);
    var src: Seeded = .{ .r = prng.random() };
    for (0..5000) |_| try checkOne(&src);
}

test "expr: the generator calls the built-ins a deck can spell, and no other" {
    // Name lists, both ways, against expr_ops.zig `fns` but its TABLE,
    // which only reader_behavioural.zig writes. Red before: `ternary`,
    // which ngspice-44.2 refuses ("Undefined parameter [ternary]") and
    // `fns` dropped, stayed here, so the reference evaluated a call the
    // fold leaves unknown (the seeded loop, unit7 17:10).
    const gpa = std.testing.allocator;
    var differ: std.ArrayList(u8) = .empty;
    defer differ.deinit(gpa);
    for (funcs) |f| if (!expr_ops.fns.has(f.name)) try differ.print(gpa, "generator only: {s}\n", .{f.name});
    for (expr_ops.fns.keys()) |name| {
        if (std.mem.eql(u8, name, "TABLE")) continue;
        for (funcs) |f| {
            if (std.mem.eql(u8, f.name, name)) break;
        } else try differ.print(gpa, "fns only: {s}\n", .{name});
    }
    try std.testing.expectEqualStrings("", differ.items);
}

test "expr: a NaN condition takes the true branch, as ngspice-44.2 reads it" {
    // ngspice-44.2 -b printed 0.25 for each text as `.param p={...}` read by
    // `vp p 0 {p}`, and for the first two as `b1 o 0 v=...`: acosh(0) is
    // NaN, and NaN is not 0. The third is the seeded loop's failing case
    // (unit7 17:10) with ternary_fcn; spelled `ternary(` it stops ngspice
    // ("Undefined parameter [ternary]") and stays unknown here. A guard:
    // fold and eval already read NaN as true, as the reference does.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stack: std.ArrayList(expr.Val) = .empty;
    const seeded = "acosh(TERNARY(-0.5,+acosh(2.5e-3 <= 2),exp(3/.25%!123.456))) ? .25 : abs(0.5)";
    const texts = [_][]const u8{ "acosh(0) ? .25 : .5", "ternary_fcn(acosh(0), .25, .5)", try std.mem.replaceOwned(u8, a, seeded, "TERNARY", "ternary_fcn") };
    for (texts) |text| {
        var s: expr.Scratch = .{};
        try expr.compileAll(a, &s, text);
        const folded = try expr.fold(a, &stack, s.ops.items, s.consts.items, false, &.{});
        try std.testing.expect(folded.known);
        try std.testing.expectEqual(0.25, folded.num);
        try std.testing.expectEqual(0.25, try expr.eval(a, &stack, s.ops.items, s.consts.items, &.{}, null));
    }
    var bare: expr.Scratch = .{};
    try expr.compileAll(a, &bare, try std.mem.replaceOwned(u8, a, seeded, "TERNARY", "ternary"));
    try std.testing.expect(!(try expr.fold(a, &stack, bare.ops.items, bare.consts.items, false, &.{})).known);
}

test "expr: the precedence the printer assumes, by hand" {
    // Values derived by hand from `compile`'s grammar: a unary operand
    // reaches over a power (`2^-1^2` is 2^(-(1^2))), `!`'s does not.
    for ([_]struct { []const u8, f64 }{
        .{ "-2^2", -4 },     .{ "2^3^2", 64 },    .{ "!0^2", 1 },    .{ "2^-1^2", 0.5 },
        .{ "1?2:0?3:4", 2 }, .{ "0?2:0?3:4", 4 }, .{ "1+1?5:6", 5 }, .{ "7%4*2", 6 },
        .{ "1<2==1", 1 },    .{ "-3%2", -1 },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var s: expr.Scratch = .{};
        try expr.compileAll(arena.allocator(), &s, case[0]);
        var stack: std.ArrayList(expr.Val) = .empty;
        try std.testing.expectEqual(case[1], (try expr.fold(arena.allocator(), &stack, s.ops.items, s.consts.items, false, &.{})).num);
    }
}

test "expr: literals read as std.fmt.parseFloat reads them" {
    for (literals) |text| {
        const want = try std.fmt.parseFloat(f64, text);
        try std.testing.expectEqual(want, spice_number.spiceNumber(text).?);
    }
}

test "fuzz expr: raw bytes compile or fail with a declared error" {
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = &.{ "1+2*3", "v(a,b)*i(v1)", "f(1,2)?x:-y", "((1))", "1e3k**2", "!a<>b", "'1'+\"2\"" } });
}

test "expr: compile, fold and eval fail cleanly at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileFold, .{"max(1, x) + v(a, b) * foo(2, 3) ? 1 : agauss(1, 2, 3)"});
}
