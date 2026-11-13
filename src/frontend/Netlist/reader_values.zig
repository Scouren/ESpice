//! Card values: a field as a number, a name, a group or postfix, folded
//! against the `.param` scopes.
//! Cites: dev/research/ngspice-syntax.md §2.2; HSPICE [CR10] p. 238 (#203).
//!
//! Contents:
//! - `pub const max_group_depth = 32`
//! - `pub fn readValue(r: *Reader, f: *F, frame: *const Frame, subst_names: bool, geometry: bool) Error!Value`
//! - `pub fn valueAt(r: *Reader, t: []const u8, f: *F, frame: *const Frame, subst_names: bool, geometry: bool) Error!Value`
//! - `pub fn kvValue(r: *Reader, f: *F, frame: *const Frame, geometry: bool) Error!Value`
//! - `pub fn literalValue(f: *F) Error!?f64`
//! - `pub fn junkNumber(w: []const u8) bool`
//! - `pub fn numberByte(c: u8) bool`
//! - `pub fn refuseOperatorField(r: *Reader, line: []const u8, t: []const u8) Error!void`
//! - `pub fn operatorLed(t: []const u8) bool`
//! - `pub fn nameValue(r: *Reader, name: []const u8, frame: *const Frame, geometry: bool) Error!Value`
//! - `pub fn exprValue(r: *Reader, text: []const u8, frame: *const Frame, geometry: bool) Error!Value`
//! - `pub fn fold(r: *Reader, from: usize, frame: *const Frame, geometry: bool) Error!Value`
//! - `pub fn pathOf(r: *Reader, f: *F) Error![]const u8`
//! - `pub fn dataPath(r: *Reader, f: *F) Error![]const u8`

const std = @import("std");
const Ast = @import("../Ast.zig");
const spice_number = @import("../Parse/spice_number.zig");
const expr = @import("../Parse/expr.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_subst = @import("reader_subst.zig");
const reader_diag = @import("reader_diag.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const Value = card_rows.Value;
const Frame = reader_frame.Frame;
const readsLive = card_table.readsLive;

pub const max_group_depth = 32;

/// A positional value: number, name, `{expr}`/quoted expression, or
/// `name(args)`. `subst_names` substitutes a name a scope defines
/// (devices and models do; analysis cards only substitute expressions).
pub fn readValue(r: *Reader, f: *F, frame: *const Frame, subst_names: bool, geometry: bool) Error!Value {
    return valueAt(r, f.field() orelse return error.ParseError, f, frame, subst_names, geometry);
}

/// `readValue` whose first field `t` is already read.
pub fn valueAt(r: *Reader, t: []const u8, f: *F, frame: *const Frame, subst_names: bool, geometry: bool) Error!Value {
    if (!F.isWord(t)) {
        if (t[0] == '{' or F.isQuote(t[0])) return exprValue(r, F.body(t), frame, geometry);
        return error.ParseError;
    }
    if (f.nextByte() == '(') {
        _ = f.field();
        // Bounded: each nesting level is a stack frame.
        if (r.eval.group_depth == max_group_depth) return error.ParseError;
        r.eval.group_depth += 1;
        defer r.eval.group_depth -= 1;
        // `v(...)`/`i(...)` name nodes and devices, never numbers.
        const probe = std.ascii.eqlIgnoreCase(t, "v") or std.ascii.eqlIgnoreCase(t, "i");
        // `items[0]` is the name (`Group`).
        var items: std.ArrayList(Value) = .empty;
        try items.append(r.arena, .{ .name = t });
        while (true) {
            const a = f.field() orelse return error.ParseError;
            if (a[0] == ')') break;
            if (a[0] == ',') continue;
            try items.append(r.arena, if (probe and F.isWord(a)) .{ .name = a } else try valueAt(r, a, f, frame, subst_names, geometry));
        }
        return .{ .group = .{ .items = items.items } };
    }
    if (spice_number.spiceNumber(t)) |n| return .{ .num = n };
    return if (subst_names) nameValue(r, t, frame, geometry) else .{ .name = t };
}

/// The value after `key=`: an expression read up to where the grammar
/// stops, or a braced/quoted field.
pub fn kvValue(r: *Reader, f: *F, frame: *const Frame, geometry: bool) Error!Value {
    const rest = f.rest();
    if (rest.len == 0) return error.ParseError;
    if ((rest[0] == '{' and !F.isWord(rest)) or rest[0] == '\'') return readValue(r, f, frame, true, geometry);
    if (try literalValue(f)) |n| return .{ .num = n };
    const mark = r.eval.scratch.mark();
    defer r.eval.scratch.reset(mark);
    // A subcircuit body's value is read once per instance: compiled once,
    // when the card is the deck's own text (a rewritten one is not).
    const code: *const expr.Scratch, const from: usize = if (frame.sub != null and r.ast.inSource(f.line)) blk: {
        const c = try reader_subst.compiledAt(r, f.line, f.pos);
        try f.seek(r.arena, c.end);
        break :blk .{ c.code, 0 };
    } else blk: {
        try f.seek(r.arena, try expr.compile(r.arena, &r.eval.scratch, f.line, f.pos));
        break :blk .{ &r.eval.scratch, mark.ops };
    };
    const ops = code.ops.items[from..];
    if (ops.len == 1 and ops[0].code == .num) return .{ .num = code.consts.items[ops[0].a] };
    if (ops.len == 1 and ops[0].code == .ident) return nameValue(r, code.names.items[ops[0].a], frame, geometry);
    return foldCode(r, code, from, frame, geometry);
}

/// The value after `key=` when it is a lone number literal (`w=0.5u`),
/// which needs no compile, or ngspice's `r=10%3`, read as 10
/// (`junkNumber`, #200): `f` moves past it. Null, `f` unmoved, for
/// anything else. The line's text alone decides it, never a scope.
pub fn literalValue(f: *F) Error!?f64 {
    const rest = f.rest();
    if (rest.len == 0 or !(std.ascii.isDigit(rest[0]) or rest[0] == '.')) return null;
    const save = f.*;
    const w = f.field().?;
    const lone = expr.numberLen(w) == w.len or junkNumber(w);
    if (lone and !expr.isOperator(f.nextByte() orelse ' ')) return spice_number.spiceNumber(w) orelse return error.ParseError;
    f.* = save;
    return null;
}

/// Whether ngspice reads field `w` as one number token whose rest it
/// ignores: a number that runs on through `%` or `\` (`10%3`, `2k\3`),
/// since INPgetTok ends a token at `*`, `/` and `^` but at neither
/// of those (inpgtok.c; ngspice-syntax.md §1.10). The ngspice.peg
/// `numtok` rule.
pub fn junkNumber(w: []const u8) bool {
    if (w.len < 2) return false;
    if (!std.ascii.isDigit(w[0]) and !(w[0] == '.' and std.ascii.isDigit(w[1]))) return false;
    var i: usize = 1;
    while (i < w.len and numberByte(w[i])) i += 1;
    if (i == w.len or (w[i] != '%' and w[i] != '\\')) return false;
    for (w[i..]) |c| if (!numberByte(c) and c != '%' and c != '\\') return false;
    return true;
}

/// A byte INPevaluate's token runs on through after its mantissa.
pub fn numberByte(c: u8) bool {
    return std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '.';
}

/// ngspice fails a device card whose value or model field starts
/// with an operator byte (`R1 a b 10 %3`: "unknown parameter");
/// ESPice refuses it by name instead of reading a name `%3` (#200).
/// Node fields are names and stay
/// read, as do X cards and dot cards. tests/frontend/lower.zig
/// `element` refuses the same fields.
pub fn refuseOperatorField(r: *Reader, line: []const u8, t: []const u8) Error!void {
    if (operatorLed(t)) return reader_diag.unsupported(r, line, "an operator where a name or value belongs");
}

/// Whether `refuseOperatorField` refuses field `t`.
pub fn operatorLed(t: []const u8) bool {
    return F.isWord(t) and std.mem.indexOfScalar(u8, "%\\*/^|&?", t[0]) != null;
}

/// A bare name: substituted when a scope defines it.
pub fn nameValue(r: *Reader, name: []const u8, frame: *const Frame, geometry: bool) Error!Value {
    if (reader_subst.find(frame.scopes, name) == null) return .{ .name = name };
    const mark = r.eval.scratch.mark();
    defer r.eval.scratch.reset(mark);
    try r.eval.scratch.names.append(r.arena, name);
    try r.eval.scratch.ops.append(r.arena, .{ .code = .ident, .a = @intCast(mark.names) });
    return fold(r, mark.ops, frame, geometry);
}

pub fn exprValue(r: *Reader, text: []const u8, frame: *const Frame, geometry: bool) Error!Value {
    // A subcircuit body's expression is read once per instance: compiled once.
    if (frame.sub != null) return foldCode(r, try reader_subst.compiledText(r, text), 0, frame, geometry);
    const mark = r.eval.scratch.mark();
    defer r.eval.scratch.reset(mark);
    try expr.compileAll(r.arena, &r.eval.scratch, text);
    return fold(r, mark.ops, frame, geometry);
}

/// Splices parameters into the scratch ops from `from` on, then folds. A
/// number keeps nothing; anything else keeps its postfix.
/// A device or model value that reads a live name, or a distribution
/// when some card runs Monte Carlo, keeps its postfix too: a variant
/// re-evaluates it (`resolveLive`). A live name read anywhere else is
/// `UnsupportedCard`, since nothing would re-read it.
pub fn fold(r: *Reader, from: usize, frame: *const Frame, geometry: bool) Error!Value {
    return foldCode(r, &r.eval.scratch, from, frame, geometry);
}

/// A quoted or bare path; its original case survives case folding.
pub fn pathOf(r: *Reader, f: *F) Error![]const u8 {
    const t = f.field() orelse return error.ParseError;
    var path = t;
    if (F.isQuote(t[0])) {
        path = F.body(t);
    } else if (!F.isWord(t)) {
        return error.ParseError;
    } else if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) {
        path = t[1 .. t.len - 1];
    }
    return r.ast.written(path);
}

/// A data file's path, recorded for `prepare` to read.
pub fn dataPath(r: *Reader, f: *F) Error![]const u8 {
    const path = try pathOf(r, f);
    try r.decl.foreign.append(r.arena, .{ .kind = .data, .path = path });
    return path;
}

// ---- private ----

/// `fold` over `code`'s ops from `from` on.
fn foldCode(r: *Reader, code: *const expr.Scratch, from: usize, frame: *const Frame, geometry: bool) Error!Value {
    const ops_mark = r.nl.ops.items.len;
    const consts_mark = r.nl.consts.items.len;
    const sites_mark = r.live.site_ops.items.len;
    try reader_subst.subst(r, code, from, code.ops.items.len, frame, frame.scopes, 0);
    const ops = r.nl.ops.items[ops_mark..];
    const v = try expr.fold(r.arena, &r.eval.stack, ops, r.nl.consts.items, geometry, r.live.nominal.items);
    if (v.known) {
        const reads = readsLive(ops);
        const sited = r.live.site_ops.items.len > sites_mark;
        if (reads and !frame.keep_live and !frame.live_ok) {
            try reader_diag.note(r, .{ .code = .live_outside });
            return error.UnsupportedCard;
        }
        if (!(frame.keep_live and (reads or sited))) {
            r.nl.ops.shrinkRetainingCapacity(ops_mark);
            r.nl.consts.shrinkRetainingCapacity(consts_mark);
            r.live.site_ops.shrinkRetainingCapacity(sites_mark);
            r.live.site_keys.shrinkRetainingCapacity(sites_mark);
            return .{ .num = v.num };
        }
    }
    return .{ .expr = .{ .start = @intCast(ops_mark), .len = @intCast(r.nl.ops.items.len - ops_mark) } };
}
