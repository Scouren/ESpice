//! Expressions as flat postfix. In: expression text, or final ops after
//! reader_subst.zig `subst`. Out: the compiled tape (expr_compile.zig) and its
//! value, folded on a value stack (`fold`, `eval`). No tree is built: a
//! consumer walks subtrees backwards from their last op (`subtreeStart`).
//! Cites: dev/research/ngspice-syntax.md §2.2, ngspice xpressn.c (#39, #77).
//!
//! Contents:
//! - `pub const Error = expr_ops.Error`
//! - `pub const none = expr_ops.none`
//! - `pub const Code = expr_ops.Code`
//! - `pub const Fn = expr_ops.Fn`
//! - `pub const Op = expr_ops.Op`
//! - `pub const Scratch = expr_ops.Scratch`
//! - `pub const isDistributionName = expr_ops.isDistributionName`
//! - `pub const isDistribution = expr_ops.isDistribution`
//! - `pub const bsourceFn = expr_ops.bsourceFn`
//! - `pub const max_depth = expr_compile.max_depth`
//! - `pub const compile = expr_compile.compile`
//! - `pub const compileAll = expr_compile.compileAll`
//! - `pub const numberLen = expr_compile.numberLen`
//! - `pub const isOperator = expr_compile.isOperator`
//! - `pub const Val = struct`
//! - `pub fn fold(gpa: Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, geometry: bool, live: []const f64) Error!Val`
//! - `pub fn arity(op: Op) u32`
//! - `pub fn subtreeStart(ops: []const Op, end: usize) usize`
//! - `pub fn eval(gpa: Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, live: []const f64, draw: anytype) Error!f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const expr_ops = @import("expr_ops.zig");
const expr_compile = @import("expr_compile.zig");

/// Malformed text (`ParseError`) or no memory; `fold` and `eval` fail only
/// with `OutOfMemory`. A failed `compile` leaves what it appended in the
/// `Scratch`; roll it back with `Scratch.mark` and `Scratch.reset`.
pub const Error = expr_ops.Error;

/// Absent operand.
pub const none = expr_ops.none;

/// Postfix opcode.
pub const Code = expr_ops.Code;

/// Built-in functions.
pub const Fn = expr_ops.Fn;

/// One postfix op.
pub const Op = expr_ops.Op;

/// Compile output before parameters are spliced in.
pub const Scratch = expr_ops.Scratch;

/// True when `name` (lower case) calls a function a Monte Carlo trial draws.
pub const isDistributionName = expr_ops.isDistributionName;

/// True for the functions a Monte Carlo trial draws.
pub const isDistribution = expr_ops.isDistribution;

/// The B parser's meaning of a numparam built-in; null where it has none.
pub const bsourceFn = expr_ops.bsourceFn;

/// Recursion bound of `compile`, in parser calls.
pub const max_depth = expr_compile.max_depth;

/// Compiles the expression at `text[pos]`; returns where it ends.
pub const compile = expr_compile.compile;

/// Compiles the whole of `text`; trailing input is a ParseError.
pub const compileAll = expr_compile.compileAll;

/// Length of the number literal `text` starts with.
pub const numberLen = expr_compile.numberLen;

/// A byte that continues an expression after an operand.
pub const isOperator = expr_compile.isOperator;

/// A folded value. `nominal` records, for an unknown value, whether a zero
/// multiplier may still erase it: finite constants, declared model geometry
/// (`l`, `w`, `mult`) and distributions (`agauss(...)`) whose nominal did not fold, combined by
/// arithmetic and math calls (the nominal PDK corner `0*agauss(...)`).
pub const Val = struct {
    num: f64 = 0,
    known: bool,
    nominal: bool = false,

    fn isNominal(v: Val) bool {
        return if (v.known) std.math.isFinite(v.num) else v.nominal;
    }

    fn unknown(nominal: bool) Val {
        return .{ .known = false, .nominal = nominal };
    }

    fn of(n: f64) Val {
        return .{ .num = n, .known = true };
    }
};

/// Folds final ops (after `subst`) to a value; `stack` is reused scratch
/// in `gpa`. `geometry` lets model-card `l`/`w`/`mult` vanish behind a zero
/// switch; `live` holds the current value of each `.live` operand. Asserts
/// `ops` is one complete postfix expression, as `compile` emits. Fails only
/// with `OutOfMemory`, growing `stack` to `ops.len`.
pub fn fold(gpa: Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, geometry: bool, live: []const f64) Error!Val {
    stack.clearRetainingCapacity();
    // Every op pushes at most one value: one reserve, no per-op growth check.
    try stack.ensureTotalCapacity(gpa, ops.len);
    assert(ops.len > 0);
    for (ops) |op| step(stack, op, consts, geometry, live);
    return stack.pop().?;
}

/// Operands an op pops.
pub fn arity(op: Op) u32 {
    return switch (op.code) {
        .num, .ident, .live, .vprobe, .iprobe => 0,
        .neg, .not => 1,
        .call, .ucall => op.b,
        else => 2,
    };
}

/// First op of the subtree whose root is `ops[end]`. O(subtree size).
/// Asserts `ops[0..end + 1]` holds that whole subtree.
pub fn subtreeStart(ops: []const Op, end: usize) usize {
    assert(end < ops.len);
    var need: u32 = 1;
    var i = end;
    while (true) : (i -= 1) {
        need = need - 1 + arity(ops[i]);
        if (need == 0) return i;
    }
}

/// Evaluates ops that fold to a number: constants, `.live` operands and
/// arithmetic, as `fold` would, except that the distribution call ending at
/// op `i` returns `draw.value(i, f, args)` when `draw` is not null. `stack`
/// is reused scratch in `gpa`. Ops `fold` leaves unknown evaluate to NaN.
/// Asserts `ops` is one complete postfix expression.
pub fn eval(gpa: Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, live: []const f64, draw: anytype) Error!f64 {
    assert(ops.len > 0);
    stack.clearRetainingCapacity();
    try stack.ensureTotalCapacity(gpa, ops.len);
    for (ops, 0..) |op, i| {
        if (op.code == .call and @TypeOf(draw) != @TypeOf(null) and isDistribution(@fromBackingInt(@intCast(op.a)))) {
            const argc: usize = op.b;
            var nums: [4]f64 = @splat(0);
            const args = stack.items[stack.items.len - argc ..];
            for (args, 0..) |a, k| if (k < nums.len) {
                nums[k] = if (a.known) a.num else std.math.nan(f64);
            };
            stack.shrinkRetainingCapacity(stack.items.len - argc);
            stack.appendAssumeCapacity(.of(draw.value(i, @fromBackingInt(@intCast(op.a)), nums[0..@min(argc, nums.len)])));
            continue;
        }
        step(stack, op, consts, false, live);
    }
    const top = stack.pop().?;
    return if (top.known) top.num else std.math.nan(f64);
}

// ---- private ----

fn bool01(b: bool) f64 {
    return @floatFromInt(@intFromBool(b));
}

/// Applies one postfix op to the value stack, which has room for its push.
fn step(stack: *std.ArrayList(Val), op: Op, consts: []const f64, geometry: bool, live: []const f64) void {
    const v: Val = switch (op.code) {
        .num => .of(consts[op.a]),
        .live => .of(live[op.a]),
        .ident => .unknown(geometry and op.a == 1),
        .vprobe, .iprobe => .unknown(false),
        .neg, .not => blk: {
            const x = stack.pop().?;
            if (!x.known) break :blk .unknown(x.isNominal());
            break :blk .of(if (op.code == .neg) -x.num else bool01(x.num == 0));
        },
        .call => blk: {
            const argc: usize = op.b;
            const args = stack.items[stack.items.len - argc ..];
            const result = call(@fromBackingInt(@intCast(op.a)), args);
            stack.shrinkRetainingCapacity(stack.items.len - argc);
            break :blk result;
        },
        // An unknown function, before `subst`: nothing to fold it with.
        .ucall => blk: {
            stack.shrinkRetainingCapacity(stack.items.len - op.b);
            break :blk .unknown(false);
        },
        else => blk: {
            const b = stack.pop().?;
            const a = stack.pop().?;
            if (op.code == .mul and ((a.known and a.num == 0 and !b.known and b.nominal) or
                (b.known and b.num == 0 and !a.known and a.nominal))) break :blk .of(0);
            if (!a.known or !b.known) break :blk .unknown(a.isNominal() and b.isNominal());
            const x = a.num;
            const y = b.num;
            break :blk .of(switch (op.code) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
                .div => x / y,
                .mod => x - y * @trunc(x / y),
                .idiv => @trunc(@abs(x / y)),
                .pow => std.math.pow(f64, @abs(x), y),
                .lt => bool01(x < y),
                .gt => bool01(x > y),
                .le => bool01(x <= y),
                .ge => bool01(x >= y),
                .eq => bool01(x == y),
                .ne => bool01(x != y),
                .@"and" => bool01(x != 0 and y != 0),
                .@"or" => bool01(x != 0 or y != 0),
                else => unreachable,
            });
        },
    };
    stack.appendAssumeCapacity(v);
}

fn call(f: Fn, args: []const Val) Val {
    var all_nominal = true;
    var all_known = true;
    for (args) |a| {
        all_nominal = all_nominal and a.isNominal();
        all_known = all_known and a.known;
    }
    const want: usize = switch (f) {
        // `ddt` reads the circuit's history, even of a constant.
        .table, .ddt => return .unknown(false),
        // Folding keeps the nominal; a Monte Carlo trial draws through
        // `eval`'s `draw` instead.
        .agauss, .gauss, .unif, .aunif => return if (args.len >= 2 and args.len <= 4 and args[0].known) args[0] else .unknown(args.len >= 2 and all_nominal),
        .limit => return if (args.len == 2 and args[0].known) args[0] else .unknown(false),
        .ternary => 3,
        // numparam seeds a call's second operand `v = 1.0` (xpressn.c:921)
        // and keeps it when the call has one argument, so max(x) is
        // MAX(x, 1) and min(x) MIN(x, 1) (xpressn.c:142-146).
        .min, .max => if (args.len == 1) 1 else 2,
        .pow, .pwr, .bpwr => 2,
        else => 1,
    };
    if (args.len != want or !args[0].known) return .unknown(all_nominal);
    const a = args[0].num;
    if (f == .ternary) {
        const picked = args[if (a != 0) 1 else 2];
        return if (picked.known) picked else .unknown(all_nominal);
    }
    if (want == 2 and !args[1].known) return .unknown(all_nominal);
    // A one-argument min or max reads numparam's seeded 1; no other
    // one-argument function reads `b`.
    const b = if (want == 2) args[1].num else 1;
    return .of(switch (f) {
        .sqrt => @sqrt(a),
        .abs => @abs(a),
        .min => @min(a, b),
        .max => @max(a, b),
        // numparam's pow is C's (xpressn.c XFU_POW): pow(-2, 3) is -8 and
        // pow(-2, 2.5) NaN, where ngspice-44.2 fails the deck. Its pwr is
        // |a|^b (XFU_PWR), so pwr(-0, 0) is 1, and so is the B parser's
        // pow; the B parser's pwr is PTpwr's sign(a)·|a|^b (`bsourceFn`).
        .pow => std.math.pow(f64, a, b),
        .pwr => std.math.pow(f64, @abs(a), b),
        .bpwr => if (a < 0) -std.math.pow(f64, -a, b) else std.math.pow(f64, a, b),
        .exp => @exp(a),
        .ln, .log => @log(a),
        .log10 => @log10(a),
        .sin => @sin(a),
        .cos => @cos(a),
        .tan => @tan(a),
        .atan, .arctan => std.math.atan(a),
        .floor => @floor(a),
        .ceil => @ceil(a),
        .tanh => std.math.tanh(a),
        .sqr => a * a,
        .int => @trunc(a),
        .nint => roundHalfEven(a),
        .sgn => std.math.sign(a),
        .sinh => std.math.sinh(a),
        .cosh => std.math.cosh(a),
        .asin => std.math.asin(a),
        .acos => std.math.acos(a),
        .asinh => std.math.asinh(a),
        .acosh => std.math.acosh(a),
        .atanh => std.math.atanh(a),
        .ternary, .agauss, .gauss, .unif, .aunif, .limit, .table, .ddt => unreachable,
    });
}

/// numparam's `nint` (§2.2): to the nearest integer, a half to the even one.
/// A zero keeps `a`'s sign, so nint(-0.5) is -0, as in ngspice.
fn roundHalfEven(a: f64) f64 {
    const r = @round(a);
    if (@abs(a - @trunc(a)) != 0.5) return r;
    return std.math.copysign(if (@mod(r, 2) == 0) r else r - std.math.sign(a), a);
}

fn testFold(a: std.mem.Allocator, text: []const u8) !Val {
    var s: Scratch = .{};
    try compileAll(a, &s, text);
    var stack: std.ArrayList(Val) = .empty;
    return fold(a, &stack, s.ops.items, s.consts.items, false, &.{});
}

test "compile and fold: precedence, associativity and calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, f64 };
    for ([_]Case{
        .{ "1+2*3", 1 + 2 * 3 },        .{ "(1+2)*3", (1 + 2) * 3 },         .{ "7-2-1", 7 - 2 - 1 },
        .{ "10/4", 10.0 / 4.0 },        .{ "2^3^2", 64 },                    .{ "2**3", 8 },
        .{ "-2^2", -4 },                .{ "2^-1", 0.5 },                    .{ "+3", 3 },
        .{ "1<2", 1 },                  .{ "2<=1", 0 },                      .{ "1>=1", 1 },
        .{ "3>2", 1 },                  .{ "1==1", 1 },                      .{ "1!=1", 0 },
        .{ "1&&0", 0 },                 .{ "1||0", 1 },                      .{ "!0", 1 },
        .{ "!3", 0 },                   .{ "1?2:3", 2 },                     .{ "0?2:3", 3 },
        .{ "1+1?4:5", 4 },              .{ "'1+2'*2", 6 },                   .{ "\"2\"", 2 },
        .{ "sqrt(16)", 4 },             .{ "max(1,min(5,3))", 3 },           .{ "pow(2,10)", 1024 },
        .{ "abs(-3)", 3 },              .{ "floor(2.5)+ceil(2.5)", 5 },      .{ "1k*2", 2000 },
        .{ "agauss(1,0.1,3)", 1 },      .{ "limit(2,1)", 2 },                .{ "1e-3*2", 2e-3 },
        .{ "pwr(-4,0.5)", 2 },          .{ "pwr(9,0.5)", 3 },
        // numparam's operators and built-ins (#121).
                       .{ "7%3", 1 },
        .{ "-7%3", -1 },                .{ "7\\2", 3 },                      .{ "1<>2", 1 },
        .{ "2<>2", 0 },                 .{ "tanh(0)", 0 },                   .{ "sqr(3)", 9 },
        .{ "int(-2.7)", -2 },           .{ "nint(2.5)", 2 },                 .{ "nint(3.5)", 4 },
        .{ "nint(-2.5)", -2 },          .{ "sgn(-3)", -1 },                  .{ "sinh(0)+cosh(0)", 1 },
        .{ "arctan(0)+asin(0)", 0 },    .{ "acos(1)+asinh(0)+atanh(0)", 0 }, .{ "acosh(1)", 0 },
        .{ "ternary_fcn(0,2,3)", 3 },
        // ngspice's powers of a negative base (#39): numparam's pow is C's,
        // its pwr, `^` and `**` |x|^y (ngspice-44.2: -8, 8, 8).
          .{ "pwr(-0,0)", 1 },                 .{ "(-2)^3", 8 },
        .{ "pow(-2,3)", -8 },           .{ "(-2)^0.5", @sqrt(2.0) },         .{ "(-2)^2.5", std.math.pow(f64, 2, 2.5) },
        .{ "pwr(-2,0.5)", @sqrt(2.0) }, .{ "pow(0,0)", 1 },                  .{ "pwr(-2,3)", 8 },
        // numparam's one-argument max and min read a seeded 1 (xpressn.c:921).
        .{ "max(0.5)", 1 },             .{ "max(3)", 3 },                    .{ "min(3)", 1 },
    }) |case| {
        const v = try testFold(a, case[0]);
        try std.testing.expect(v.known);
        try std.testing.expectEqual(case[1], v.num);
    }
    // C's pow of a negative base to a fractional power is NaN; ngspice-44.2
    // fails a deck that reads {pow(-2,2.5)}.
    try std.testing.expect(std.math.isNan((try testFold(a, "pow(-2,2.5)")).num));
    // nint(-0.5) is -0: ngspice-45 reads {1/nint(-0.5)} as -inf. Found by the
    // reference fuzz as ln(+(ln(0)&&3)/nint(-0.5))^1e-300.
    try std.testing.expectEqual(-std.math.inf(f64), (try testFold(a, "1/nint(-0.5)")).num);
    // Names, probes, unknown functions and wrong arities stay symbolic.
    for ([_][]const u8{ "x+1", "v(a)", "i(v1)*2", "foo(1)", "sqrt()", "pow(1)", "agauss(1)" }) |text|
        try std.testing.expect(!(try testFold(a, text)).known);
    // PSPICE's single `|`, `&` and unary `~` too: plain ngspice-44.2 stops
    // on each, "Syntax error: letter [|]"; and a `{` inside the text, which
    // ngspice does not read as a group (src/tests/expressions.zig).
    for ([_][]const u8{ "", "1+", "(1", "1)", "a=b", "1 2", "1?2", "f(1,", "#", "'1", "{1", "(1}", "~", "1|0", "1&0", "~0", "1&&&0", "{1+2}*3", "2*{1}" }) |text| {
        var s: Scratch = .{};
        try std.testing.expectError(error.ParseError, compileAll(a, &s, text));
    }
    // `compile` stops at the first byte that cannot continue the expression.
    var s: Scratch = .{};
    try std.testing.expectEqual(6, try compile(a, &s, "x 1+2 y", 2));
}

test "the B parser's pwr, which `bsourceFn` maps pwr to, is sign(x)·|x|^y; its pow is |x|^y" {
    // ptfuncs.c PTpwr and PTpower; ngspice-44.2 reads b1 o 0 v=pwr(-2,3)
    // as -8, pwr(-2,2.5) as -5.6568542494923806 and pow(-2,3) as 8.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: std.ArrayList(Val) = .empty;
    const Case = struct { Fn, f64, f64, f64 };
    for ([_]Case{
        .{ .pwr, -2, 3, -8 }, .{ .pwr, -2, 2.5, -std.math.pow(f64, 2, 2.5) }, .{ .pwr, 2, 3, 8 },
        .{ .pwr, 0, 0, 1 },   .{ .pow, -2, 3, 8 },                            .{ .pow, -2, 2.5, std.math.pow(f64, 2, 2.5) },
    }) |c| {
        const f = bsourceFn(c[0]).?;
        const ops = [_]Op{ .{ .code = .num, .a = 0 }, .{ .code = .num, .a = 1 }, .{ .code = .call, .a = @backingInt(f), .b = 2 } };
        const v = try fold(arena.allocator(), &stack, &ops, &.{ c[1], c[2] }, false, &.{});
        try std.testing.expect(v.known);
        try std.testing.expectEqual(c[3], v.num);
    }
}

test "`**` and `^` are |x|^y, as ngspice's PTpower (#39, #77)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Hand-computed: 8^(1/3) = 2 and 1.75^3 = 5.359375, both signs dropped.
    try std.testing.expectApproxEqRel(2, (try testFold(a, "(-8)**(1/3)")).num, 1e-15);
    try std.testing.expectApproxEqRel(5.359375, (try testFold(a, "(-1.75)^3")).num, 1e-15);
}

test "compile bounds its recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 100_000;
    for ([_][3]u8{ .{ '(', '1', ')' }, .{ '-', '1', ' ' }, .{ '!', '1', ' ' } }) |shape| {
        const text = try a.alloc(u8, 2 * n + 1);
        @memset(text[0..n], shape[0]);
        text[n] = shape[1];
        @memset(text[n + 1 ..], shape[2]);
        var s: Scratch = .{};
        try std.testing.expectError(error.ParseError, compileAll(a, &s, text));
    }
    // `1?1:1?1:...1` is valid but recurses through `bin` alone.
    var chain: std.ArrayList(u8) = .empty;
    for (0..n) |_| try chain.appendSlice(a, "1?1:");
    try chain.appendSlice(a, "1");
    var s: Scratch = .{};
    try std.testing.expectError(error.ParseError, compileAll(a, &s, chain.items));
    // Realistic nesting still compiles.
    try std.testing.expectEqual(1, (try testFold(a, "((((((((((((((((1))))))))))))))))")).num);
}

test "a zero multiplier erases only nominal unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stack: std.ArrayList(Val) = .empty;
    // `0*w` with w declared geometry (ident a = 1), and `0*x` for any other name.
    const geometry = [_]Op{ .{ .code = .num }, .{ .code = .ident, .a = 1 }, .{ .code = .mul } };
    const other = [_]Op{ .{ .code = .num }, .{ .code = .ident, .a = 0 }, .{ .code = .mul } };
    try std.testing.expectEqual(Val.of(0), try fold(a, &stack, &geometry, &.{0}, true, &.{}));
    try std.testing.expect(!(try fold(a, &stack, &geometry, &.{0}, false, &.{})).known);
    try std.testing.expect(!(try fold(a, &stack, &other, &.{0}, true, &.{})).known);
    // `0*agauss(w, 1, 1)`: the distribution of a nominal unknown is nominal.
    const dist = [_]Op{
        .{ .code = .num },                                       .{ .code = .ident, .a = 1 },
        .{ .code = .num, .a = 1 },                               .{ .code = .num, .a = 1 },
        .{ .code = .call, .a = @backingInt(Fn.agauss), .b = 3 }, .{ .code = .mul },
    };
    try std.testing.expectEqual(Val.of(0), try fold(a, &stack, &dist, &.{ 0, 1 }, true, &.{}));
    // `0*(1/0 + w)`: an infinite term is not nominal, so the zero keeps it.
    const inf_ops = [_]Op{ .{ .code = .num }, .{ .code = .num, .a = 1 }, .{ .code = .div }, .{ .code = .ident, .a = 1 }, .{ .code = .add }, .{ .code = .num, .a = 1 }, .{ .code = .mul } };
    try std.testing.expect(!(try fold(a, &stack, &inf_ops, &.{ 1, 0 }, true, &.{})).known);
}

test eval {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stack: std.ArrayList(Val) = .empty;
    var s: Scratch = .{};
    try compileAll(a, &s, "agauss(1,2,3)+1");
    try std.testing.expectEqual(2, try eval(a, &stack, s.ops.items, s.consts.items, &.{}, null));
    const Draw = struct {
        fn value(_: @This(), i: usize, f: Fn, args: []const f64) f64 {
            std.debug.assert(i == 3 and f == .agauss and args.len == 3);
            return 41;
        }
    };
    try std.testing.expectEqual(42, try eval(a, &stack, s.ops.items, s.consts.items, &.{}, Draw{}));
    const live = [_]Op{ .{ .code = .live }, .{ .code = .num }, .{ .code = .add } };
    try std.testing.expectEqual(5, try eval(a, &stack, &live, &.{3}, &.{2}, null));
    s = .{};
    try compileAll(a, &s, "x+1");
    try std.testing.expect(std.math.isNan(try eval(a, &stack, s.ops.items, s.consts.items, &.{}, null)));
}

test "postfix subtrees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: Scratch = .{};
    try compileAll(arena.allocator(), &s, "1+2*3");
    const ops = s.ops.items; // 1 2 3 mul add
    try std.testing.expectEqual(5, ops.len);
    try std.testing.expectEqual(0, subtreeStart(ops, 4));
    try std.testing.expectEqual(1, subtreeStart(ops, 3));
    try std.testing.expectEqual(2, subtreeStart(ops, 2));
    // Probes keep their arguments as names; `1n` stays a node, not 1e-9.
    s = .{};
    try compileAll(arena.allocator(), &s, "v(1n,2)+i(vdd)");
    try std.testing.expectEqual(Code.vprobe, s.ops.items[0].code);
    try std.testing.expectEqualStrings("1n", s.names.items[s.ops.items[0].a]);
    try std.testing.expectEqualStrings("vdd", s.names.items[s.ops.items[1].a]);
    s = .{};
    try compileAll(arena.allocator(), &s, "v(out)");
    try std.testing.expectEqual(none, s.ops.items[0].b);
}

test numberLen {
    try std.testing.expectEqual(7, numberLen("2.5e-3k+1"));
    try std.testing.expectEqual(5, numberLen("10meg)"));
    try std.testing.expectEqual(2, numberLen("1e+"));
    try std.testing.expectEqual(3, numberLen("1e5"));
    try std.testing.expectEqual(3, numberLen("1E5"));
    try std.testing.expectEqual(0, numberLen(""));
    try std.testing.expect(isOperator('+') and isOperator('?') and !isOperator(')') and !isOperator(','));
    // Every byte `compile` reads as a binary operator continues a value (#180).
    for ("|&<>=!+-*/%\\^?") |c| try std.testing.expect(isOperator(c));
}

test "% and \\ are numparam operators (#203)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Hand-computed: 10 % 3 = 1, trunc(10 / 3) = 3.
    try std.testing.expectEqual(1, (try testFold(a, "10 % 3")).num);
    try std.testing.expectEqual(3, (try testFold(a, "10 \\ 3")).num);
}

test "unary ! is numparam's logical not (#203)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Hand-computed: !0 + 1 = 2.
    try std.testing.expectEqual(2, (try testFold(a, "!0+1")).num);
}

test {
    _ = expr_ops;
    _ = expr_compile;
    _ = @import("../tests/expr.zig");
}
