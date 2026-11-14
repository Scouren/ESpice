//! Subcircuit expansion. In: an `X` card read into the card scratch, and
//! its frame. Out: the subcircuit's body cards read under a child frame,
//! and the size a hierarchical deck flattens to.
//! Cites: ngspice subckt.c, inpcom.c:4334-4344 (m=);
//! dev/research/ngspice-syntax.md §4.1.
//!
//! Contents:
//! - `pub fn expand(r: *Reader, head: []const u8, frame: *const Frame, kv_text: []const []const u8) Error!void`
//! - `pub fn skipNested(card: Card, nested: *u32) bool`

const std = @import("std");
const Ast = @import("../Ast.zig");
const reader_devices = @import("reader_devices.zig");
const reader_models = @import("reader_models.zig");
const reader_diag = @import("reader_diag.zig");
const reader_branch = @import("reader_branch.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_nets = @import("reader_nets.zig");
const tokenizer = @import("../tokenizer.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const VertexId = card_rows.VertexId;
const Error = card_rows.Error;
const Branches = card_table.Branches;
const Scope = reader_frame.Scope;
const Frame = reader_frame.Frame;
const Card = tokenizer.Card;

/// Flattens an `X` card: reads its subcircuit's lines under a child frame.
pub fn expand(r: *Reader, head: []const u8, frame: *const Frame, kv_text: []const []const u8) Error!void {
    const arena = r.arena;
    const ast = &r.ast;
    const tags = ast.cards.items(.tag);
    // A top-level X card expands at depth 0, so 32 levels end at 31.
    if (frame.depth >= 32) {
        try reader_diag.note(r, .{ .code = .nest_depth, .text = head });
        return error.ParseError;
    }
    if (r.card.positional.items.len < 1) return error.ParseError;
    const sname = switch (r.card.positional.items[r.card.positional.items.len - 1]) {
        .name => |n| n,
        else => return error.ParseError,
    };
    const id = r.decl.subckt_ids.get(sname) orelse return error.ParseError;
    const sub = r.decl.subckts.items[id];
    if (r.card.nodes.items.len != sub.ports.len) return error.ParseError;
    if (r.nl.instances == std.math.maxInt(u32)) return error.CircuitTooLarge;
    const instance = r.nl.instances;
    r.nl.instances += 1;

    // Shadow order: instance values, subcircuit defaults, enclosing scopes.
    const scope = try arena.create(Scope);
    scope.* = .empty;
    for (sub.defaults) |d| try scope.put(arena, d.key, .{ .text = d.text });
    for (r.card.kv.items, kv_text) |kv, text| try scope.put(arena, kv.key, switch (kv.value) {
        .num => |n| .{ .num = n },
        .name => |n| .{ .text = n },
        else => .{ .text = if (text.len > 0 and (text[0] == '{' or F.isQuote(text[0]))) F.body(text) else text },
    });
    // `m=` on an X card whose subcircuit declares no `m` makes m
    // parallel copies of it (ngspice inpcom.c:4334-4344, HSPICE's
    // instance multiplier).
    var mult = frame.mult;
    const declares_m = for (sub.defaults) |d| {
        if (std.mem.eql(u8, d.key, "m")) break true;
    } else false;
    if (!declares_m) for (r.card.kv.items) |kv| if (std.mem.eql(u8, kv.key, "m")) {
        mult *= kv.value.number() orelse return reader_diag.unsupported(r, r.diag.card, "an X card's m= that is not a number");
    };
    const actuals = try arena.alloc(VertexId, r.card.nodes.items.len);
    for (r.card.nodes.items, actuals) |n, *a| a.* = try reader_nets.netOf(r, frame, n);
    const scopes = try std.mem.concat(arena, *const Scope, &.{ frame.scopes, &.{scope} });
    const child: Frame = .{
        .path = if (frame.path) |p| try std.mem.concat(arena, u8, &.{ p, ".", head }) else head,
        .ports = sub.ports,
        .actuals = actuals,
        .port_index = sub.port_index,
        .scopes = scopes,
        .depth = frame.depth + 1,
        .instance = instance,
        .sub = id,
        .models_mark = @intCast(r.local.instance_models.items.len),
        .mult = mult,
        .keep_live = frame.keep_live,
    };
    defer r.local.instance_models.shrinkRetainingCapacity(child.models_mark);
    // Models first, as ngspice reads every `.model` before any
    // device: the ones under a branch this instance keeps.
    const locals = r.local.models.items[sub.models_lo..sub.models_hi];
    if (for (locals) |m| {
        if (m.cond) break true;
    } else false) {
        var kept: Branches = .{};
        var nested: u32 = 0;
        for (sub.first..sub.end) |i| {
            const card = tags[i];
            if (card == .device or card == .unknown) continue;
            var f = ast.cursor(@intCast(i));
            _ = f.field();
            if (sub.has_nested and skipNested(card, &nested)) continue;
            switch (card) {
                .cond => |c| try reader_branch.branch(r, &kept, c, &f, &child),
                .model => if (kept.active()) for (locals, sub.models_lo..) |m, lm| {
                    if (m.cond and m.line == i) _ = try reader_models.localRow(r, lm, &child);
                },
                else => {},
            }
        }
    }
    var branches: Branches = .{};
    var nested: u32 = 0;
    for (sub.first..sub.end) |index| {
        const i: u32 = @intCast(index);
        const card = tags[i];
        if (card == .device) {
            if (nested == 0 and branches.active()) try reader_devices.readDevice(r, ast.cursor(i), &child);
            continue;
        }
        if (card == .unknown or (!sub.has_cond and !sub.has_nested)) continue;
        var f = ast.cursor(i);
        _ = f.field();
        if (sub.has_nested and skipNested(card, &nested)) continue;
        if (card == .cond) try reader_branch.branch(r, &branches, card.cond, &f, &child);
    }
    if (branches.depth != 0) return error.ParseError;
}

/// Tracks nested `.subckt` ... `.ends` while reading a body: true
/// for every card from a nested definition's header to its `.ends`.
pub fn skipNested(card: Card, nested: *u32) bool {
    switch (card) {
        .subckt => {
            nested.* += 1;
            return true;
        },
        .ends => if (nested.* > 0) {
            nested.* -= 1;
            return true;
        },
        else => {},
    }
    return nested.* > 0;
}

// ---- private ----
