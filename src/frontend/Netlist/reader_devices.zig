//! Device cards: the element line read into one hyperedge with its
//! positional and `key=value` rows; shunts and model bins after the walk.
//! Cites: ngspice inpcom.c, INPgetModBin; HSPICE [CR] .OPTION GSHUNT.
//!
//! Contents:
//! - `pub fn readDevice(r: *Reader, card: F, outer: *const Frame) Error!void`

const std = @import("std");
const Ast = @import("../Ast.zig");
const source = @import("../source.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_behavioural = @import("reader_behavioural.zig");
const reader_rcl = @import("reader_rcl.zig");
const reader_values = @import("reader_values.zig");
const reader_diag = @import("reader_diag.zig");
const reader_card = @import("reader_card.zig");
const reader_expand = @import("reader_expand.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const nameKey = netlist_view.nameKey;
const behavioural = card_table.behavioural;
const Frame = reader_frame.Frame;

/// Reads device card `card`, a cursor at its start, under `outer` into one
/// hyperedge, or expands it when it is an X card.
pub fn readDevice(r: *Reader, card: F, outer: *const Frame) Error!void {
    const line = card.line;
    r.diag.card = line;
    const arena = r.arena;
    var f = card;
    const head = f.field() orelse return error.ParseError;
    var own = outer.*;
    own.keep_live = true;
    const frame = &own;
    if (r.live.monte) r.eval.site_owner = nameKey(nameKey(0, frame.path orelse ""), head);
    r.eval.site_ordinal = 0;
    if (!F.isWord(head) or !std.ascii.isAlphabetic(head[0])) return error.ParseError;
    const letter = std.ascii.toLower(head[0]);
    if (card_table.isDataElement(letter, line)) return readDataElement(r, head, letter, &f, frame);
    if (std.mem.indexOfScalar(u8, "efgh", letter) != null) {
        // E and G name two controls, F and H one source.
        const controls: u8 = if (letter == 'f' or letter == 'h') 1 else 2;
        var probe = f;
        _ = probe.field();
        _ = probe.field();
        var buf: [16]u8 = undefined;
        const at = probe.pos;
        const fourth = probe;
        if (probe.field()) |t| if (t.len <= buf.len) if (behavioural.get(std.ascii.lowerString(&buf, t))) |form| keyword: {
            if (form == .kind) {
                // A word for another letter (`E1 o 0 CCCS ...`) is
                // refused, as ngspice does, not read as this one (#75).
                const kinds = std.StaticStringMap(u8).initComptime(.{ .{ "vcvs", 'e' }, .{ "vccs", 'g' }, .{ "ccvs", 'h' }, .{ "cccs", 'f' } });
                if (kinds.get(std.ascii.lowerString(&buf, t)) != letter) return reader_diag.unsupported(r, line, "a controlled-source type word for another letter");
                // `E1 a b VCVS c d 2`: ngspice drops the word only
                // from a whole linear card (inpcom.c replace_token,
                // 7 fields on E and G, 6 on F and H), so the re-read
                // keeps its next word as a node and stops there.
                if (linearTail(probe, controls, false))
                    return readDevice(r, try F.initLine(arena, try std.mem.concat(arena, u8, &.{ line[0..at], " ", probe.line[probe.pos..] })), frame);
            }
            // A form word followed by a linear card's tail is a node
            // (a source on F and H): ngspice-44.2 reads `E1 o 0 vcr 0
            // 2` as v(vcr) times 2, and `vol 0 2` too. `value` and
            // `table` are keywords wherever they stand (inpcom.c
            // search_plain_identifier).
            const anywhere = std.ascii.eqlIgnoreCase(t, "value") or std.ascii.eqlIgnoreCase(t, "table");
            if (!anywhere and linearTail(probe, controls - 1, true)) break :keyword;
            if (form == .kind) return reader_diag.unsupported(r, line, "a controlled-source type word on a card ngspice does not read as linear");
            return reader_behavioural.behaviouralCard(r, line, head, letter, f, frame, form);
        };
        // SPICE 2G6 lets a one-dimensional POLY drop its `POLY(1)`:
        // ngspice inserts it when a linear card's gain is followed
        // by more (inpcom.c inp_poly_2g6_compat), so `E1 o 0 a 0 2
        // 3` is 2 + 3·v(a).
        switch (polyTail(fourth, controls)) {
            .linear => {},
            .poly => return readDevice(r, try F.initLine(arena, try std.mem.concat(arena, u8, &.{ line[0..at], " poly(1)", line[at..] })), frame),
            .dropped => return reader_diag.unsupported(r, line, "a number after a linear E, F, G or H card's m=, or after its gain when its first control starts with poly, value, vol, table, laplace, cur, vccs, vcvs, ccvs or cccs: ngspice reads no POLY(1) there and stops on it (\"unknown parameter\")"),
        }
    }
    r.card.nodes.clearRetainingCapacity();
    r.card.positional.clearRetainingCapacity();
    r.card.kv.clearRetainingCapacity();
    const model_word = try reader_card.cardNodes(arena, &f, letter, &r.card.nodes);
    // An R, C or L whose value reads the circuit, its two nodes just read.
    if (model_word == null and std.mem.indexOfScalar(u8, "rcl", letter) != null and reader_rcl.lowersToB(letter, f))
        return reader_rcl.behaviouralPassive(r, card, letter, frame);
    if (model_word) |model| {
        if (letter != 'x') try reader_values.refuseOperatorField(r, line, model);
        try r.card.positional.append(arena, try reader_values.nameValue(r, model, frame, false));
    } else if (letter == 'b') {
        const out = f.field() orelse return error.ParseError;
        const eq = f.field() orelse return error.ParseError;
        if (!F.isWord(out) or eq[0] != '=') return error.ParseError;
        // ngspice's B card has v= and i= alone: q= is "unknown
        // parameter (q)" there, a charge being a C card's q=.
        if (!std.mem.eql(u8, out, "v") and !std.mem.eql(u8, out, "i"))
            return reader_diag.unsupported(r, line, "a B source output other than v= or i=: ngspice reads q= as an unknown parameter; a charge is a C card's q={...}");
        const value = v: {
            own.bsource = true;
            defer own.bsource = false;
            break :v try reader_values.exprValue(r, try reader_behavioural.exprRest(r, &f, frame), frame, false);
        };
        try r.card.kv.append(arena, .{ .key = out, .value = value });
        // A braced expression may be followed by instance
        // parameters (`i={...} tc1=1m reciproctc=1`).
        while (f.field()) |t| {
            if (!F.isWord(t) or !f.takeEq()) return error.ParseError;
            try r.card.kv.append(arena, .{ .key = t, .value = try reader_values.kvValue(r, &f, frame, false) });
        }
        return reader_card.commit(r, head, letter, frame);
    }

    var kv_text: std.ArrayList([]const u8) = .empty;
    try reader_card.readFields(r, line, letter, &f, frame, &kv_text);
    if (letter == 'x') return reader_expand.expand(r, head, frame, kv_text.items);
    // A D card's third node is its thermal node `tj` when a model
    // name follows it (ngspice-syntax.md §3.2, #121).
    if (letter == 'q' or letter == 'm' or letter == 'd') try reader_card.splitTerminals(r);
    return reader_card.commit(r, head, letter, frame);
}

// ---- private ----

/// A W RLGC line or S N-port card (`card_table.isDataElement`):
/// nodes and `key=value` pairs in any order (`W1 N=3 1 3 5 0 2 4 6
/// 0 RLGCMODEL=m L=0.97`). A file key's value is the raw path in
/// the deck's own case.
fn readDataElement(r: *Reader, head: []const u8, letter: u8, f: *F, frame: *const Frame) Error!void {
    r.card.nodes.clearRetainingCapacity();
    r.card.positional.clearRetainingCapacity();
    r.card.kv.clearRetainingCapacity();
    while (f.field()) |t| {
        if (t[0] == ',') continue;
        if (!F.isWord(t)) return error.ParseError;
        if (!f.takeEq()) {
            try r.card.nodes.append(r.arena, t);
        } else if (card_table.data_file_keys.has(t)) {
            try r.card.kv.append(r.arena, .{ .key = t, .value = .{ .name = try reader_values.dataPath(r, f) } });
        } else {
            try r.card.kv.append(r.arena, .{ .key = t, .value = try reader_values.kvValue(r, f, frame, false) });
        }
    }
    return reader_card.commit(r, head, letter, frame);
}

/// True when `f` holds `names` words, a gain and nothing more, or
/// only `m=` pairs more when `m_ok`: a linear E, F, G or H card's
/// tail. ngspice-44.2 reads `G1 0 o vcr 0 2m m=2` as linear, and
/// `E1 o 0 delay a 0 td=1n` as no linear card.
fn linearTail(f: F, names: u8, m_ok: bool) bool {
    var g = f;
    for (0..names) |_| {
        const n = g.field() orelse return false;
        if (!F.isWord(n) or g.nextByte() == '=') return false;
    }
    const gain = g.field() orelse return false;
    if (std.mem.indexOfScalar(u8, "=(),", gain[0]) != null or g.nextByte() == '=') return false;
    while (g.field()) |k| {
        if (!m_ok or !std.mem.eql(u8, k, "m") or !g.takeEq()) return false;
        const v = g.field() orelse return false;
        if (std.mem.indexOfScalar(u8, "=(),", v[0]) != null) return false;
    }
    return true;
}

/// What ngspice-44.2 reads after the gain of a linear E, F, G or H
/// card, `f` at its first control (inpcom.c inp_poly_2g6_compat):
/// nothing, or `m=` or `ic=` and more pairs, is `.linear`; anything
/// else makes the numbers from the gain on SPICE 2G6 POLY(1)
/// coefficients (`.poly`), unless the first control starts like a
/// form word (ciprefix): there, and after `m=`, a number is one
/// ngspice stops on (`.dropped`). `(`, `)` and `,` separate, as
/// ngspice reads them in POLY.
fn polyTail(f: F, controls: u8) enum { linear, poly, dropped } {
    const poly_free = [_][]const u8{ "poly", "value", "vol", "table", "laplace", "cur", "vccs", "vcvs", "ccvs", "cccs" };
    var g = f;
    const first = reader_behavioural.word(&g) catch return .linear;
    for (1..controls) |_| _ = reader_behavioural.word(&g) catch return .linear;
    const plain = for (poly_free) |p| {
        if (std.ascii.startsWithIgnoreCase(first, p)) break false;
    } else true;
    var gain = false;
    var pairs = false;
    while (g.field()) |k| {
        if (k[0] == ',' or k[0] == '(' or k[0] == ')') continue;
        const pair = F.isWord(k) and g.takeEq();
        if (pair) _ = g.field();
        if (!gain) {
            if (pair) return .linear;
            gain = true;
            continue;
        }
        const linear_key = pair and (std.ascii.eqlIgnoreCase(k, "m") or std.ascii.eqlIgnoreCase(k, "ic"));
        if (!pairs and plain and !linear_key) return .poly;
        if (!pair) return .dropped;
        pairs = true;
    }
    return .linear;
}
