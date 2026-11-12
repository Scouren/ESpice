//! The postfix expression tape's rows. In: nothing (definitions only).
//! Out: the opcode and built-in tables every expression stage reads:
//! `Code`, `Fn`, `Op`, the compile `Scratch`, and the built-in name maps.
//! Cites: dev/research/ngspice-syntax.md §2.2 and ngspice xpressn.c for
//! numparam's operators and built-ins.
//!
//! Contents:
//! - `pub const Error = error{ OutOfMemory, ParseError }`
//! - `pub const none: u32`
//! - `pub const Code = enum(u8)`
//! - `pub const Fn = enum(u8)`
//! - `pub const Op = struct`
//! - `pub const Scratch = struct`
//! - `pub const Mark = struct`
//! - `pub fn mark(s: Scratch) Mark`
//! - `pub fn reset(s: *Scratch, m: Mark) void`
//! - `pub const fns: std.StaticStringMap(Fn)`
//! - `pub fn isDistributionName(name: []const u8) bool`
//! - `pub fn isDistribution(f: Fn) bool`
//! - `pub fn bsourceFn(f: Fn) ?Fn`

const std = @import("std");
const assert = std.debug.assert;

/// `ParseError`: malformed expression text, or nesting past `max_depth`.
/// On either error `compile` leaves what it appended in the `Scratch`;
/// roll it back with `Scratch.mark` and `Scratch.reset`. `fold` and `eval`
/// fail only with `OutOfMemory`.
pub const Error = error{ OutOfMemory, ParseError };
/// Absent operand.
pub const none = std.math.maxInt(u32);

/// Postfix opcode; `a`/`b` operands as noted, none for the operators.
pub const Code = enum(u8) {
    /// a: constant pool index.
    num,
    /// A name no scope defines. As compiled, a is its index into
    /// `Scratch.names`; in final ops a = 1 for `l`, `w`, `mult`, 2 for
    /// `time`, 3 for `temper`, 0 otherwise.
    ident,
    /// A swept global parameter kept symbolic: a indexes the live table
    /// (`fold`'s `live`). Only netlist.zig `subst` emits it.
    live,
    /// `v(p[,n])`: a, b are the nets (names before `subst`), `none` if absent.
    vprobe,
    /// `i(device)`: a is the device name (a name before `subst`, its
    /// flattened `Netlist.pool` index after).
    iprobe,
    neg,
    not,
    add,
    sub,
    mul,
    div,
    /// `a % b`: a - b·trunc(a/b), as numparam's `%` (ngspice-syntax.md §2.2).
    mod,
    /// `a \ b`: trunc(|a/b|), numparam's integer division.
    idiv,
    pow,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    @"and",
    @"or",
    /// a: `Fn`, b: argument count.
    call,
    /// A call to a function outside `Fn`, as compiled: a is its name (an
    /// index into `Scratch.names`), b the argument count. reader_subst.zig
    /// `inline_` expands a `.func` it names and refuses any other, so
    /// final ops never hold one.
    ucall,
};

/// Built-in functions; a name the tables do not know compiles to `ucall`.
/// The statistical distributions `agauss`, `gauss`, `unif`, `aunif` and
/// numparam's `limit(nom, var)` fold to their nominal, the first argument; a
/// Monte Carlo trial draws them instead (`eval`). `pow` is C's pow, as
/// numparam's (xpressn.c XFU_POW), and `pwr` is |a|^b (XFU_PWR). The B
/// parser reads its own `pow` as |a|^b and its `pwr` as sign(a)·|a|^b
/// (`bpwr`), which `bsourceFn` maps to. `arctan` is numparam's name for
/// `atan`, which the B parser lacks. `table(x, d, x1, y1, ...)`, an even
/// argument count, is the smoothed transfer of an E/G TABLE card (`TABLE`
/// in `fns`); `table(x, x1, y1, ...)`, an odd count, is the B-source
/// `pwl`, which ngspice runs as ptfuncs.c PTpwl. Both run only on the
/// B-source tape (models/bsource.va opcodes 37, 38). `ddt(x)` is the
/// B-source time derivative (inpptree.c:177), which never folds
/// (models/bsource.va opcode 40).
pub const Fn = enum(u8) { sqrt, abs, min, max, pow, pwr, exp, ln, log, log10, sin, cos, tan, atan, floor, ceil, ternary, tanh, sqr, int, nint, sgn, sinh, cosh, asin, acos, asinh, acosh, atanh, agauss, gauss, unif, aunif, limit, table, ddt, bpwr, arctan };

/// One postfix op.
pub const Op = struct { code: Code, a: u32 = 0, b: u32 = 0 };

comptime {
    // A row of the postfix tape: a 1-byte opcode and two u32 operands.
    assert(@sizeOf(Code) == 1);
    assert(@sizeOf(Fn) == 1);
    assert(@sizeOf(Op) == 12);
}

/// Compile output before parameters are spliced in.
pub const Scratch = struct {
    ops: std.ArrayList(Op) = .empty,
    /// The constant pool `.num` operands index.
    consts: std.ArrayList(f64) = .empty,
    /// Slices of the compiled text that `.ident`, probe and `.ucall`
    /// operands index.
    names: std.ArrayList([]const u8) = .empty,

    /// Table lengths to roll back to.
    pub const Mark = struct { ops: usize, consts: usize, names: usize };

    /// The current table lengths, for a later `reset`.
    pub fn mark(s: Scratch) Mark {
        return .{ .ops = s.ops.items.len, .consts = s.consts.items.len, .names = s.names.items.len };
    }

    /// Drops everything appended since `m`.
    pub fn reset(s: *Scratch, m: Mark) void {
        assert(m.ops <= s.ops.items.len);
        assert(m.names <= s.names.items.len);
        s.ops.shrinkRetainingCapacity(m.ops);
        s.consts.shrinkRetainingCapacity(m.consts);
        s.names.shrinkRetainingCapacity(m.names);
    }
};

/// Built-in names to their `Fn`: each one ngspice-44.2's numparam or B
/// parser reads, but `TABLE`. Deck text reaches the compiler lower case
/// (physical_lines.zig `normalize`), so no deck spells `TABLE`: only
/// reader_behavioural.zig writes it, for an E/G TABLE card, and a deck's
/// own `table(` is an unknown function, as ngspice-44.2 reads it.
pub const fns = std.StaticStringMap(Fn).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "abs", .abs },       .{ "min", .min },       .{ "max", .max },
    .{ "pow", .pow },     .{ "pwr", .pwr },       .{ "exp", .exp },       .{ "ln", .ln },
    .{ "log", .log },     .{ "log10", .log10 },   .{ "sin", .sin },       .{ "cos", .cos },
    .{ "tan", .tan },     .{ "atan", .atan },     .{ "floor", .floor },   .{ "ceil", .ceil },
    .{ "tanh", .tanh },   .{ "agauss", .agauss }, .{ "gauss", .gauss },   .{ "unif", .unif },
    .{ "aunif", .aunif }, .{ "limit", .limit },   .{ "TABLE", .table },
    // numparam's other built-ins (ngspice-syntax.md §2.2, xpressn.c fmathS).
      .{ "sqr", .sqr },
    .{ "int", .int },     .{ "nint", .nint },     .{ "sgn", .sgn },       .{ "sinh", .sinh },
    .{ "cosh", .cosh },   .{ "asin", .asin },     .{ "acos", .acos },     .{ "asinh", .asinh },
    .{ "acosh", .acosh }, .{ "atanh", .atanh },   .{ "arctan", .arctan }, .{ "ternary_fcn", .ternary },
});

/// True when `name` (lower case) calls a function a Monte Carlo trial draws.
pub fn isDistributionName(name: []const u8) bool {
    const f = fns.get(name) orelse return false;
    return isDistribution(f);
}

/// True for the functions a Monte Carlo trial draws.
pub fn isDistribution(f: Fn) bool {
    return switch (f) {
        .agauss, .gauss, .unif, .aunif, .limit => true,
        else => false,
    };
}

/// What the B parser means by the name numparam reads as `f`: its `pow`
/// is ptfuncs.c PTpower's |a|^b, numparam's `pwr`, and its `pwr` is
/// PTpwr's sign(a)·|a|^b. ngspice-44.2 reads them so in a B card, an E or
/// G VALUE and the `.func` bodies they call, and numparam's in a `.param`
/// even where a B card reads it (src/tests/expressions.zig, measured).
/// Null for numparam's `sqr`, `int` and `arctan`, which the B parser
/// lacks: ngspice-44.2 stops on each there, constant or not, "no such
/// function" (src/tests/unknown_functions.zig).
pub fn bsourceFn(f: Fn) ?Fn {
    return switch (f) {
        .pow => .pwr,
        .pwr => .bpwr,
        .sqr, .int, .arctan => null,
        else => f,
    };
}

test "every built-in name a deck can spell is one ngspice-44.2 reads" {
    // Oracle: numparam's fmathS (xpressn.c:91-95) and the B parser's funcs
    // (inpptree.c:138-177), as src/tests/unknown_functions.zig copies them
    // from ngspice's source. A name only ESPice reads runs a deck ngspice
    // stops on. Red before: `table` and `ternary` were names here, which
    // ngspice-44.2 refuses ("no such function", "Undefined parameter").
    const ngspice = std.StaticStringMap(void).initComptime(.{
        .{"sqr"},   .{"sqrt"}, .{"sin"},    .{"cos"},  .{"exp"},         .{"ln"},    .{"arctan"}, .{"abs"},
        .{"pow"},   .{"pwr"},  .{"max"},    .{"min"},  .{"int"},         .{"log"},   .{"log10"},  .{"sinh"},
        .{"cosh"},  .{"tanh"}, .{"agauss"}, .{"sgn"},  .{"ternary_fcn"}, .{"gauss"}, .{"unif"},   .{"aunif"},
        .{"limit"}, .{"ceil"}, .{"floor"},  .{"asin"}, .{"acos"},        .{"atan"},  .{"asinh"},  .{"acosh"},
        .{"atanh"}, .{"tan"},  .{"nint"},   .{"u"},    .{"uramp"},       .{"u2"},    .{"pwl"},    .{"eq0"},
        .{"ne0"},   .{"gt0"},  .{"lt0"},    .{"ge0"},  .{"le0"},         .{"ddt"},
    });
    const gpa = std.testing.allocator;
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    for (fns.keys()) |name| if (!ngspice.has(name)) try extra.print(gpa, "{s}\n", .{name});
    try std.testing.expectEqualStrings("TABLE\n", extra.items);
}
