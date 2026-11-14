//! Live values: every device and model value that reads a swept `.param` or
//! a distribution, as slots a variant rewrites.
//! Cites: dev/analysis/variants.md; #133.
//!
//! Contents:
//! - `pub const Sites = struct`
//! - `pub const Slots = struct`
//! - `pub fn resolveLive(r: *Reader) Error!Live`
//! - `pub fn readsCircuit(ops: []const expr.Op) bool`
//! - `pub fn holdsSite(r: *const Reader, start: usize, end: usize) bool`
//! - `pub fn liveSlot(r: *Reader, v: *Value, at: Live.Slot, slots: *Slots, spans: *std.ArrayList(Span), pool_rows: []u32, sites: *Sites) Error!void`
//! - `pub fn siteRows(r: *Reader, span: Span, sites: *Sites) Error!Span`
//! - `pub fn liveConds(r: *Reader) Error![]const Span`

const std = @import("std");
const expr = @import("../Parse/expr.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_values = @import("reader_values.zig");
const Reader = reader.Reader;
const none = card_rows.none;
const Error = card_rows.Error;
const Span = card_rows.Span;
const Value = card_rows.Value;
const Live = card_rows.Live;
const Frame = reader_frame.Frame;
const readsLive = card_table.readsLive;
const orderU32 = netlist_view.orderU32;
const Group = card_rows.Group;

/// `Live.site_rows` and `Live.site_spans` as `liveSlot` finds them.
pub const Sites = struct { rows: std.ArrayList(u32) = .empty, spans: std.ArrayList(Span) = .empty };

/// `Live.slots` and `Live.groups` as `liveSlot` finds them.
pub const Slots = struct { at: std.ArrayList(Live.Slot) = .empty, groups: std.ArrayList(Group) = .empty };

/// Collects the live values after the device walk: each table value
/// kept as postfix because it read a live name or a distribution
/// becomes a slot holding its nominal number. Other kept postfix
/// (a B source's) reads each live name from a constant-pool row.
pub fn resolveLive(r: *Reader) Error!Live {
    if (r.live.names.count() == 0 and r.live.site_ops.items.len == 0) return .{};
    var slots: Slots = .{};
    var spans: std.ArrayList(Span) = .empty;
    var out: Live = .{ .names = r.live.names.keys(), .nominal = r.live.nominal.items };
    const pool_rows = try r.arena.alloc(u32, r.live.names.count());
    @memset(pool_rows, none);
    var sites: Sites = .{};
    for (r.nl.values.items, 0..) |*v, i| try liveSlot(r, v, .{ .table = .values, .row = @intCast(i) }, &slots, &spans, pool_rows, &sites);
    for (r.nl.kvs.items, 0..) |*kv, i| try liveSlot(r, &kv.value, .{ .table = .kvs, .row = @intCast(i) }, &slots, &spans, pool_rows, &sites);
    out.slots = slots.at.items;
    out.groups = slots.groups.items;
    out.ops = spans.items;
    out.site_ops = r.live.site_ops.items;
    out.site_keys = r.live.site_keys.items;
    out.pool_rows = pool_rows;
    out.site_rows = sites.rows.items;
    out.site_spans = sites.spans.items;
    return out;
}

/// Whether postfix `ops` reads the circuit (a probe, `time` or
/// `temper`): only a B-source tape does.
pub fn readsCircuit(ops: []const expr.Op) bool {
    for (ops) |op| switch (op.code) {
        .vprobe, .iprobe => return true,
        .ident => if (op.a >= 2) return true,
        else => {}, // else: no other op reads the circuit
    };
    return false;
}

/// Whether one of the distribution calls the parse recorded sits in
/// ops `start..end` of the netlist.
pub fn holdsSite(r: *const Reader, start: usize, end: usize) bool {
    const k = std.sort.lowerBound(u32, r.live.site_ops.items, @as(u32, @intCast(start)), orderU32);
    return k < r.live.site_ops.items.len and r.live.site_ops.items[k] < end;
}

/// Records `v`, which sits at `at`, as a slot when it reads a live
/// name or a distribution, and the arguments of a group the same way.
pub fn liveSlot(r: *Reader, v: *Value, at: Live.Slot, slots: *Slots, spans: *std.ArrayList(Span), pool_rows: []u32, sites: *Sites) Error!void {
    switch (v.*) {
        // `valueAt` built the arguments in the parse arena, mutable;
        // `Group` types them const for every reader after the parse.
        // A group keeps its `Live.groups` row only if an argument
        // (or a nested group's) became a slot.
        .group => |g| {
            if (slots.groups.items.len == none) return error.CircuitTooLarge;
            const row: u32 = @intCast(slots.groups.items.len);
            try slots.groups.append(r.arena, g);
            const mark = slots.at.items.len;
            for (g.args(), 0..) |*a, j| try liveSlot(r, @constCast(a), .{ .table = .groups, .row = row, .arg = @intCast(j) }, slots, spans, pool_rows, sites);
            if (slots.at.items.len == mark) {
                std.debug.assert(slots.groups.items.len == row + 1);
                slots.groups.items.len = row;
            }
        },
        .expr => |span| {
            const sited = holdsSite(r, span.start, span.start + span.len);
            if (!sited and !readsLive(r.nl.ops.items[span.start..][0..span.len])) return;
            const folded = try expr.fold(r.arena, &r.eval.stack, r.nl.ops.items[span.start..][0..span.len], r.nl.consts.items, false, r.live.nominal.items);
            if (folded.known) {
                try slots.at.append(r.arena, at);
                try spans.append(r.arena, span);
                v.* = .{ .num = folded.num };
                return;
            }
            // A B source's tape reads its draws from pool rows. A model
            // value kept for its `l`/`w`/`mult` is read per instance
            // as a slot, so its shared copy keeps its calls (#100).
            const kept = if (sited and readsCircuit(r.nl.ops.items[span.start..][0..span.len])) try siteRows(r, span, sites) else span;
            v.* = .{ .expr = kept };
            for (r.nl.ops.items[kept.start..][0..kept.len]) |*op| if (op.code == .live) {
                if (pool_rows[op.a] == none) {
                    try r.nl.consts.append(r.arena, r.live.nominal.items[op.a]);
                    pool_rows[op.a] = @intCast(r.nl.consts.items.len - 1);
                }
                op.* = .{ .code = .num, .a = pool_rows[op.a] };
            };
        },
        else => {},
    }
}

/// A copy of the kept expression at `span` with each largest constant
/// subtree holding a distribution call replaced by a pool row at its
/// nominal value, which `setLive` redraws from the subtree left in
/// place (#133). A subtree that also reads a probe stays as it is.
pub fn siteRows(r: *Reader, span: Span, sites: *Sites) Error!Span {
    var rev: std.ArrayList(expr.Op) = .empty;
    var i: usize = span.len;
    while (i > 0) {
        i -= 1;
        const ops = r.nl.ops.items[span.start..][0..span.len];
        const s = expr.subtreeStart(ops, i);
        const sub: Span = .{ .start = span.start + @as(u32, @intCast(s)), .len = @intCast(i + 1 - s) };
        const v = if (holdsSite(r, sub.start, sub.start + sub.len)) try expr.fold(r.arena, &r.eval.stack, ops[s .. i + 1], r.nl.consts.items, false, r.live.nominal.items) else expr.Val{ .known = false };
        if (!v.known) {
            try rev.append(r.arena, ops[i]);
            continue;
        }
        try r.nl.consts.append(r.arena, v.num);
        const row: u32 = @intCast(r.nl.consts.items.len - 1);
        try sites.rows.append(r.arena, row);
        try sites.spans.append(r.arena, sub);
        try rev.append(r.arena, .{ .code = .num, .a = row });
        i = s;
    }
    std.mem.reverse(expr.Op, rev.items);
    const start: u32 = @intCast(r.nl.ops.items.len);
    try r.nl.ops.appendSlice(r.arena, rev.items);
    return .{ .start = start, .len = @intCast(rev.items.len) };
}

/// Recompiles the top-level conditions walk 1 evaluated, now that the
/// swept names are known, keeping those that read one.
pub fn liveConds(r: *Reader) Error![]const Span {
    if (r.live.names.count() == 0) return &.{};
    const top: Frame = .{ .scopes = &r.decl.global_scopes, .keep_live = true };
    var out: std.ArrayList(Span) = .empty;
    for (r.decl.cond_texts.items) |text| switch (try reader_values.exprValue(r, text, &top, false)) {
        .expr => |span| try out.append(r.arena, span),
        else => {},
    };
    return out.items;
}

// ---- private ----
