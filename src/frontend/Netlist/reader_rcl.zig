//! Behavioural R, C and L: a passive card whose value reads the circuit
//! becomes the network of plain elements and B sources ngspice writes in
//! its place. In: one R, C or L card and its frame. Out: the replacement
//! cards, committed as hyperedges; nothing for any other card.
//! Cites: ngspice inp_compat, inpcom.c:6832-7071 (git a9da7bc), its
//! eval_tc/eval_m/eval_mvalue (inpcom.c:5962-6118) and
//! b_transformation_wanted (inpcom.c:5861-5879); asrcload.c:41-52.
//!
//! Contents:
//! - `pub fn lowersToB(letter: u8, rest: F) bool`
//! - `pub fn behaviouralPassive(r: *Reader, card: F, letter: u8, outer: *const Frame) Error!void`

const std = @import("std");
const Ast = @import("../Ast.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_behavioural = @import("reader_behavioural.zig");
const reader_values = @import("reader_values.zig");
const reader_diag = @import("reader_diag.zig");
const reader_card = @import("reader_card.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const Value = card_rows.Value;
const Kv = card_rows.Kv;
const Frame = reader_frame.Frame;
const bTransformationWanted = card_table.bTransformationWanted;

/// One replacement card: what `commit` reads off the scratch lists.
const Card = struct {
    head: []const u8,
    letter: u8,
    nodes: []const []const u8,
    positional: []const Value = &.{},
    kv: []const Kv = &.{},
};

/// What a field of a behavioural card is to its network.
const Role = enum { value, charge, tc, m, noise };

/// A field's role and the letter it belongs to (0: every letter).
const Field = struct { letter: u8, role: Role };

const fields = std.StaticStringMap(Field).initComptime(.{
    .{ "r", Field{ .letter = 'r', .role = .value } },
    .{ "resistance", Field{ .letter = 'r', .role = .value } },
    .{ "noisy", Field{ .letter = 'r', .role = .noise } },
    .{ "noise", Field{ .letter = 'r', .role = .noise } },
    .{ "c", Field{ .letter = 'c', .role = .value } },
    .{ "capacitance", Field{ .letter = 'c', .role = .value } },
    .{ "q", Field{ .letter = 'c', .role = .charge } },
    .{ "l", Field{ .letter = 'l', .role = .value } },
    .{ "inductance", Field{ .letter = 'l', .role = .value } },
    .{ "tc1", Field{ .letter = 0, .role = .tc } },
    .{ "tc2", Field{ .letter = 0, .role = .tc } },
    .{ "m", Field{ .letter = 0, .role = .m } },
});

/// True when ngspice's inp_compat rewrites an R, C or L card, `rest`
/// just past its two nodes: the text there reads `v(`, `i(`, `time`,
/// `temper` or `hertz` (b_transformation_wanted), or it is a C card with
/// a `q=` charge, whatever that reads (inpcom.c:6925).
pub fn lowersToB(letter: u8, rest: F) bool {
    if (bTransformationWanted(rest.rest())) return true;
    if (letter != 'c') return false;
    var f = rest;
    while (f.field()) |t| if (F.isWord(t) and std.mem.eql(u8, t, "q") and f.takeEq()) return true;
    return false;
}

/// Commits the network ngspice writes for a card `lowersToB` accepts.
/// With `x` the card's name and `eq` its first `{...}` or `'...'`
/// field (quotes read as braces, inpcom.c:3693):
/// - R (:6878) `bx n1 n2 i=v(n1,n2)/(eq) tc m reciproctc=1
///   reciprocm=0`, then the noise network under `noisy=1`/`noise=1`
///   (:6880-6886).
/// - C with q= (:6948-6962) `gx n1 n2 x_int1 0 m`, `lx x_int1 0 1`,
///   `bx 0 x_int1 i=(eq) tc reciproctc=1`: i = m dq/dt.
/// - C (:6979-7000, the `#else` branch) `gx x_int1 0 n2 n1 1e9 m=m`,
///   `rx x_int1 0 1e-9`, `cx x_int1 x_int2 1e-6`, `vcurrmeasx x_int2
///   0 0`, `rxpar n2 n1 1e15`, `bx n1 n2 i=1e6*i(vcurrmeasx)*(eq) tc
///   reciproctc=1`: i = m C(v) dv/dt.
/// - L (:7048-7056) `fx x_int2 0 bx -1`, `lx x_int2 0 1`, `bx n2 n1
///   v=v(x_int2)*(eq)/m tc reciproctc=0`: v = L(.) di/dt / m.
/// reciproctc=1 divides a B by its temperature factor and 0
/// multiplies (asrcload.c:41-52). An enclosing X card's m reaches
/// what ngspice gives it, the card's own line (inpcom.c:4250-4305 runs
/// first): R's B, C's G and the divisor of L's B. ngspice drops every
/// other `key=value` field without a word (HSPICE's ctype= and ltype=
/// among them); this drops it too and warns, once per field.
pub fn behaviouralPassive(r: *Reader, card: F, letter: u8, outer: *const Frame) Error!void {
    var mode = outer.*;
    const frame = &mode;
    const arena = r.arena;
    const line = card.line;
    var f = card;
    const head = f.field().?;
    const n1 = f.field().?;
    const n2 = f.field().?;

    // The card's fields: its equation, then those the network keeps.
    var eq: ?[]const u8 = null;
    var charge = false;
    var noisy = false;
    var tc: [2]Kv = undefined;
    var n_tc: usize = 0;
    var m: ?Value = null;
    // Parentheses outside a {...} or '...' field; an unbalanced one
    // is a malformed card, not an equation left unbraced.
    var depth: u32 = 0;
    while (f.field()) |t| {
        if (!F.isWord(t) and (t[0] == '{' or F.isQuote(t[0]))) {
            if (eq == null) eq = F.body(t);
            continue;
        }
        if (t[0] == '(') depth += 1;
        if (t[0] == ')') depth = std.math.sub(u32, depth, 1) catch return error.ParseError;
        if (!F.isWord(t) or !f.takeEq()) continue;
        const role = roleOf(letter, t) orelse {
            _ = f.field() orelse return error.ParseError;
            try reader_diag.note(r, .{ .code = .rcl_dropped, .subject = r.ast.written(line), .text = t, .letter = letter });
            continue;
        };
        switch (role) {
            .value, .charge => {
                charge = charge or role == .charge;
                const v = f.field() orelse return error.ParseError;
                // A bare value is no equation (ngspice: "mal formed ... instance").
                if (eq == null and !F.isWord(v) and (v[0] == '{' or F.isQuote(v[0]))) eq = F.body(v);
            },
            .tc => {
                for (tc[0..n_tc]) |k| if (std.mem.eql(u8, k.key, t)) return error.ParseError;
                tc[n_tc] = .{ .key = t, .value = try reader_values.kvValue(r, &f, frame, false) };
                n_tc += 1;
            },
            .m => {
                if (m != null) return error.ParseError;
                m = try reader_values.kvValue(r, &f, frame, false);
            },
            .noise => noisy = ((try reader_values.kvValue(r, &f, frame, false)).number() orelse return error.ParseError) != 0,
        }
    }
    if (depth != 0) return error.ParseError;
    const e = try reader_behavioural.unbraced(r, line, eq orelse return reader_diag.unsupported(r, line, "a behavioural R, C or L without {...} or '...' around its equation"), frame);
    // Every expression below is a B card's (`R.bsource`); the
    // fields above were read as numparam's.
    mode.bsource = true;

    // The temperature factor's fields; bsource's dT is T - 300.15 K
    // (asrcload.c:41).
    const heat = tc[0..n_tc];

    // ngspice writes its network after the X card's m pass, so none
    // of the added cards takes that m (`bare`) unless named above.
    var bare = frame.*;
    bare.mult = 1;
    const b = try arena.print("b{s}", .{head});
    var kv: std.ArrayList(Kv) = .empty;
    switch (letter) {
        'r' => {
            try kv.append(arena, .{ .key = "i", .value = try reader_values.exprValue(r, try arena.print("v({s},{s})/({s})", .{ n1, n2, e }), frame, false) });
            try kv.appendSlice(arena, heat);
            if (m) |v| try kv.append(arena, .{ .key = "m", .value = v });
            try kv.appendSlice(arena, &.{ .{ .key = "reciproctc", .value = .{ .num = 1 } }, .{ .key = "reciprocm", .value = .{ .num = 0 } } });
            try put(r, .{ .head = b, .letter = 'b', .nodes = &.{ n1, n2 }, .kv = kv.items }, frame);
            if (!noisy) return;
            // A 1 ohm `r<x>_2` with the card's tc across a 0 V
            // `v<x>_3`, whose noise current `b<x>_1` injects as
            // i(v<x>_3)/sqrt(eq): 4kT/eq.
            const tap = try arena.print("{s}_3", .{head});
            const sense = try arena.print("v{s}", .{tap});
            try put(r, .{ .head = try arena.print("r{s}_2", .{head}), .letter = 'r', .nodes = &.{ tap, "0" }, .positional = &.{.{ .num = 1 }}, .kv = heat }, &bare);
            try put(r, .{ .head = sense, .letter = 'v', .nodes = &.{ tap, "0" }, .positional = &.{.{ .num = 0 }} }, &bare);
            const noise = try reader_values.exprValue(r, try arena.print("i({s})/sqrt({s})", .{ sense, e }), &bare, false);
            try put(r, .{ .head = try arena.print("b{s}_1", .{head}), .letter = 'b', .nodes = &.{ n1, n2 }, .kv = &.{.{ .key = "i", .value = noise }} }, &bare);
        },
        'c' => {
            const int1 = try arena.print("{s}_int1", .{head});
            const g = try arena.print("g{s}", .{head});
            // ngspice divides C by its temperature factor (reciproctc=1).
            if (charge) {
                try put(r, .{ .head = g, .letter = 'g', .nodes = &.{ n1, n2, int1, "0" }, .positional = &.{m orelse Value{ .num = 1 }} }, frame);
                try put(r, .{ .head = try arena.print("l{s}", .{head}), .letter = 'l', .nodes = &.{ int1, "0" }, .positional = &.{.{ .num = 1 }} }, &bare);
                try kv.append(arena, .{ .key = "i", .value = try reader_values.exprValue(r, try arena.print("({s})", .{e}), &bare, false) });
                try kv.appendSlice(arena, heat);
                try kv.append(arena, .{ .key = "reciproctc", .value = .{ .num = 1 } });
                try put(r, .{ .head = b, .letter = 'b', .nodes = &.{ "0", int1 }, .kv = kv.items }, &bare);
                return;
            }
            // i = C(v) dv/dt, not charge-conserving: ngspice's c=.
            const int2 = try arena.print("{s}_int2", .{head});
            const meas = try arena.print("vcurrmeas{s}", .{head});
            if (m) |v| try kv.append(arena, .{ .key = "m", .value = v });
            try put(r, .{ .head = g, .letter = 'g', .nodes = &.{ int1, "0", n2, n1 }, .positional = &.{.{ .num = 1e9 }}, .kv = kv.items }, frame);
            try put(r, .{ .head = try arena.print("r{s}", .{head}), .letter = 'r', .nodes = &.{ int1, "0" }, .positional = &.{.{ .num = 1e-9 }} }, &bare);
            try put(r, .{ .head = try arena.print("c{s}", .{head}), .letter = 'c', .nodes = &.{ int1, int2 }, .positional = &.{.{ .num = 1e-6 }} }, &bare);
            try put(r, .{ .head = meas, .letter = 'v', .nodes = &.{ int2, "0" }, .positional = &.{.{ .num = 0 }} }, &bare);
            try put(r, .{ .head = try arena.print("r{s}par", .{head}), .letter = 'r', .nodes = &.{ n2, n1 }, .positional = &.{.{ .num = 1e15 }} }, &bare);
            kv.clearRetainingCapacity();
            try kv.append(arena, .{ .key = "i", .value = try reader_values.exprValue(r, try arena.print("1e6*i({s})*({s})", .{ meas, e }), &bare, false) });
            try kv.appendSlice(arena, heat);
            try kv.append(arena, .{ .key = "reciproctc", .value = .{ .num = 1 } });
            try put(r, .{ .head = b, .letter = 'b', .nodes = &.{ n1, n2 }, .kv = kv.items }, &bare);
        },
        'l' => {
            // `commit` gives a v= B no m, so the X card's goes into the divisor.
            const own = if (m) |v| v.number() orelse return reader_diag.unsupported(r, line, "a behavioural L whose m= is not a number") else 1;
            const int2 = try arena.print("{s}_int2", .{head});
            const div = own * frame.mult;
            // ngspice's `fx x_int2 0 bx -1`. An F senses V cards only
            // here (`addBranchRef`), so it is its behavioural twin, a
            // B that keeps the F's name, as a behavioural F card is.
            const bv = try arena.print("v({s})*({s})/{e}", .{ int2, e, div });
            const fi = try reader_values.exprValue(r, try arena.print("-i({s})", .{b}), &bare, false);
            try kv.append(arena, .{ .key = "v", .value = try reader_values.exprValue(r, bv, &bare, false) });
            try kv.appendSlice(arena, heat);
            try kv.append(arena, .{ .key = "reciproctc", .value = .{ .num = 0 } });
            // The B first: the F reads its branch once it exists.
            try put(r, .{ .head = b, .letter = 'b', .nodes = &.{ n2, n1 }, .kv = kv.items }, &bare);
            try put(r, .{ .head = try arena.print("f{s}", .{head}), .letter = 'b', .nodes = &.{ int2, "0" }, .kv = &.{.{ .key = "i", .value = fi }} }, &bare);
            try put(r, .{ .head = try arena.print("l{s}", .{head}), .letter = 'l', .nodes = &.{ int2, "0" }, .positional = &.{.{ .num = 1 }} }, &bare);
        },
        else => unreachable,
    }
}

// ---- private ----

/// The role of key `key` on a card of `letter`; null for a field
/// the network drops.
fn roleOf(letter: u8, key: []const u8) ?Role {
    const field = fields.get(key) orelse return null;
    return if (field.letter == 0 or field.letter == letter) field.role else null;
}

/// Commits `card` through the scratch lists, as `readDevice` would.
fn put(r: *Reader, card: Card, frame: *const Frame) Error!void {
    const arena = r.arena;
    r.card.nodes.clearRetainingCapacity();
    r.card.positional.clearRetainingCapacity();
    r.card.kv.clearRetainingCapacity();
    try r.card.nodes.appendSlice(arena, card.nodes);
    try r.card.positional.appendSlice(arena, card.positional);
    try r.card.kv.appendSlice(arena, card.kv);
    try reader_card.commit(r, card.head, card.letter, frame);
}
