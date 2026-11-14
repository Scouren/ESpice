//! After the device walk. In: every card read. Out: the `.options` shunt
//! cards, and each M card on its model bin with `.option scale` applied.
//! Cites: ngspice INPgetModBin; HSPICE [CR] .OPTION GSHUNT.
//!
//! Contents:
//! - `pub fn shunts(r: *Reader) Error!void`
//! - `pub fn modelBins(r: *Reader, slots: []const Live.Slot, slot_scale: []f64) Error!void`

const std = @import("std");
const reader_nets = @import("reader_nets.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const reader_frame = @import("reader_frame.zig");
const reader_models = @import("reader_models.zig");
const card_table = @import("card_table.zig");
const netlist_view = @import("netlist_view.zig");
const reader_directives = @import("reader_directives.zig");
const Reader = reader.Reader;
const VertexId = card_rows.VertexId;
const ground = card_rows.ground;
const none = card_rows.none;
const Error = card_rows.Error;
const Value = card_rows.Value;
const appendSpan = reader_frame.appendSpan;
const Live = card_rows.Live;
const binBounds = card_table.binBounds;
const binHolds = netlist_view.binHolds;
const kvNumber = netlist_view.kvNumber;

/// `.options gshunt=G cshunt=C` [CR Ch.3] and ngspice's `rshunt=R`:
/// a conductance, capacitance or resistance from every net to
/// ground, added as R and C cards named `r.gshunt.<net>`,
/// `c.cshunt.<net>` and `r.rshunt.<net>`.
pub fn shunts(r: *Reader) Error!void {
    const nets = r.nl.hg.vertices.len;
    inline for (.{ .{ "gshunt", 'r' }, .{ "cshunt", 'c' }, .{ "rshunt", 'r' } }) |s| if (reader_directives.option(r, s[0])) |v| if (v > 0) {
        for (1..nets) |net| {
            const value: Value = .{ .num = if (comptime std.mem.eql(u8, s[0], "gshunt")) 1 / v else v };
            const pins = [2]VertexId{ .from(net), ground };
            const net_name = r.nl.pool.str(r.nl.hg.vertices.items(.name)[net]);
            const name = try reader_nets.internName(r, try r.arena.print("{c}.{s}.{s}", .{ s[1], s[0], net_name }));
            _ = r.nl.hg.addEdge(r.arena, .{
                .kind = s[1],
                .name = name,
                .model = none,
                .positional = try appendSpan(Value, r.arena, &r.nl.values, &.{value}),
                .kv = .{},
                .subckt_instance = 0,
            }, &pins) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CircuitTooLarge,
            };
        }
    };
}

/// `.option scale` and ngspice model binning (INPgetModBin): an M card
/// naming `nm` takes the last-declared global `nm.<n>` whose L/W
/// bounds hold it, within 1 nm. `modelRow` already binned the cards
/// that name a subcircuit's own bins. Writes the factor each live
/// slot of `slots` takes into `slot_scale`, parallel to it.
pub fn modelBins(r: *Reader, slots: []const Live.Slot, slot_scale: []f64) Error!void {
    std.debug.assert(slots.len == slot_scale.len);
    const scale = r.deck.scale;
    const wnflag = r.deck.wnflag;
    const arena = r.arena;
    // Slot of each `kvs` row, `none` where it holds none, for the
    // scale and the bin check; empty when the deck has no slot.
    const slot_of = try arena.alloc(u32, if (slots.len == 0) 0 else r.nl.kvs.items.len);
    @memset(slot_of, none);
    for (slots, 0..) |slot, k| if (slot.table == .kvs) {
        slot_of[slot.row] = @intCast(k);
    };
    const models = r.nl.models.items;
    const kvs = r.nl.kvs.items;
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    const next = try arena.alloc(u32, models.len);
    @memset(next, none);
    const bounds = try arena.alloc([4]f64, models.len);
    // Global rows only: a subcircuit's models are its own.
    for (models, 0..) |m, i| if (r.nl.model_ids.contains(m.name)) try names.put(arena, m.name, @intCast(i));
    for (models, 0..) |m, mi| {
        if (!r.nl.model_ids.contains(m.name)) continue;
        const dot = std.mem.lastIndexOfScalar(u8, m.name, '.') orelse continue;
        _ = std.fmt.parseInt(u32, m.name[dot + 1 ..], 10) catch continue;
        bounds[mi] = binBounds(kvs[m.kv.start..][0..m.kv.len]) orelse continue;
        const entry = try names.getOrPut(arena, m.name[0..dot]);
        if (entry.found_existing) {
            if (std.mem.eql(u8, models[entry.value_ptr.*].name, m.name[0..dot])) continue;
            next[mi] = entry.value_ptr.*;
        }
        entry.value_ptr.* = @intCast(mi);
    }
    const lengths = std.StaticStringMap(u2).initComptime(.{
        .{ "l", 1 },  .{ "w", 1 },  .{ "pd", 1 }, .{ "ps", 1 }, .{ "sa", 1 }, .{ "sb", 1 }, .{ "sd", 1 },
        .{ "ad", 2 }, .{ "as", 2 },
    });
    const edges = r.nl.hg.edges.slice();
    for (edges.items(.kind), edges.items(.positional), edges.items(.kv), edges.items(.model), 0..) |kind, ps, ks, *model, ei| {
        if (kind != 'm') continue;
        const kv = r.nl.kvs.items[ks.start..][0..ks.len];
        var swept_geometry = false;
        for (kv, @as(usize, ks.start)..) |*item, row| {
            const power = lengths.get(item.key) orelse continue;
            if (item.value != .num) return error.ParseError;
            const factor = if (power == 2) scale * scale else scale;
            if (slot_of.len != 0 and slot_of[row] != none) {
                const k = slot_of[row];
                slot_scale[k] = factor;
                swept_geometry = swept_geometry or std.mem.eql(u8, item.key, "l") or std.mem.eql(u8, item.key, "w");
            }
            if (scale != 1) item.value.num *= factor;
        }
        if (ps.len == 0) continue;
        const first = &r.nl.values.items[ps.start];
        if (first.* != .name) continue;
        var bin = names.get(first.name) orelse continue;
        if (std.mem.eql(u8, first.name, models[bin].name)) continue;
        const l = kvNumber(kv, "l") orelse return error.ParseError;
        const use_nf = if (kvNumber(kv, "wnflag")) |flag| flag != 0 else wnflag;
        const nf = if (use_nf) kvNumber(kv, "nf") orelse 1 else 1;
        const w = (kvNumber(kv, "w") orelse return error.ParseError) / nf;
        // A swept or sampled l/w: every bin is a candidate a point
        // may pick (`Live.bins`).
        if (swept_geometry) {
            var c = bin;
            while (c != none) : (c = next[c]) {
                try r.live.bin_rows.append(arena, r.nl.model_ids.get(models[c].name) orelse none);
                try r.live.bin_bounds.append(arena, bounds[c]);
            }
            try reader_models.closeBins(r, @intCast(ei), use_nf);
        }
        while (bin != none) : (bin = next[bin]) {
            if (binHolds(bounds[bin], l, w)) {
                first.* = .{ .name = models[bin].name };
                model.* = r.nl.model_ids.get(models[bin].name) orelse none;
                break;
            }
        }
        if (bin == none) return error.ModelBinNotFound;
    }
}

// ---- private ----
