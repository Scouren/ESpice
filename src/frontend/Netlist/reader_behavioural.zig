//! Behavioural E/F/G/H forms: VALUE, POLY, TABLE, LAPLACE and the rest
//! rewritten as B-source text, and the data-file path a model names.
//! Cites: ngspice inpcom.c (E/G keywords, inp_bsource_compat); XSPICE
//! spice2poly; HSPICE [SA].
//!
//! Contents:
//! - `pub fn behaviouralCard(r: *Reader, line: []const u8, head: []const u8, letter: u8, f_in: F, frame: *const Frame, form: Form) Error!void`
//! - `pub fn wrapped(arena: Allocator, pre: []const u8, text: []const u8, post: []const u8) Error!std.ArrayList(u8)`
//! - `pub fn exprRest(r: *Reader, f: *F, frame: *const Frame) Error![]const u8`
//! - `pub fn unbraced(r: *Reader, line: []const u8, text: []const u8, frame: *const Frame) Error![]const u8`
//! - `pub fn word(f: *F) Error![]const u8`
//! - `pub fn numberAt(r: *Reader, t: []const u8, f: *F, frame: *const Frame) Error!f64`
//! - `pub fn controlText(r: *Reader, w: *std.ArrayList(u8), f: *F, by_current: bool) Error!void`
//! - `pub fn tablePoints(r: *Reader, f: *F, frame: *const Frame) Error![]const f64`
//! - `pub fn polyText(r: *Reader, w: *std.ArrayList(u8), f: *F, frame: *const Frame, by_current: bool) Error!void`

const std = @import("std");
const Ast = @import("../Ast.zig");
const Allocator = std.mem.Allocator;
const source = @import("../source.zig");
const expr = @import("../Parse/expr.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const sweep_points = @import("sweep_points.zig");
const reader_values = @import("reader_values.zig");
const reader_diag = @import("reader_diag.zig");
const reader_card = @import("reader_card.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const Kv = card_rows.Kv;
const isGroundName = netlist_view.isGroundName;
const Form = card_table.Form;
const kvIndex = card_table.kvIndex;
const nextPower = sweep_points.nextPower;
const Frame = reader_frame.Frame;

/// An E/F/G/H card in a behavioural form, `f` just past the name.
/// Value, POLY and TABLE forms become a B card over one expression
/// (`i=` or `v=`); LAPLACE, POLE and DELAY keep their letter and
/// carry the form in `laplace=` or `pole=<numerator count>`, or
/// `td=`. A POLE side is a constant and (re, im) root pairs, so both
/// counts are odd. Anything else is refused, HSPICE's PWL(1), VCR
/// and VCCAP among them: plain ngspice-44.2 stops on PWL(1) and VCR
/// PWL(1) ("Bad real value"), and on VALUE and TABLE on F and H,
/// which it reads on E and G alone. A VALUE takes the modifiers
/// `m=`, `tc1=` and `tc2=`, as ngspice's B card does; any other
/// modifier, and any after POLY or TABLE, is refused (ngspice stops
/// on it, or drops one after TABLE with "Missing token").
pub fn behaviouralCard(r: *Reader, line: []const u8, head: []const u8, letter: u8, f_in: F, frame: *const Frame, form: Form) Error!void {
    const arena = r.arena;
    var f = f_in;
    r.card.nodes.clearRetainingCapacity();
    r.card.positional.clearRetainingCapacity();
    r.card.kv.clearRetainingCapacity();
    for (0..2) |_| try r.card.nodes.append(arena, try word(&f));
    const keyword = f.field() orelse return error.ParseError;
    const by_current = letter == 'f' or letter == 'h';
    // ngspice-44.2 reads VALUE and TABLE on E and G alone, VOL= on E
    // and CUR= on G: elsewhere the braced text reaches numparam
    // ("Undefined parameter [v]").
    if (by_current and (form == .value or form == .table))
        return reader_diag.unsupported(r, line, "VALUE or TABLE on an F or H card: plain ngspice reads them on E and G alone; write a B source");
    if ((letter == 'e' and std.mem.eql(u8, keyword, "cur")) or (letter == 'g' and std.mem.eql(u8, keyword, "vol")))
        return reader_diag.unsupported(r, line, "CUR= on an E card or VOL= on a G card: plain ngspice reads VOL= on E and CUR= on G alone");
    var w: std.ArrayList(u8) = .empty;
    switch (form) {
        .refused, .kind => return reader_diag.unsupported(r, line, "unsupported controlled-source form"),
        .gate => return reader_diag.unsupported(r, line, "an AND, NAND, OR or NOR(n) gate: ngspice-44.2 runs it on an E card as XSPICE's multi_input_pwl (inpcom.c inp_chk_for_multi_in_vcvs), which ESPice does not port (#TBD)"),
        .laplace, .pole, .delay => {
            if (by_current) return reader_diag.unsupported(r, line, "unsupported controlled-source form");
            for (0..2) |_| try r.card.nodes.append(arena, try word(&f));
            var n_num: usize = 0;
            while (f.field()) |t| {
                if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
                if (form != .delay and std.mem.eql(u8, t, "/")) {
                    n_num = r.card.positional.items.len;
                } else if (F.isWord(t) and f.takeEq()) {
                    try r.card.kv.append(arena, .{ .key = t, .value = try reader_values.kvValue(r, &f, frame, false) });
                } else try r.card.positional.append(arena, .{ .num = try numberAt(r, t, &f, frame) });
            }
            if (form != .delay) {
                const n_den = r.card.positional.items.len - n_num;
                if (n_num == 0 or n_den == 0) return error.ParseError;
                if (form == .pole and (n_num % 2 == 0 or n_den % 2 == 0)) return error.ParseError;
                try r.card.kv.append(arena, .{ .key = @tagName(form), .value = .{ .num = @floatFromInt(n_num) } });
            } else if (r.card.positional.items.len != 0 or kvIndex(r.card.kv.items, "td") == null) return error.ParseError;
            return reader_card.commit(r, head, letter, frame);
        },
        .value => {
            _ = f.takeEq();
            // ngspice-44.2 reads a VALUE text that starts with a
            // number from its first brace on (`2*v(a)+{k}` is k
            // there) and stops when it has none ("mal formed E
            // source instance"); one that starts otherwise is read
            // whole (inpcom.c; scratchpad r4, `listing expand`).
            const rest = f.rest();
            const lead: usize = if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) 1 else 0;
            if (lead < rest.len and (std.ascii.isDigit(rest[lead]) or rest[lead] == '.'))
                return reader_diag.unsupported(r, line, "an E or G VALUE that starts with a number: ngspice reads it from its first brace on (2*v(a)+{k} is k there) and stops when there is none; brace the whole expression");
            try w.appendSlice(arena, try exprRest(r, &f, frame));
        },
        .poly => try polyText(r, &w, &f, frame, by_current),
        .table => {
            // TABLE {expr} = (x1, y1) (x2, y2) ... (ngspice inpcom.c),
            // corners smoothed over a tenth of the shorter segment,
            // the ends held. `TABLE` is the name no deck spells
            // (expr_ops.zig `fns`). One pair is its y alone, as
            // ngspice-44.2 reads it ("a single pair (x0, y0) will
            // return a constant").
            _ = f.takeEq();
            const t = f.field() orelse return error.ParseError;
            if (t[0] != '{' and !F.isQuote(t[0])) return error.ParseError;
            _ = f.takeEq();
            const x = try unbraced(r, line, F.body(t), frame);
            const pts = try tablePoints(r, &f, frame);
            if (pts.len == 2) {
                try w.print(arena, "({e})", .{pts[1]});
            } else {
                try w.print(arena, "TABLE(({s}),0.1", .{x});
                for (pts) |p| try w.print(arena, ",{e}", .{p});
                try w.append(arena, ')');
            }
        },
    }
    // Modifiers after the form.
    while (f.field()) |t| {
        if (t[0] == ',') continue;
        if (!F.isWord(t) or !f.takeEq()) return error.ParseError;
        try r.card.kv.append(arena, .{ .key = t, .value = try reader_values.kvValue(r, &f, frame, false) });
    }
    // ngspice-44.2 moves a VALUE's m=, tc1= and tc2= to its B card
    // and stops on scale=, max=, min=, abs= and ic= ("Undefined
    // parameter"); after POLY it stops on any ("MIF-ERROR"), and
    // after TABLE it drops any ("Missing token"; scratchpad r4).
    var tc: [2]Kv = undefined;
    var n_tc: usize = 0;
    for (r.card.kv.items) |kv| {
        const x = switch (kv.value) {
            .num => |x| x,
            else => return reader_diag.unsupported(r, line, "non-constant controlled-source parameter"),
        };
        if (form != .value) return reader_diag.unsupported(r, line, "a modifier after POLY or TABLE: ngspice stops on one after POLY and drops one after TABLE");
        if (std.mem.eql(u8, kv.key, "m")) {
            w = try wrapped(arena, "(", w.items, try arena.print(")*({e})", .{x}));
        } else if (std.mem.eql(u8, kv.key, "tc1") or std.mem.eql(u8, kv.key, "tc2")) {
            if (n_tc == tc.len) return error.ParseError;
            tc[n_tc] = kv;
            n_tc += 1;
        } else return reader_diag.unsupported(r, line, "an E or G modifier other than m=, tc1= and tc2=: plain ngspice stops on scale=, max=, min=, abs= and ic=");
    }
    r.card.kv.clearRetainingCapacity();
    const key: []const u8 = if (letter == 'g' or letter == 'f') "i" else "v";
    const value = v: {
        var b = frame.*;
        b.bsource = true;
        break :v try reader_values.exprValue(r, w.items, &b, false);
    };
    try r.card.kv.append(arena, .{ .key = key, .value = value });
    try r.card.kv.appendSlice(arena, tc[0..n_tc]);
    return reader_card.commit(r, head, 'b', frame);
}

/// `pre ++ text ++ post` in a fresh list.
pub fn wrapped(arena: Allocator, pre: []const u8, text: []const u8, post: []const u8) Error!std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}{s}{s}", .{ pre, text, post });
    return out;
}

/// The expression after a B or VALUE `=`. A `{...}` or quoted field
/// followed by nothing or by `name=` modifiers is its body; else the
/// expression runs to the end of the line (`{g}*V(a)`). Either runs
/// only to the instance parameters ngspice's lexer stops at
/// (`i=v(1) tc1=1m`; PTlex, inpptree.c:1529-1546), left in `f`.
/// A brace or quote left inside is `unbraced`'s.
pub fn exprRest(r: *Reader, f: *F, frame: *const Frame) Error![]const u8 {
    const start = f.pos;
    const t = f.field() orelse return error.ParseError;
    const end = exprEnd(f.line, start);
    const all = std.mem.trim(u8, f.line[start..end], " \t");
    if (all.len == 0) return error.ParseError;
    if (t[0] == '{' or F.isQuote(t[0])) {
        var after = f.*;
        const n = after.field() orelse return unbraced(r, f.line, F.body(t), frame);
        if (F.isWord(n) and after.takeEq()) return unbraced(r, f.line, F.body(t), frame);
    }
    try f.seek(r.arena, end);
    return unbraced(r, f.line, all, frame);
}

/// B, E or G expression `text` of card `line`, its braces and quotes read as
/// ngspice reads them: it turns quotes into braces and strips every
/// brace from a B line, an E or G VALUE's included (inpcom.c
/// inp_change_quotes, inp_bsource_compat), so `{k+1}*v(a)` is
/// k+1*v(a) there. A group that parses the same stripped
/// (`{g}*v(a)`) runs; any other is refused, rather than computed
/// with its grouping: ngspice-44.2 reads `2*{1+v(a)}` as 2.5 at
/// v(a) = 0.5, and `{2*{1+1}}` as 3, or 4 when the deck has a
/// `.param` (src/tests/expressions.zig). A B line holding `=pwl(`
/// keeps its braces (inpcom.c:7199-7201), so numparam evaluates
/// each group there in `frame`: `numparamGroups`.
pub fn unbraced(r: *Reader, line: []const u8, text: []const u8, frame: *const Frame) Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "{}'") == null) return text;
    if (pwlLine(line)) return numparamGroups(r, line, text, frame);
    // A subcircuit body's expression is read once per instance: checked
    // once, when it is the deck's own text. The check reads the text alone.
    const key: [2]usize = .{ @intFromPtr(text.ptr), text.len };
    const memo = frame.sub != null and r.ast.inSource(text);
    if (memo) if (r.eval.unbraced_at.get(key)) |bare| return bare;
    const grouped = try r.arena.dupe(u8, text);
    const bare = try r.arena.dupe(u8, text);
    var open = false;
    for (grouped, bare) |*g, *b| {
        const c = g.*;
        if (c != '{' and c != '}' and !F.isQuote(c)) continue;
        b.* = ' ';
        g.* = if (c == '{' or (F.isQuote(c) and !open)) '(' else ')';
        if (F.isQuote(c)) open = !open;
    }
    var with: expr.Scratch = .{};
    var without: expr.Scratch = .{};
    try expr.compileAll(r.arena, &with, grouped);
    var same = true;
    expr.compileAll(r.arena, &without, bare) catch |err| switch (err) {
        error.ParseError => same = false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // The names and constants come in the same order either way,
    // so equal ops are the same expression.
    same = same and with.ops.items.len == without.ops.items.len and for (with.ops.items, without.ops.items) |x, y| {
        if (!std.meta.eql(x, y)) break false;
    } else true;
    if (!same) return reader_diag.unsupported(r, line, "a brace or quote inside a B, E or G expression that groups: ngspice strips it as text (2*{1+v(a)} is 2*1+v(a) there); write parentheses");
    if (memo) try r.eval.unbraced_at.put(r.arena, key, bare);
    return bare;
}

/// The next node or source name, past any `(`, `)` or `,`.
pub fn word(f: *F) Error![]const u8 {
    while (f.field()) |t| {
        if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
        if (!F.isWord(t)) return error.ParseError;
        return t;
    }
    return error.ParseError;
}

/// A number field, or a parameter or `{expr}` that folds to one.
pub fn numberAt(r: *Reader, t: []const u8, f: *F, frame: *const Frame) Error!f64 {
    return switch (try reader_values.valueAt(r, t, f, frame, true, false)) {
        .num => |x| x,
        else => error.ParseError,
    };
}

/// One controlling quantity as expression text: `v(a,b)` over the
/// next two nodes, or `i(vname)` over the next source name.
pub fn controlText(r: *Reader, w: *std.ArrayList(u8), f: *F, by_current: bool) Error!void {
    if (by_current) return w.print(r.arena, "i({s})", .{try word(f)});
    const a = try word(f);
    const b = try word(f);
    if (isGroundName(b)) return w.print(r.arena, "v({s})", .{a});
    try w.print(r.arena, "v({s},{s})", .{ a, b });
}

/// `(x1, y1) (x2, y2) ...` or `x1,y1 x2,y2 ...` as x1, y1, x2, ...:
/// one pair or more. A `key=value` among them goes to `card_kv`.
pub fn tablePoints(r: *Reader, f: *F, frame: *const Frame) Error![]const f64 {
    var pts: std.ArrayList(f64) = .empty;
    while (f.field()) |t| {
        if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
        if (F.isWord(t) and f.takeEq()) {
            try r.card.kv.append(r.arena, .{ .key = t, .value = try reader_values.kvValue(r, f, frame, false) });
            continue;
        }
        try pts.append(r.arena, try numberAt(r, t, f, frame));
    }
    if (pts.items.len < 2 or pts.items.len % 2 != 0) return error.ParseError;
    return pts.items;
}

/// `POLY(n) <controls> p0 p1 ...` as a sum of products in SPICE 2G6
/// coefficient order (XSPICE spice2poly nxtpwr). A lone coefficient
/// is p0, as ngspice reads it.
pub fn polyText(r: *Reader, w: *std.ArrayList(u8), f: *F, frame: *const Frame, by_current: bool) Error!void {
    const arena = r.arena;
    if (!std.mem.eql(u8, f.field() orelse "", "(")) return error.ParseError;
    const dim_f = try numberAt(r, f.field() orelse return error.ParseError, f, frame);
    if (!std.mem.eql(u8, f.field() orelse "", ")") or dim_f < 1 or dim_f > 8 or dim_f != @trunc(dim_f)) return error.ParseError;
    const dim: usize = @intFromFloat(dim_f);
    var ctl: [8][]const u8 = undefined;
    for (ctl[0..dim]) |*c| {
        var t: std.ArrayList(u8) = .empty;
        try controlText(r, &t, f, by_current);
        c.* = t.items;
    }
    var coef: std.ArrayList(f64) = .empty;
    while (f.field()) |t| {
        // XSPICE reads the coefficients past `(`, `)` and `,`
        // (enhtrans.c:407-410, mifutil.c:68-71 MIFgettok), so
        // `POLY(2) vs1 vs2 (0,2.4e-5,3.8e-5)` is three of them.
        if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
        if (F.isWord(t) and f.takeEq()) {
            try r.card.kv.append(arena, .{ .key = t, .value = try reader_values.kvValue(r, f, frame, false) });
            continue;
        }
        try coef.append(arena, try numberAt(r, t, f, frame));
    }
    if (coef.items.len == 0) return error.ParseError;
    try w.print(arena, "({e})", .{coef.items[0]});
    var pw: [8]u32 = @splat(0);
    for (coef.items[1..]) |c| {
        nextPower(pw[0..dim]);
        if (c == 0) continue;
        try w.print(arena, "+({e})", .{c});
        for (pw[0..dim], ctl[0..dim]) |e, x| for (0..e) |_| try w.print(arena, "*{s}", .{x});
    }
}

// ---- private ----

/// `text` with each `{...}` or quoted group replaced by its value as
/// numparam reads it (`R.bsource` off), ngspice-44.2's reading on a
/// `=pwl(` B line: `pwl(v(a),0,0,1,4)*{1+k}` is 8 at v(a) = 0.5 and
/// k = 3. A group that reads a probe stops ngspice ("Undefined
/// parameter [v]") and is refused; a nested one is a ParseError, as
/// it is ngspice's "Syntax error".
fn numparamGroups(r: *Reader, line: []const u8, text: []const u8, frame: *const Frame) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var from: usize = 0;
    // Each pass consumes a group of two bytes or more.
    for (0..text.len) |_| {
        const open = std.mem.indexOfAnyPos(u8, text, from, "{'") orelse break;
        const close = std.mem.indexOfScalarPos(u8, text, open + 1, if (text[open] == '{') '}' else text[open]) orelse return error.ParseError;
        const value = v: {
            var numparam = frame.*;
            numparam.bsource = false;
            break :v try reader_values.exprValue(r, text[open + 1 .. close], &numparam, false);
        };
        const x = value.number() orelse return reader_diag.unsupported(r, line, "a {...} on a B line holding =pwl( that does not fold to a number: ngspice's numparam evaluates it there and stops on a probe");
        try out.print(r.arena, "{s}({e})", .{ text[from..open], x });
        from = close + 1;
    }
    try out.appendSlice(r.arena, text[from..]);
    return out.items;
}

/// True for a B card holding `=pwl(`, blanks after the `=` dropped as
/// ngspice's inp_remove_ws drops them: inp_bsource_compat leaves that
/// line's braces to numparam (inpcom.c:7199-7201). `pwl (` does not match.
fn pwlLine(card: []const u8) bool {
    if (card.len == 0 or card[0] != 'b') return false;
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, card, from, '=')) |eq| {
        from = eq + 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, card[from..], " \t"), "pwl(")) return true;
    }
    return false;
}

/// Where a B or VALUE expression starting at `from` in `line` ends: before
/// the first `tc1=`, `tc2=`, `temp=`, `dtemp=` or `reciproctc=` that starts
/// a word outside braces and quotes, the instance parameters ngspice's
/// expression lexer returns at (PTlex, inpptree.c:1529-1546); else the
/// line's end. A `==` is a comparison, never a parameter.
fn exprEnd(line: []const u8, from: usize) usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i = from;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '{' => depth += 1,
            '}' => depth -|= 1,
            else => {},
        }
        if (depth != 0 or (i > from and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_'))) continue;
        for ([_][]const u8{ "tc1", "tc2", "temp", "dtemp", "reciproctc" }) |key| {
            if (!std.mem.startsWith(u8, line[i..], key)) continue;
            var j = i + key.len;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
            if (j < line.len and line[j] == '=' and (j + 1 == line.len or line[j + 1] != '=')) return i;
        }
    }
    return line.len;
}

test "exprEnd: a B expression ends at the instance parameters ngspice stops at" {
    // Oracle: ngspice-45 reads asrc-tc-1.sp's `b2 2 0 i=v(1) tc1=0.001`
    // as the expression v(1) with tc1 = 1e-3 (inpptree.c:1529-1546).
    const line = "b2 2 0 i=v(1) tc1=0.001";
    try std.testing.expectEqual(@as(usize, 14), exprEnd(line, 9));
    for ([_][]const u8{ "v(a)*temp == 1", "{a tc1=1}*v(b)", "'x temp=2'", "mytc1=1", "v(a) temper=1" }) |whole|
        try std.testing.expectEqual(whole.len, exprEnd(whole, 0));
    try std.testing.expectEqual(@as(usize, 5), exprEnd("v(a) reciproctc = 1 dtemp=2", 0));
}

test "pwlLine: the B lines whose braces ngspice leaves to numparam" {
    // Oracle: inpcom.c:7199-7201, strstr(line, "=pwl(") after inp_remove_ws
    // drops the blanks around `=`; ngspice-44.2 grouped the braces of the
    // first three and stripped the rest's (scratchpad r4/pwlcases).
    for ([_][]const u8{ "b1 o 0 v=pwl(v(a),0,0,1,4)*{1+k}", "b1 o 0 v = pwl(v(a),0,0,1,4)*{1+k}", "b1 o 0 i=pwl(v(a),0,0,1,4m)*{1+k}" }) |line|
        try std.testing.expect(pwlLine(line));
    for ([_][]const u8{ "b1 o 0 v=pwl (v(a),0,0,1,4)*{1+k}", "b1 o 0 v={1+k}*pwl(v(a),0,0,1,4)", "b1 o 0 v=2*pwl(v(a),0,0,1,4)*{1+k}", "e1 o 0 value=pwl(v(a),0,0,1,4)" }) |line|
        try std.testing.expect(!pwlLine(line));
}
