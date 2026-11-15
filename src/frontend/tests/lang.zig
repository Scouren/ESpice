//! Tests of the ESPice language's lexer, numbers and parser. Oracles:
//! values derived by hand from language.md's prefix and unit tables and
//! its three safety rules; the grammar of "Files and statements" for the
//! shapes; diagnostic codes pinned, never message text.

const std = @import("std");
const testing = std.testing;
const number = @import("../lang/number.zig");
const lexer = @import("../lang/lexer.zig");
const parse = @import("../lang/parse.zig");
const ast = @import("../lang/ast.zig");
const diag = @import("../lang/diag.zig");
const Code = diag.Code;

// ---- private ----

/// The codes of `src`'s parse rows, in order (caller frees).
fn codes(src: []const u8) ![]Code {
    const gpa = testing.allocator;
    var diags: diag.Diags = .{ .gpa = gpa };
    defer diags.rows.deinit(gpa);
    var tree = try parse.parse(gpa, src, &diags);
    defer tree.deinit(gpa);
    const out = try gpa.alloc(Code, diags.rows.items.len);
    for (out, diags.rows.items) |*o, d| o.* = d.code;
    return out;
}

/// The operand of `node` on the left, `n` binary levels down.
fn sideOf(tree: *const ast.Ast, node: ast.Index, n: usize) ast.Index {
    var x = tree.node(node).lhs;
    for (0..n) |_| x = tree.node(x).lhs;
    return x;
}

test "numbers: value, prefix and unit as the spec's tables give them" {
    const Case = struct { []const u8, f64, ?number.Unit };
    for ([_]Case{
        .{ "1.8V", 1.8, .V },       .{ "10ns", 10e-9, .s },   .{ "5fF", 5e-15, .F }, .{ "1MHz", 1e6, .Hz },
        .{ "2.2kOhm", 2200, .Ohm }, .{ "150nm", 150e-9, .m }, .{ "27C", 27, .C },    .{ "90deg", 90, .deg },
        .{ "5%", 0.05, .pct },      .{ "1m", 1e-3, null },    .{ "1mm", 1e-3, .m },  .{ "1e-3", 1e-3, null },
        .{ "2.5e3Hz", 2500, .Hz },  .{ "3GHz", 3e9, .Hz },    .{ "1T", 1e12, null }, .{ "4a", 4e-18, null },
        .{ "1uA", 1e-6, .A },       .{ "1S", 1, .S },         .{ "1s", 1, .s },      .{ "2H", 2, .H },
        .{ "1MOhm", 1e6, .Ohm },    .{ "7", 7, null },
    }) |c| {
        const r = number.read(c[0]);
        try testing.expectEqual(@as(?Code, null), r.code);
        try testing.expectApproxEqRel(c[1], r.number.?.value, 1e-15);
        try testing.expectEqual(c[2], r.number.?.unit);
    }
}

test "numbers: the three safety rules and the other refusals" {
    const Case = struct { []const u8, Code };
    for ([_]Case{
        .{ "1M", .bare_mega },    .{ "1meg", .spice_suffix },  .{ "1MEG", .spice_suffix }, .{ "2mil", .spice_suffix },
        .{ "1x", .spice_suffix }, .{ "1K", .spice_suffix },    .{ "1U", .spice_suffix },   .{ "1N", .spice_suffix },
        .{ "1P", .spice_suffix }, .{ "1Q", .unknown_unit },    .{ "1kq", .unknown_unit },  .{ "5k%", .percent_prefix },
        .{ "1e", .unknown_unit }, .{ "1m%", .percent_prefix },
    }) |c| {
        const r = number.read(c[0]);
        try testing.expectEqual(@as(?Code, c[1]), r.code);
        try testing.expectEqual(@as(?number.Number, null), r.number);
    }
    // `1F` is one farad, read with a warning.
    const f = number.read("1F");
    try testing.expectEqual(@as(?Code, .farad_warning), f.code);
    try testing.expectEqual(@as(f64, 1), f.number.?.value);
    try testing.expectEqual(diag.Severity.warn, diag.info(.farad_warning).severity);
}

test "numbers: the legacy spelling keeps the mantissa and maps the prefix" {
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "5fF", "5f" },  .{ "1MHz", "1meg" },    .{ "1.8V", "1.8" }, .{ "2G", "2g" },          .{ "3THz", "3t" },
        .{ "5%", "5e-2" }, .{ "1.5e3%", "1.5e1" }, .{ "27C", "27" },   .{ "4.70kOhm", "4.70k" }, .{ "1e-3", "1e-3" },
        .{ "10u", "10u" }, .{ "2.5mm", "2.5m" },
    }) |c| {
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try number.writeLegacy(number.read(c[0]).number.?, &w);
        try testing.expectEqualStrings(c[1], w.buffered());
    }
}

test "lexer: names, directives, numbers, operators and comments" {
    var diags: diag.Diags = .{ .gpa = testing.allocator };
    defer diags.rows.deinit(testing.allocator);
    const src = ".param a!=b** 2 // c\nvdd! \"net<3>\" x1.q &&";
    var toks = try lexer.lex(testing.allocator, src, &diags);
    defer toks.deinit(testing.allocator);
    const T = lexer.Tag;
    try testing.expectEqualSlices(T, &.{ .directive, .word, .bang_eq, .word, .star_star, .number, .newline, .word, .string, .word, .amp_amp, .eof }, toks.items(.tag));
    try testing.expectEqual(0, diags.rows.items.len);
    try testing.expectEqualStrings("vdd!", src[toks.items(.start)[7]..lexer.tokenEnd(src, .word, toks.items(.start)[7])]);
}

test "lexer: every legacy operator and stray character is a row, and lexing goes on" {
    const got = try codes(".espice 1\n.param a = 2^3 + 'x' <> b \\ c ; d\n");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Code, &.{ .legacy_operator, .legacy_operator, .legacy_operator, .legacy_operator, .legacy_operator, .unknown_char }, got[0..6]);
}

test "parser: the spec's opening example parses with no row" {
    const src =
        \\.espice 1
        \\.title "Inverter delay across process"
        \\.lib "pdk.lib" tt                     // a legacy library, read as before
        \\.option reltol=1e-4 temp=27C
        \\.param vdd = 1.8V
        \\.subckt inv (in out vdd vss) wn=420nm wp=1um {
        \\    Mn (d=out g=in s=vss b=vss) nch w=wn l=150nm
        \\}
        \\Vin (in 0)         vsource   pulse(0, vdd, td=1ns, tr=20ps,
        \\                                   tf=20ps, pw=2ns, per=4ns)
        \\.tran stop=8ns step=10ps sweep monte(200)
        \\.meas tran tphl = cross(v(out), vdd/2, fall=1) - cross(v(in), vdd/2, rise=1)
        \\.model nch bsim4 type=n {
        \\    vth0 = 0.45
        \\}
    ;
    var diags: diag.Diags = .{ .gpa = testing.allocator };
    defer diags.rows.deinit(testing.allocator);
    var tree = try parse.parse(testing.allocator, src, &diags);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(0, diags.rows.items.len);
    const stmts = tree.span(tree.root);
    try testing.expectEqual(9, stmts.len);
    // The subckt owns one statement; the model's block holds settings.
    const sub = tree.statement(stmts[4]);
    try testing.expectEqual(1, sub.block.end - sub.block.start);
    try testing.expectEqual(ast.Tag.instance, tree.tag(tree.span(sub.block)[0]));
    const tran = tree.statement(stmts[6]);
    try testing.expect(tran.sweep != ast.none);
    try testing.expectEqual(2, tran.items.end - tran.items.start);
    const model = tree.statement(stmts[8]);
    try testing.expectEqual(4, model.items.end - model.items.start);
    // `.meas tran tphl = a - b`: one subject, one setting whose value is a difference.
    const meas = tree.span(tree.statement(stmts[7]).items);
    try testing.expectEqual(ast.Tag.setting, tree.tag(meas[1]));
    try testing.expectEqual(ast.Tag.binary, tree.tag(tree.node(meas[1]).rhs));
}

test "parser: precedence, ** binds right and over a prefix, calls need no blank before (" {
    const src = ".espice 1\n.param x = -2**3**2 + a*b % c < d == e && f || g ? h : i\n.subckt s (a b) {\n}\n";
    var diags: diag.Diags = .{ .gpa = testing.allocator };
    defer diags.rows.deinit(testing.allocator);
    var tree = try parse.parse(testing.allocator, src, &diags);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(0, diags.rows.items.len);
    const top = tree.node(tree.span(tree.statement(tree.span(tree.root)[0]).items)[0]).rhs;
    try testing.expectEqual(ast.Tag.ternary, tree.tag(top));
    // `.subckt s (a b)`: the blank makes `(a b)` a port list, not a call.
    const sub = tree.span(tree.statement(tree.span(tree.root)[1]).items);
    try testing.expectEqual(ast.Tag.word, tree.tag(sub[0]));
    try testing.expectEqual(ast.Tag.group, tree.tag(sub[1]));
    // The unary minus holds `2**(3**2)`.
    const lhs = sideOf(&tree, top, 5);
    try testing.expectEqual(ast.Tag.unary, tree.tag(lhs));
    const pow = tree.node(lhs).lhs;
    try testing.expectEqual(lexer.Tag.star_star, tree.tokenTag(tree.node(pow).main));
    try testing.expectEqual(lexer.Tag.star_star, tree.tokenTag(tree.node(tree.node(pow).rhs).main));
}

test "parser: every problem is a row and the next statement is read" {
    const got = try codes(
        \\.espice 1
        \\R1 (a b) resistor 1k )
        \\.param x = f(a=1, 2)
        \\}
        \\.if 1 { .param y = 1
        \\}
        \\R2 (a b) resistor (1k
        \\
    );
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Code, &.{ .unexpected, .positional_after_key, .stray_close, .block_line, .stray_close, .unclosed }, got);
}

test "parser: a bad header is a row" {
    const got = try codes(".espice 2\n.param a = 1\n");
    defer testing.allocator.free(got);
    try testing.expectEqual(Code.bad_header, got[0]);
}

test "parser: nesting past the cap is a row, never a stack overflow" {
    const depth = 10_000;
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, ".espice 1\n.param a = ");
    try src.appendNTimes(gpa, '(', depth);
    try src.append(gpa, '1');
    try src.appendNTimes(gpa, ')', depth);
    try src.appendSlice(gpa, "\n.param b = ");
    for (0..depth) |_| try src.appendSlice(gpa, "-");
    try src.appendSlice(gpa, "1\n.param c = 2\n");
    const got = try codes(src.items);
    defer gpa.free(got);
    try testing.expectEqualSlices(Code, &.{ .too_deep, .too_deep }, got);
}

test "diagnostics.md lists exactly the catalogue's codes, in order, with their severities" {
    // Oracle: the page, read at test time; name lists compared, never counts.
    const gpa = testing.allocator;
    const page = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/using/diagnostics.md", gpa, .limited(1 << 20));
    defer gpa.free(page);
    const start = std.mem.indexOf(u8, page, "## The ESPice language") orelse return error.NoSection;
    const end = std.mem.indexOfPos(u8, page, start + 1, "\n## ") orelse page.len;
    var listed: std.ArrayList(u8) = .empty;
    defer listed.deinit(gpa);
    var lines = std.mem.splitScalar(u8, page[start..end], '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "| `")) {
        try listed.appendSlice(gpa, line[3..8]);
        try listed.append(gpa, ' ');
    };
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    for (std.enums.values(Code)) |c| try want.print(gpa, "{c}{d} ", .{ @as(u8, if (diag.info(c).severity == .err) 'E' else 'W'), @backingInt(c) });
    try testing.expectEqualStrings(want.items, listed.items);
}
