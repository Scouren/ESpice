//! Nets and subcircuit expansion: interned names, flattened node names, and
//! an `X` card's body re-read under its frame.
//! Cites: ngspice subckt.c; dev/research/ngspice-syntax.md §4.1.
//!
//! Contents:
//! - `pub fn internName(r: *Reader, s: []const u8) Error!Name`
//! - `pub fn intern(r: *Reader, s: []const u8) Error!VertexId`
//! - `pub fn connect(r: *Reader, a: []const u8, b: []const u8) Error!void`
//! - `pub fn joined(r: *Reader, parts: []const []const u8) Error![]const u8`
//! - `pub fn netOf(r: *Reader, frame: *const Frame, node: []const u8) Error!VertexId`

const std = @import("std");
const core = @import("core");
const Name = core.Name;
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const reader_frame = @import("reader_frame.zig");
const Reader = reader.Reader;
const VertexId = card_rows.VertexId;
const ground = card_rows.ground;
const none = card_rows.none;
const Error = card_rows.Error;
const isGroundName = netlist_view.isGroundName;
const Frame = reader_frame.Frame;

/// A name into the pool; a new one maps to no net yet.
pub fn internName(r: *Reader, s: []const u8) Error!Name {
    const n = try r.nl.pool.intern(r.arena, s);
    if (n.index() == r.nl.net_of.items.len) try r.nl.net_of.append(r.arena, none);
    return n;
}

pub fn intern(r: *Reader, s: []const u8) Error!VertexId {
    if (isGroundName(s)) return ground;
    const n = try internName(r, s);
    const slot = &r.nl.net_of.items[n.index()];
    if (slot.* == none) {
        const v = r.nl.hg.addVertex(r.arena, .{ .name = n }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CircuitTooLarge,
        };
        slot.* = v.index();
    }
    return .from(slot.*);
}

/// Makes nets `a` and `b` one net, before any device card is read.
/// Two names that are already distinct nets (an alias chain closing
/// on itself through different roots) are refused.
pub fn connect(r: *Reader, a: []const u8, b: []const u8) Error!void {
    // Name rows, not pointers into `net_of`: interning `b` can grow it.
    var rows: [2]?u32 = .{ null, null };
    for ([_][]const u8{ a, b }, &rows) |name, *row| if (!isGroundName(name)) {
        row.* = (try internName(r, try r.arena.dupe(u8, name))).index();
    };
    var ids: [2]u32 = .{ 0, 0 };
    for (rows, &ids) |row, *id| if (row) |n| {
        id.* = r.nl.net_of.items[n];
    };
    if (ids[0] == none and ids[1] == none) ids[0] = (try intern(r, try r.arena.dupe(u8, a))).index();
    if (ids[0] == none) r.nl.net_of.items[rows[0].?] = ids[1] else if (ids[1] == none) r.nl.net_of.items[rows[1].?] = ids[0] else if (ids[0] != ids[1]) return error.ParseError;
}

/// `parts` joined, in reused scratch: valid until the next call, so
/// a name kept past it is interned or copied.
pub fn joined(r: *Reader, parts: []const []const u8) Error![]const u8 {
    r.nl.name_buf.clearRetainingCapacity();
    for (parts) |part| try r.nl.name_buf.appendSlice(r.arena, part);
    return r.nl.name_buf.items;
}

/// A node as the frame names it: a port maps to the caller's net,
/// ground (`isGroundName`) and `.global` names stay global, anything
/// else is `<path>.<node>`.
pub fn netOf(r: *Reader, frame: *const Frame, node: []const u8) Error!VertexId {
    const path = frame.path orelse return intern(r, node);
    if (frame.port_index) |index| {
        if (index.get(node)) |k| return frame.actuals[k];
    } else for (frame.ports, frame.actuals) |p, a| if (std.mem.eql(u8, p, node)) return a;
    if (isGroundName(node) or r.nl.global_nets.contains(node)) return intern(r, node);
    return intern(r, try joined(r, &.{ path, ".", node }));
}

// ---- private ----
