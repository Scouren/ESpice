//! One device card's parts. In: a card's fields after its head. Out: its
//! nodes, model word and value fields in the reader's card scratch, and the
//! hyperedge they commit to under a frame.
//! Cites: ngspice inp2*.c (INPlookMod, INPgetMod), subckt.c:1422-1486,
//! inpcom.c:4253-4300 (m=).
//!
//! Contents:
//! - `pub fn fixedPins(letter: u8) ?usize`
//! - `pub fn cardNodes(a: Allocator, f: *F, letter: u8, nodes: *std.ArrayList([]const u8)) Error!?[]const u8`
//! - `pub fn readFields(r: *Reader, line: []const u8, letter: u8, f: *F, frame: *const Frame, kv_text: *std.ArrayList([]const u8)) Error!void`
//! - `pub fn namesModel(r: *const Reader, letter: u8, t: []const u8) bool`
//! - `pub fn isModel(r: *const Reader, name: []const u8) bool`
//! - `pub fn splitTerminals(r: *Reader) Error!void`
//! - `pub fn commit(r: *Reader, head: []const u8, letter: u8, frame: *const Frame) Error!void`

const std = @import("std");
const Ast = @import("../Ast.zig");
const card_rows = @import("card_rows.zig");
const reader_values = @import("reader_values.zig");
const reader = @import("reader.zig");
const reader_frame = @import("reader_frame.zig");
const reader_models = @import("reader_models.zig");
const reader_nets = @import("reader_nets.zig");
const reader_diag = @import("reader_diag.zig");
const Allocator = std.mem.Allocator;
const F = Ast.Cursor;
const Error = card_rows.Error;
const Reader = reader.Reader;
const Frame = reader_frame.Frame;
const none = card_rows.none;
const Value = card_rows.Value;
const Kv = card_rows.Kv;
const appendSpan = reader_frame.appendSpan;

pub fn fixedPins(letter: u8) ?usize {
    return switch (letter) {
        // W n+ n- Vctrl model: Vctrl/model are positional words (ngspice INP2W).
        'r', 'c', 'l', 'v', 'i', 'd', 'b', 'f', 'h', 'w' => 2,
        'q', 'z', 'j' => 3,
        'e', 'g', 's', 'm', 't', 'o' => 4,
        'k' => 0,
        else => null,
    };
}

/// A card's nodes into `nodes`, `f` just past its head, and the
/// model or subcircuit word after them: the `(`-listed nodes and
/// the word after the `)`, the fixed pins and null, or the words
/// before the first value. Reads only the line.
pub fn cardNodes(a: Allocator, f: *F, letter: u8, nodes: *std.ArrayList([]const u8)) Error!?[]const u8 {
    if ((f.nextByte() orelse return error.ParseError) == '(') {
        _ = f.field();
        while (true) {
            const t = f.field() orelse return error.ParseError;
            if (t[0] == ')') break;
            if (t[0] == ',') continue;
            if (!F.isWord(t)) return error.ParseError;
            try nodes.append(a, t);
        }
        const model = f.field() orelse return error.ParseError;
        if (!F.isWord(model)) return error.ParseError;
        return model;
    }
    if (fixedPins(letter)) |fixed| {
        try nodes.ensureUnusedCapacity(a, fixed);
        for (0..fixed) |_| {
            const t = f.field() orelse return error.ParseError;
            if (!F.isWord(t)) return error.ParseError;
            nodes.appendAssumeCapacity(t);
        }
        return null;
    }
    // Variable-terminal cards end their word list with the model/subcircuit name.
    while (true) {
        const save = f.*;
        const t = f.field() orelse break;
        if (!F.isWord(t) or f.takeEq()) {
            f.* = save;
            break;
        }
        try nodes.append(a, t);
    }
    // ngspice reads `X1 a b sub params: p=1` (numparam's subcircuit call).
    if (letter == 'x' and nodes.items.len > 0 and std.mem.eql(u8, nodes.items[nodes.items.len - 1], "params:")) _ = nodes.pop();
    return nodes.pop() orelse return error.ParseError;
}

/// The value fields after a card's nodes and model, in card order: each
/// read into `card.positional` or `card.kv` as it comes, and an X card's
/// value texts into `kv_text`.
pub fn readFields(r: *Reader, line: []const u8, letter: u8, f: *F, frame: *const Frame, kv_text: *std.ArrayList([]const u8)) Error!void {
    while (f.field()) |t| {
        if (t[0] == ',') continue;
        if (F.isWord(t) and f.takeEq()) {
            const start = f.pos;
            try r.card.kv.append(r.arena, .{ .key = t, .value = try reader_values.kvValue(r, f, frame, false) });
            if (letter == 'x') try kv_text.append(r.arena, std.mem.trim(u8, f.line[start..f.pos], " \t"));
        } else {
            if (letter != 'x') try reader_values.refuseOperatorField(r, line, t);
            try r.card.positional.append(r.arena, if (namesModel(r, letter, t)) .{ .name = t } else try reader_values.valueAt(r, t, f, frame, true, false));
        }
    }
}

/// Whether value field `t` of a `letter` card is a `.model`'s name,
/// which it is even where it reads as a number: ngspice looks the
/// word after a D, Q, J, Z, M, S, O or W card's nodes up as a model
/// (INPlookMod, INPgetMod: inp2d.c:47-51, inp2q.c:56-60,
/// inp2j.c:47-49, inp2z.c:55-57, inp2m.c:76-84, inp2s.c:57-59,
/// inp2o.c:57-69, inp2w.c:54-56), so `J1 d g s 2SK170` names model
/// 2sk170, not the number 2. R, C and L read their value first
/// (inp2r.c:83-85).
pub fn namesModel(r: *const Reader, letter: u8, t: []const u8) bool {
    return std.mem.indexOfScalar(u8, "dqjzmsow", letter) != null and isModel(r, t);
}

pub fn isModel(r: *const Reader, name: []const u8) bool {
    return r.nl.model_ids.contains(name) or r.local.names.contains(name);
}

/// Q cards carry 3-5 terminals and M cards 3-7 against the fixed 3
/// and 4 read, so the model name can land on either side of the
/// node/positional split. Moves it to positional[0].
pub fn splitTerminals(r: *Reader) Error!void {
    const nodes = &r.card.nodes;
    const pos = &r.card.positional;
    // Too few terminals: the model name was read as the last node.
    if (nodes.items.len > 0 and (pos.items.len == 0 or switch (pos.items[0]) {
        .name => |n| !isModel(r, n),
        else => true,
    })) {
        const last = nodes.items[nodes.items.len - 1];
        if (isModel(r, last)) {
            _ = nodes.pop();
            pos.shrinkRetainingCapacity(@min(pos.items.len, 3));
            try pos.insert(r.arena, 0, .{ .name = last });
            return;
        }
    }
    // Too many: extra terminals spilled into positional before the model.
    var model_at: ?usize = null;
    for (pos.items, 0..) |p, i| switch (p) {
        .name => |n| if (isModel(r, n)) {
            model_at = i;
        },
        else => {},
    };
    const mi = model_at orelse return;
    if (mi == 0 or nodes.items.len + mi > 8 or pos.items.len - mi > 4) return;
    for (pos.items[0..mi]) |p| switch (p) {
        .name, .num => {},
        else => return,
    };
    for (pos.items[0..mi]) |p| try nodes.append(r.arena, switch (p) {
        .name => |n| n,
        .num => |v| try r.arena.print("{d}", .{v}),
        else => unreachable,
    });
    try pos.replaceRange(r.arena, 0, mi, &.{});
}

pub fn commit(r: *Reader, head: []const u8, letter: u8, frame: *const Frame) Error!void {
    const arena = r.arena;
    try r.card.pins.resize(arena, r.card.nodes.items.len);
    for (r.card.nodes.items, r.card.pins.items) |n, *pin| pin.* = try reader_nets.netOf(r, frame, n);
    // A behavioural E/F/G/H is built as a B card but keeps its own
    // letter in a flattened name, which is what its i() probes use.
    const name_letter = if (letter == 'b') std.ascii.toLower(head[0]) else letter;
    // An enclosing X card's m (`Frame.mult`) multiplies the card's
    // own, as HSPICE does; ngspice overwrites it there outside its
    // HSPICE mode (inpcom.c:4272-4300). The letters and the v= B
    // ngspice gives no m are left alone (inpcom.c:4253-4271).
    if (frame.mult != 1) multiply: {
        if (std.mem.indexOfScalar(u8, "rclgfibdqjzm", name_letter) == null) break :multiply;
        var v_out = false;
        if (letter == 'b') for (r.card.kv.items) |item| {
            if (item.key.len == 1 and std.mem.indexOfScalar(u8, "viq", item.key[0]) != null) v_out = item.key[0] == 'v';
        };
        if (v_out) break :multiply;
        for (r.card.kv.items) |*item| if (std.mem.eql(u8, item.key, "m")) {
            const own = item.value.number() orelse return reader_diag.unsupported(r, r.diag.card, "m= that is not a number inside an X card with m=");
            item.value = .{ .num = own * frame.mult };
            break :multiply;
        };
        try r.card.kv.append(arena, .{ .key = "m", .value = .{ .num = frame.mult } });
    }
    // F, H and W name a V card, K two L cards: inside a subcircuit,
    // the instance's own, flattened as those cards' names are
    // (subckt.c:1422-1436, 1475-1486).
    if (frame.path) |path| if (std.mem.indexOfScalar(u8, "fhwk", letter) != null) {
        const refs: usize = if (letter == 'k') 2 else 1;
        const target: []const u8 = if (letter == 'k') "l" else "v";
        // In the arena: the card keeps the name, and `joined`'s
        // scratch is the next name's.
        for (r.card.positional.items[0..@min(refs, r.card.positional.items.len)]) |*p| if (p.* == .name) {
            p.* = .{ .name = try std.mem.concat(r.arena, u8, &.{ target, ".", path, ".", p.name }) };
        };
    };
    const positional = try appendSpan(Value, arena, &r.nl.values, r.card.positional.items);
    const kv = try appendSpan(Kv, arena, &r.nl.kvs, r.card.kv.items);
    // After the spans: reading an instance model reuses the card scratch.
    // An R, C or L card may name its model after its value
    // (`R1 a b 1k rmod`, ngspice INP2R/INP2C/INP2L).
    const pv = r.card.positional.items;
    const model_at: ?usize = if (pv.len > 0 and pv[0] == .name) 0 else if (std.mem.indexOfScalar(u8, "rcl", letter) != null and pv.len > 1 and pv[0] == .num and pv[1] == .name) 1 else null;
    const model: u32 = if (model_at) |k| try reader_models.modelRow(r, letter, pv[k].name, positional.start, frame) else none;
    const name = try reader_nets.internName(r, if (frame.path) |path| try reader_nets.joined(r, &[_][]const u8{ &.{name_letter}, ".", path, ".", head }) else head);
    _ = r.nl.hg.addEdge(arena, .{
        .kind = letter,
        .name = name,
        .model = model,
        .positional = positional,
        .kv = kv,
        .subckt_instance = frame.instance,
    }, r.card.pins.items) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CircuitTooLarge,
    };
}

// ---- private ----
