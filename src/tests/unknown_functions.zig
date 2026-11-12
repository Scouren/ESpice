//! Function names, both ways. A call to a function no table and no
//! `.func` defines refuses at every site a deck can write one, and every
//! function ngspice defines evaluates or is a named gap.
//!
//! Oracle for the refusals: ngspice-44.2 (`ngspice -b`) on each site deck
//! below. Every value, `.param` (read or not) and model site exits 1 with
//! "Undefined parameter [zork]", every B and E site with "no such
//! function 'zork'", and each `abs` twin runs; a `.meas` PARAM= prints
//! "Undefined parameter" and marks its result failed. Here each site
//! refuses with `UnsupportedCard`, logged with the function and the card
//! (reader_subst.zig `inline_`), since an unsupported form fails and never
//! skips; its twin calling `abs` runs, so the refusal is the name's and
//! not the site's syntax. Red before (the prebuilt espice of 2026-11-10):
//! no site refused with `UnsupportedCard`; `.param q={zork(3)+1}` read by
//! `vp3 p3 0 {q}` solved v(p3) = 0, and so did `vp3 p3 0 {v(a)}`.
//!
//! Oracle for the names: ngspice's own tables, copied by name from its
//! source (git a9da7bca6): numparam's `fmathS` (xpressn.c:91-95), which
//! every `.param` and `{}` value reads, and the B-source parser's `funcs`
//! (inpptree.c:138-177; "-" is unary minus, no name). A name missing here,
//! or a gap that starts evaluating, fails the name-list comparison. The
//! numparam names the B parser lacks refuse in a B source, as ngspice-44.2
//! stops (or, for a distribution on a probe, reads 0) there.
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;

/// One kind of site that calls a function: its deck lines, `FN` where the
/// function's name goes.
const Site = struct { name: []const u8, lines: []const u8 };

/// Every site kind a function call can sit in.
const sites = [_]Site{
    .{ .name = ".param read", .lines = ".param p={FN(2)}\nr1 a 0 {p}\n" },
    .{ .name = ".param unread", .lines = ".param p={FN(2)}\n" },
    .{ .name = "instance value", .lines = "r1 a 0 {FN(2)}\n" },
    .{ .name = "subcircuit instance value", .lines = ".subckt s n\nr1 n 0 {FN(2)}\n.ends\nx1 a s\n" },
    .{ .name = "source value", .lines = "v2 b 0 {FN(2)}\nr2 b 0 1k\n" },
    .{ .name = "model value", .lines = "r1 a k 1k\nd1 k 0 dm\n.model dm d is={FN(1e-14)}\n" },
    .{ .name = "B v=", .lines = "b1 b 0 v=FN(v(a))\nr2 b 0 1k\n" },
    .{ .name = "B i=", .lines = "b1 b 0 i=FN(v(a))\nr2 b 0 1k\n" },
    .{ .name = "E value=", .lines = "e1 b 0 value={FN(v(a))}\nr2 b 0 1k\n" },
    .{ .name = "E vol=", .lines = "e1 b 0 vol='FN(v(a))'\nr2 b 0 1k\n" },
    .{ .name = ".meas param", .lines = ".tran 1n 2n\n.meas tran m1 param='FN(2)'\n" },
};

/// One ngspice built-in: its name, its call's arguments, and why ESPice
/// does not evaluate it (null when it does).
const Builtin = struct { name: []const u8, args: []const u8 = "0.5", gap: ?[]const u8 = null };

/// numparam's `fmathS`, in its order, each called in a `.param`.
const numparam = [_]Builtin{
    .{ .name = "sqr" },                                                                             .{ .name = "sqrt" },                        .{ .name = "sin" },
    .{ .name = "cos" },                                                                             .{ .name = "exp" },                         .{ .name = "ln" },
    .{ .name = "arctan" },                                                                          .{ .name = "abs" },                         .{ .name = "pow", .args = "2, 0.5" },
    .{ .name = "pwr", .args = "2, 0.5" },                                                           .{ .name = "max", .args = "0.5, 2" },       .{ .name = "min", .args = "0.5, 2" },
    .{ .name = "int" },                                                                             .{ .name = "log" },                         .{ .name = "log10" },
    .{ .name = "sinh" },                                                                            .{ .name = "cosh" },                        .{ .name = "tanh" },
    .{ .name = "ternary_fcn", .args = "1, 2, 3" },                                                  .{ .name = "agauss", .args = "1, 0.1, 3" }, .{ .name = "sgn" },
    .{ .name = "gauss", .args = "1, 0.1, 3" },                                                      .{ .name = "unif", .args = "1, 0.1" },      .{ .name = "aunif", .args = "1, 0.1" },
    .{ .name = "limit", .args = "1, 0.1" },                                                         .{ .name = "ceil" },                        .{ .name = "floor" },
    .{ .name = "asin" },                                                                            .{ .name = "acos" },                        .{ .name = "atan" },
    .{ .name = "asinh" },                                                                           .{ .name = "acosh", .args = "1.5" },        .{ .name = "atanh" },
    .{ .name = "tan" },                                                                             .{ .name = "nint" },                        .{ .name = "vec", .gap = "reads a .control vector by name; ESPice runs no .control script" },
    .{ .name = "var", .gap = "reads a .control variable by name; ESPice runs no .control script" },
};

/// The B-source parser's `funcs`, in its order, each called on a probe so
/// the tape runs it. Each argument is 0.25 at Newton's all-zero start and
/// 0.5 at the solution, inside every function's domain.
const bsource = [_]Builtin{
    .{ .name = "abs", .args = "0.25+0.25*v(a)" },
    .{ .name = "acos", .args = "0.25+0.25*v(a)" },
    .{ .name = "acosh", .args = "1.25+0.25*v(a)" },
    .{ .name = "asin", .args = "0.25+0.25*v(a)" },
    .{ .name = "asinh", .args = "0.25+0.25*v(a)" },
    .{ .name = "atan", .args = "0.25+0.25*v(a)" },
    .{ .name = "atanh", .args = "0.25+0.25*v(a)" },
    .{ .name = "cos", .args = "0.25+0.25*v(a)" },
    .{ .name = "cosh", .args = "0.25+0.25*v(a)" },
    .{ .name = "exp", .args = "0.25+0.25*v(a)" },
    .{ .name = "ln", .args = "0.25+0.25*v(a)" },
    .{ .name = "log", .args = "0.25+0.25*v(a)" },
    .{ .name = "log10", .args = "0.25+0.25*v(a)" },
    .{ .name = "sgn", .args = "0.25+0.25*v(a)" },
    .{ .name = "sin", .args = "0.25+0.25*v(a)" },
    .{ .name = "sinh", .args = "0.25+0.25*v(a)" },
    .{ .name = "sqrt", .args = "0.25+0.25*v(a)" },
    .{ .name = "tan", .args = "0.25+0.25*v(a)" },
    .{ .name = "tanh", .args = "0.25+0.25*v(a)" },
    .{ .name = "u", .args = "0.25+0.25*v(a)" },
    .{ .name = "uramp", .args = "0.25+0.25*v(a)" },
    .{ .name = "ceil", .args = "0.25+0.25*v(a)" },
    .{ .name = "floor", .args = "0.25+0.25*v(a)" },
    .{ .name = "nint", .args = "0.25+0.25*v(a)" },
    .{ .name = "u2", .args = "0.25+0.25*v(a)" },
    .{ .name = "pwl", .args = "v(a), 0, 0, 2, 2" },
    .{ .name = "pwl_derivative", .args = "v(a), 0, 0, 2, 2", .gap = "pwl's slope, which the B parser builds as pwl's derivative (inpptree.c:565); ngspice-44.2 cannot run it in a deck either (\"bad node type 10\")" },
    .{ .name = "eq0", .args = "0.25+0.25*v(a)" },
    .{ .name = "ne0", .args = "0.25+0.25*v(a)" },
    .{ .name = "gt0", .args = "0.25+0.25*v(a)" },
    .{ .name = "lt0", .args = "0.25+0.25*v(a)" },
    .{ .name = "ge0", .args = "0.25+0.25*v(a)" },
    .{ .name = "le0", .args = "0.25+0.25*v(a)" },
    .{ .name = "pow", .args = "0.25+0.25*v(a), 0.5" },
    .{ .name = "pwr", .args = "0.25+0.25*v(a), 0.5" },
    .{ .name = "min", .args = "0.25+0.25*v(a), 2" },
    .{ .name = "max", .args = "0.25+0.25*v(a), 2" },
    .{ .name = "ddt", .args = "v(a)" },
};

// ---- private ----

/// The error `source` stops with at parse or at run; null when it runs.
fn outcome(source: []const u8) ?anyerror {
    const p = api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "unknown_functions.cir" } } }) catch |err| return err;
    defer p.deinit();
    p.run_all() catch |err| return err;
    return null;
}

/// Appends to `refused` the name, after `prefix`, of each row of `table`
/// whose call in `template` (`CALL` where it goes) does not run, and to
/// `gaps` each row's that is a named gap.
fn walk(a: std.mem.Allocator, prefix: []const u8, table: []const Builtin, template: []const u8, refused: *std.ArrayList(u8), gaps: *std.ArrayList(u8)) !void {
    for (table) |row| {
        const name = try a.print("{s} {s}\n", .{ prefix, row.name });
        if (row.gap != null) try gaps.appendSlice(a, name);
        const call = try a.print("{s}({s})", .{ row.name, row.args });
        if (outcome(try std.mem.replaceOwned(u8, a, template, "CALL", call))) |err| {
            if (row.gap == null) std.debug.print("{s}: {s}\n", .{ call, @errorName(err) });
            try refused.appendSlice(a, name);
        }
    }
}

test "a .param calling an unknown function refuses the deck, and its abs twin solves v(p3) = 4" {
    const tail = "vp3 p3 0 {q}\nr3 p3 0 1k\n.op\n.end\n";
    try t.expectEqual(@as(?anyerror, error.UnsupportedCard), outcome("zork\n.param q={zork(3)+1}\n" ++ tail));
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = "abs\n.param q={abs(3)+1}\n" ++ tail, .origin = "unknown_functions.cir" } } });
    defer p.deinit();
    try p.run_all();
    try t.expectEqual(@as(f64, 4), try deck.at(try deck.resultOf(p, .op), 0, "v(p3)"));
}

test "every site kind refuses a call to an unknown function, and runs its abs twin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: std.ArrayList(u8) = .empty;
    var refused: std.ArrayList(u8) = .empty;
    var ran: std.ArrayList(u8) = .empty;
    for (sites) |site| {
        const name = try a.print("{s}\n", .{site.name});
        try all.appendSlice(a, name);
        const text = try a.print("FN site\nv1 a 0 dc 1\nr0 a 0 1k\n{s}.op\n.end\n", .{site.lines});
        const unknown = outcome(try std.mem.replaceOwned(u8, a, text, "FN", "zork"));
        const refuses = if (unknown) |err| err == error.UnsupportedCard else false;
        if (refuses) try refused.appendSlice(a, name) else std.debug.print("zork at {s}  {s}\n", .{ name, if (unknown) |err| @errorName(err) else "ran" });
        const twin = outcome(try std.mem.replaceOwned(u8, a, text, "FN", "abs"));
        if (twin) |err| std.debug.print("abs at {s}  {s}\n", .{ name, @errorName(err) }) else try ran.appendSlice(a, name);
    }
    try t.expectEqualStrings(all.items, refused.items);
    try t.expectEqualStrings(all.items, ran.items);
}

test "a source value that reads the circuit refuses, where it held 0 (ngspice-44.2 stops on it)" {
    try t.expectEqual(@as(?anyerror, error.UnresolvedParameter), outcome("probe\nv1 a 0 dc 1\nr1 a 0 1k\nvp3 p3 0 {v(a)}\nr3 p3 0 1k\n.op\n.end\n"));
}

test "a .param reading a name nothing defines stops the deck, read or not, and so does a gain" {
    // ngspice-44.2 -b: numparam evaluates each .param where it stands, so
    // an unread `.param p={NAME}` stops it, "Undefined parameter [zork]",
    // for each name below (a probe: "[v]"); an E, G, F or H gain {x} stops
    // it too. A forward reference runs (v(p) = 3). temper and hertz/time:
    // src/tests/temper.zig. Red before: the 2026-11-10 binary ran each
    // (the E gain as 0, the F gain as 1); the tree kept an unread .param's
    // text and read an E or G gain that did not fold as 0.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "name\nv1 a 0 1\nr1 a 0 1k\nro o 0 1k\n";
    var got: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        ".param p={zork}",
        ".param p={pi}",
        ".param p={temp}",
        ".param p={w*2}",
        ".param p={v(a)}",
        "e1 o 0 a 0 {x}",
        "g1 0 o a 0 {x}",
        "f1 0 o v1 {x}",
        "h1 o 0 v1 {x}",
    }) |card| {
        const err = outcome(try a.print("{s}{s}\n.op\n.end\n", .{ head, card }));
        try got.print(a, "{s}: {s}\n", .{ card, if (err) |e| @errorName(e) else "ran" });
    }
    try t.expectEqualStrings(
        \\.param p={zork}: UnsupportedCard
        \\.param p={pi}: UnsupportedCard
        \\.param p={temp}: UnsupportedCard
        \\.param p={w*2}: UnsupportedCard
        \\.param p={v(a)}: UnsupportedCard
        \\e1 o 0 a 0 {x}: UnresolvedParameter
        \\g1 0 o a 0 {x}: UnresolvedParameter
        \\f1 0 o v1 {x}: UnresolvedParameter
        \\h1 o 0 v1 {x}: UnresolvedParameter
        \\
    , got.items);
    const p = try deck.solve("forward\n.param p={q+1}\n.param q=2\nvp p 0 {p}\nrp p 0 1k\n.op\n.end\n");
    defer p.deinit();
    try t.expectEqual(@as(f64, 3), try deck.at(try deck.resultOf(p, .op), 0, "v(p)"));
}

test "every function in ngspice's numparam and B-source tables evaluates, or is a named gap" {
    // Red before (the prebuilt espice of 2026-11-10): numparam vec and var
    // ran, read as 0 by the source; B sgn, cosh, pwr, sinh, asin, acos,
    // asinh, acosh and atanh were refused.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var refused: std.ArrayList(u8) = .empty;
    var gaps: std.ArrayList(u8) = .empty;
    try walk(a, "numparam", &numparam, "builtin\n.param p={CALL}\nvp p 0 {p}\nrp p 0 1k\n.op\n.end\n", &refused, &gaps);
    try walk(a, "B", &bsource, "builtin\nv1 a 0 dc 1\nr1 a 0 1k\nb1 o 0 v=CALL\nro o 0 1k\n.op\n.end\n", &refused, &gaps);
    try t.expectEqualStrings(gaps.items, refused.items);
}

test "a B source calling a numparam-only function refuses, but for ternary_fcn" {
    // ngspice-44.2 on `b1 o 0 v=NAME(v(a)*0+ARGS)` for each numparam name
    // its B parser lacks: sqr, arctan, int, vec and var stop it with "no
    // such function"; agauss, gauss, unif, aunif and limit read 0, a number
    // no deck means; ternary_fcn runs (2 here). Each refuses here but
    // ternary_fcn. sqr, int and arctan stop ngspice on constants too (`v=sqr(2)`,
    // E `value={int(2.5)}`), so they refuse by name in any B, E or G text
    // (expr_ops.zig `bsourceFn`). Red before: arctan ran on the tape (the
    // 2026-11-10 binary too), and the constants folded (sqr(2) = 4 there).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ran: std.ArrayList(u8) = .empty;
    for (numparam) |row| {
        const shared = for (bsource) |b| {
            if (std.mem.eql(u8, b.name, row.name)) break true;
        } else false;
        if (shared) continue;
        const text = try a.print("numparam only\nv1 a 0 dc 0.5\nr1 a 0 1k\nb1 o 0 v={s}(v(a)*0+{s})\nro o 0 1k\n.op\n.end\n", .{ row.name, row.args });
        if (outcome(text) == null) try ran.appendSlice(a, try a.print("{s}\n", .{row.name}));
    }
    try t.expectEqualStrings("ternary_fcn\n", ran.items);
    for ([_][]const u8{ "b1 o 0 v=sqr(2)", "b1 o 0 v=arctan(1)", "e1 o 0 value={int(2.5)}" }) |card|
        try t.expectEqual(@as(?anyerror, error.UnsupportedCard), outcome(try a.print("constant\n{s}\nro o 0 1k\n.op\n.end\n", .{card})));
}
