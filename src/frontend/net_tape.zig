//! Behavioural B sources as expression tapes. In: a B card's `v=` or `i=`
//! postfix. Out: the bsources that run it, one per tape
//! (src/frontend/bsrc_tape.zig compiles and splits).
//! Cites: ngspice asrcset.c, asrcload.c; models/bsource.va.
//!
//! Contents:
//! - `pub fn addBsource(self: *NetBuilder, dev: Device) !?u32`
//! - `pub fn controlledNodes(self: *NetBuilder, dev: Device) ![4]u32`
//! - `pub fn cardScale(dev: Device, letter: u8) f64`
//! - `pub fn readsCurrent(nl: Netlist, dev: Device) bool`

const std = @import("std");
const core = @import("core");
const requests = core.query;
const numerics = core.numerics;
const devices = @import("spice.zig");
const sparam = @import("sparam.zig");
const wfit = @import("wfit.zig");
const device = @import("device");
const netlist = @import("netlist");
const Netlist = netlist.Netlist;
const Device = Netlist.View;
const Model = netlist.Model;
const Kv = netlist.Kv;
const Value = netlist.Value;
const Op = netlist.expr.Op;
const batch = device.abi;
const Library = device.Library;
const DeviceType = batch.DeviceType;
const castField = batch.bind.castField;
const markGiven = batch.bind.markGiven;

const GROUND = core.GROUND;
const Circuit = device.Circuit;
const Proto = batch.Proto;

const net_builder = @import("net_builder.zig");
const bsrc_tape = @import("bsrc_tape.zig");
const net_cards = @import("net_cards.zig");
const net_devices = @import("net_devices.zig");
const NetBuilder = net_builder.NetBuilder;

const ports = bsrc_tape.ports;

/// A B card's output: V(p,n) or I(p,n), ngspice's two (reader_devices.zig
/// refuses any other).
const BMode = enum { v, i };
const b_modes = std.StaticStringMap(BMode).initComptime(.{ .{ "v", .v }, .{ "i", .i } });

/// B card as an expression tape, run by models/bsource.va (V output) or
/// bsource_i.va (I output); a tape with a `ddt` runs on bsource_d (V) or
/// bsource_di (I).
/// An expression past one tape's capacity splits into V-output pieces,
/// each driving an unlabelled row the rest reads (`bsrc_tape.cut`): one
/// bsource and two unknowns more per piece.
/// Returns a voltage-mode B's branch row, the only B branch current worth
/// probing (ngspice asrcset.c:81-88); null for the other modes.
pub fn addBsource(self: *NetBuilder, dev: Device) !?u32 {
    // The last v=/i= wins, as ngspice reads the card.
    var mode: BMode = .v;
    for (dev.kv) |item| mode = b_modes.get(item.key) orelse mode;
    // Output rows before control rows, so node numbering follows the card.
    var nodes: [ports]u32 = @splat(GROUND);
    for (dev.pins[0..@min(dev.pins.len, 2)], 0..) |pin, k| nodes[k] = try self.rowOf(pin);
    var p = try cardProg(self, dev);
    // Each cut replaces two or more instructions by one row read.
    for (0..p.ins.items.len + 1) |_| {
        const range = try bsrc_tape.cut(self.arena, p) orelse break;
        var piece: [ports]u32 = @splat(GROUND);
        piece[0] = try self.b.addNode();
        const part = bsrc_tape.tapeOf(p.ins.items[range[0]..range[1]], p.tables.items, &piece);
        if (part.n_ddt > 0) try addTape(self, devices.bsource_d, null, part, piece) else try addTape(self, devices.bsource, null, part, piece);
        try p.replace(self.arena, range, piece[0]);
    } else unreachable;
    const t = bsrc_tape.tapeOf(p.ins.items, p.tables.items, &nodes);
    const ddt = t.n_ddt > 0;
    const flow = "flowZ28pZ2cnZ29";
    switch (mode) {
        // bsource_d's d0..d3 rows move its branch row.
        .v => if (ddt) {
            try addTape(self, devices.bsource_d, dev, t, nodes);
            return net_devices.internalRow(devices.bsource_d, flow, self.b.n);
        } else {
            try addTape(self, devices.bsource, dev, t, nodes);
            return net_devices.internalRow(devices.bsource, flow, self.b.n);
        },
        .i => if (ddt) try addTape(self, devices.bsource_di, dev, t, nodes) else try addTape(self, devices.bsource_i, dev, t, nodes),
    }
    return null;
}

/// Four rows: the output pair, then the control pair.
pub fn controlledNodes(self: *NetBuilder, dev: Device) ![4]u32 {
    if (dev.pins.len != 4) return error.InvalidControlledSourceNodes;
    var nodes: [4]u32 = undefined;
    for (dev.pins, &nodes) |pin, *row| row.* = try self.rowOf(pin);
    return nodes;
}

/// HSPICE `SCALE` times, for a G card, `M`; both default to 1.
pub fn cardScale(dev: Device, letter: u8) f64 {
    const m = if (letter == 'g') net_cards.kvNumber(dev.kv, "m") orelse 1 else 1;
    return (net_cards.kvNumber(dev.kv, "scale") orelse 1) * m;
}

/// True when a B card's expression reads a branch current.
pub fn readsCurrent(nl: Netlist, dev: Device) bool {
    for (dev.kv) |item| switch (item.value) {
        .expr => |span| for (nl.exprOps(span)) |op| {
            if (op.code == .iprobe) return true;
        },
        else => {},
    };
    return false;
}

// ---- private ----

/// One bsource of type `B` running `t`: the card `dev`'s, with its
/// parameters, or a piece of it (null), with none and no card name.
fn addTape(self: *NetBuilder, comptime B: type, dev: ?Device, t: bsrc_tape.Tape, nodes: [ports]u32) !void {
    if (comptime !@hasDecl(B, "eval")) return error.UnsupportedDevice;
    comptime std.debug.assert(B.num_ports == ports);
    var model: B.Model = .{};
    var instance: B.Instance = .{};
    if (dev) |card| {
        if (card.model) |m| try net_cards.applyKv(&model, m.kv);
        try net_cards.applyKv(&model, card.kv);
        try net_cards.applyKv(&instance, card.kv);
        // asrcload.c:49-52: m multiplies the output, or divides it under
        // `reciprocm=1`. An i= output takes that as its $mfactor, m
        // parallel copies; a v= output would be a voltage gain, which ngspice's
        // own subcircuit m skips (inpcom.c:4259-4271), so it is refused.
        if (try net_cards.numericParameter(card.kv, "m")) |mv| {
            const recip = (try net_cards.numericParameter(card.kv, "reciprocm") orelse 0) == 1;
            if (comptime B == devices.bsource or B == devices.bsource_d) return net_cards.refuse(card, 'b', "m= on a v= output") else instance.mfactor = if (recip) 1 / mv else mv;
        }
    }
    t.store(B.Model, &model);
    try self.b.addDevice(B, if (dev) |card| card.name else "", &model, &instance, nodes);
}

/// The program of `dev`'s last v= or i= expression, its probes
/// resolved to rows.
fn cardProg(self: *NetBuilder, dev: Device) !bsrc_tape.Prog {
    var p: bsrc_tape.Prog = .{};
    for (dev.kv) |item| {
        _ = b_modes.get(item.key) orelse continue;
        p = switch (item.value) {
            .num => |value| try bsrc_tape.constant(self.arena, value),
            .expr => |span| blk: {
                const folded = try bsrc_tape.foldConstants(self.arena, self.nl.exprOps(span), self.nl.consts);
                break :blk bsrc_tape.compile(self, folded.ops, folded.consts) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        // The test runner fails any test that logs an error.
                        if (!@import("builtin").is_test) std.log.err("B-source '{s}': the {s}= expression is not supported ({s}); a B source reads node voltages, i() of branch cards, time and temper, through known functions, and its tables are constant and ascending", .{ dev.name, item.key, @errorName(err) });
                        return error.UnsupportedBsourceExpression;
                    },
                };
            },
            else => return error.UnresolvedParameter,
        };
    }
    return p;
}
