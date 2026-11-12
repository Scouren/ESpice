//! One card to its devices: the dispatch over the card letter. In: one
//! netlist card. Out: the device instances its letter (or loaded module)
//! selects, on the Builder.
//! Cites: ngspice inp2*.c (one reader per letter).
//!
//! Contents:
//! - `pub fn addDevice(self: *NetBuilder, card: Device) !void`
//! - `pub fn addByLetter(self: *NetBuilder, letter: u8, dev: Device) !void`
//! - `pub fn addB(self: *NetBuilder, dev: Device) !void`

const std = @import("std");
const core = @import("core");
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
const net_branches = @import("net_branches.zig");
const net_topology = @import("net_topology.zig");
const net_lines = @import("net_lines.zig");
const net_passive = @import("net_passive.zig");
const net_sources = @import("net_sources.zig");
const net_devices = @import("net_devices.zig");
const net_tape = @import("net_tape.zig");
const net_filters = @import("net_filters.zig");
const net_waves = @import("net_waves.zig");
const net_cards = @import("net_cards.zig");
const NetBuilder = net_builder.NetBuilder;

pub fn addDevice(self: *NetBuilder, card: Device) !void {
    // A source's waveform in the model's argument order (ngspiceWaveform).
    const dev = if (card.kind == 'v' or card.kind == 'i') try net_sources.ngspiceWaveform(self, card) else card;
    // HDL devices are added by addDynDevices; their opaque nodes count as
    // a DC path for the topology check.
    if (net_builder.loadedType(self.b.lib, dev) != null) {
        try net_topology.topoMark(self, dev, .dc, 0);
        return;
    }
    const letter = dev.kind;
    // ngspice takes no `m=` on these letters: their parameter tables refuse
    // it, and inpcom.c:4253-4257 leaves them out when an X card's m spreads
    // over a subcircuit. Read as a $mfactor it would mislabel a branch
    // current; dropped it would be a silent wrong number.
    if (std.mem.indexOfScalar(u8, "vehkopstuwy", letter) != null) for (dev.kv) |item| {
        if (std.mem.eql(u8, item.key, "m")) return net_cards.refuse(dev, letter, "m= is not a parameter of this element");
    };
    // 'u' (URC) has no DeviceId behind it: the card expands into
    // resistor/capacitor/diode lumps in addUrc, like ngspice's URCsetup.
    if (letter != 'u' and devices.letter_map.get(&.{letter}) == null) {
        if (try net_devices.inferDeviceFromModel(dev) == null)
            return net_devices.named(dev, error.UnsupportedDevice);
    }

    switch (letter) {
        'c' => try net_topology.topoMark(self, dev, .cap, 0),
        'i' => try net_topology.topoMark(self, dev, .cur, 0),
        // A V source shorts its pair at its DC value; an inductor at 0 V. A
        // portnum V has its z0 in series, so it is a DC path, not a short.
        'v' => if (try net_cards.sourcePort(dev) == null)
            try net_topology.topoMark(self, dev, .short, net_cards.sourceDc(dev) orelse 0)
        else
            try net_topology.topoMark(self, dev, .dc, 0),
        'l' => try net_topology.topoMark(self, dev, .short, 0),
        else => try net_topology.topoMark(self, dev, .dc, 0),
    }

    switch (letter) {
        // The value's ngspice spellings: res.c, cap.c and ind.c's IOPP names.
        'r' => _ = try net_passive.addPassive(self, devices.resistor, dev, "r", &.{ "resistance", "resist" }),
        'c' => {
            _ = try net_passive.addPassive(self, devices.capacitor, dev, "c", &.{ "capacitance", "cap" });
            // ponytail: a floating C sets its n+ node, not only its own
            // charge as ngspice's CAPload under MODEUIC does, so another
            // charge on that node starts charged too. Exact for a grounded
            // C; a per-device charge seed in the uic start is the upgrade.
            if (try net_cards.numericParameter(dev.kv, "ic")) |ic| {
                const p = try self.rowOf(dev.pins[0]);
                try self.dev_ic.append(self.arena, if (p != GROUND) .{ .node = p, .value = ic } else .{ .node = try self.rowOf(dev.pins[1]), .value = -ic });
            }
        },
        'l' => {
            const br = try net_passive.addPassive(self, devices.inductor, dev, "l", &.{"inductance"});
            if (try net_cards.numericParameter(dev.kv, "ic")) |ic| try self.dev_ic.append(self.arena, .{ .node = br, .value = ic });
        },
        'v' => {
            if (comptime !@hasDecl(devices.vsource, "eval")) return error.UnsupportedDevice;
            const bound = try net_sources.bindSource(self, devices.vsource, dev);
            var nodes = try net_devices.deviceNodes(self, devices.vsource, dev);
            const pos = nodes[0];
            const sensors: u32 = if (self.sensors.fetchRemove(dev.name)) |kv| kv.value else 0;
            const port = try net_cards.sourcePort(dev);
            const neg = nodes[1];
            // ngspice's portnum V has its z0 in series in every analysis, and
            // noiseless: vsrcload.c stamps 1/z0 from n+ to an internal
            // `#res` node the ideal source drives (44.2: v(a) = 0.5 for 1 V
            // into 50 ohm, and no z0 term in .noise). The node publishes as
            // ngspice's does, `v(<source>#res)` (vsrcset.c:56 CKTmkVolt
            // "res"). The R is an internal add, unnamed: `.dc v1` and
            // `@v1[...]` still find the source, and `.noise` and `.sens`
            // give it no row, as ngspice's vsrc has none.
            if (port) |p| {
                nodes[0] = try self.b.addNode();
                self.b.node_labels.items[nodes[0]] = try std.fmt.allocPrint(self.arena, "{s}#res", .{dev.name});
                try self.b.addDevice(devices.resistor, "", &.{ .r = p.z0, .noisy = 0 }, &.{}, [2]u32{ pos, nodes[0] });
            }
            // A PWL past the table's capacity continues in sources of its
            // later segments, in series between the card's source and n-.
            const tail = try net_waves.pwlTail(devices.vsource, self.arena, dev);
            // A sensed source ends at a hidden tap; addBranchRef chains
            // its sensors from there to n- (see `VCard.tap`).
            if (sensors != 0) nodes[1] = try self.b.addNode();
            const chain_end = nodes[1];
            if (tail.len != 0) nodes[1] = try self.b.addNode();
            const br = self.b.n;
            try self.b.addDevice(devices.vsource, dev.name, &bound[0], &bound[1], nodes);
            var from = nodes[1];
            for (tail, 0..) |seg, k| {
                const to = if (k + 1 == tail.len) chain_end else try self.b.addNode();
                try self.b.addDevice(devices.vsource, dev.name, &seg, &.{}, [2]u32{ from, to });
                from = to;
            }
            try self.v.append(self.arena, .{
                .name = dev.name,
                .pos = pos,
                .neg = neg,
                .branch = br,
                .tap = chain_end,
                .sensors = sensors,
                .distof1 = net_cards.sourceDisto(dev, "distof1"),
                .distof2 = net_cards.sourceDisto(dev, "distof2"),
            });
            // The port reads v(n+) outside its z0, which the circuit holds,
            // so `.sp`, `.lin` and `.hblin` add no termination of their own.
            if (port) |p| try self.ports.append(self.arena, .{ .num = p.num, .port = .{
                .node = pos,
                .neg = chain_end,
                .branch = br,
                .z0 = p.z0,
                .band = p.band,
            } });
            if (self.source_branch == GROUND) {
                self.source_node = pos;
                self.source_branch = br;
            }
            // Every V and I card has an `ac` row: one with no AC spec drives
            // nothing (amplitude 0, phase 0) but still has its `.sens ... ac`
            // `_acmag` and `_acphase` columns, as in ngspice (vsrc.c:14-15).
            const ac = net_cards.sourceAc(dev) orelse net_cards.SourceAc{ .re = 0, .im = 0, .unit = .{ 1, 0 } };
            try self.ac.append(self.arena, .{ .name = dev.name, .pos = GROUND, .neg = br, .re = ac.re, .im = ac.im, .unit = ac.unit });
        },
        'i' => {
            if (comptime !@hasDecl(devices.isource, "eval")) return error.UnsupportedDevice;
            var bound = try net_sources.bindSource(self, devices.isource, dev);
            // isrcload.c/isrcacld.c scale every value by `m=`.
            const m = net_cards.kvNumber(dev.kv, "m") orelse 1;
            bound[1].mfactor = m;
            const nodes = try net_devices.deviceNodes(self, devices.isource, dev);
            try self.b.addDevice(devices.isource, dev.name, &bound[0], &bound[1], nodes);
            // A PWL past the table's capacity: its later segments in parallel.
            for (try net_waves.pwlTail(devices.isource, self.arena, dev)) |seg| try self.b.addDevice(devices.isource, dev.name, &seg, &.{ .mfactor = m }, nodes);
            const ac = net_cards.sourceAc(dev) orelse net_cards.SourceAc{ .re = 0, .im = 0, .unit = .{ 1, 0 } };
            try self.ac.append(self.arena, .{ .name = dev.name, .pos = nodes[0], .neg = nodes[1], .re = m * ac.re, .im = m * ac.im, .unit = .{ m * ac.unit[0], m * ac.unit[1] } });
            try self.i.append(self.arena, .{ .name = dev.name, .pos = nodes[0], .neg = if (nodes.len > 1) nodes[1] else GROUND });
            try self.topo_isrc.append(self.arena, .{ .pos = nodes[0], .neg = if (nodes.len > 1) nodes[1] else GROUND, .dc = bound[0].dc });
        },
        'f', 'h', 'k' => try self.deferred.append(self.arena, dev),
        // A W or S card with `key=value` fields is ESPice's RLGC line or
        // N-port (card_table.isDataElement); ngspice's switch has none.
        'w' => if (dev.kv.len != 0) try net_lines.addWline(self, dev) else try self.deferred.append(self.arena, dev),
        's' => if (dev.kv.len != 0) try net_lines.addSparam(self, dev) else try addByLetter(self, letter, dev),
        // A tape that reads i() waits until every branch row exists.
        'b' => if (net_tape.readsCurrent(self.nl, dev)) try self.deferred.append(self.arena, dev) else try addB(self, dev),
        'p' => try net_lines.addCpl(self, dev),
        'o' => try net_lines.addLossyLine(self, dev),
        't' => try net_lines.addTline(self, dev),
        'y' => try net_lines.addTxl(self, dev),
        'u' => try net_lines.addUrc(self, dev),
        'e', 'g' => if (net_cards.kvNumber(dev.kv, "laplace") != null) {
            try net_filters.addLaplace(self, dev, letter);
        } else if (net_cards.kvNumber(dev.kv, "pole") != null) {
            try net_filters.addPole(self, dev, letter);
        } else if (net_cards.kvNumber(dev.kv, "td") != null) {
            try net_filters.addDelay(self, dev, letter);
        } else {
            try addByLetter(self, letter, dev);
            if (letter == 'e') try net_branches.addBranchProbe(self, dev.name, net_devices.internalRow(devices.vcvs, "flowZ28pZ2cnZ29", self.b.n));
        },
        else => try addByLetter(self, letter, dev),
    }
}

pub fn addByLetter(self: *NetBuilder, letter: u8, dev: Device) !void {
    // The netlist moved a Q/M card's model name to positional[0] whatever
    // its terminal count.
    switch (net_devices.resolveDeviceId(letter, dev) catch |err| return net_devices.named(dev, err)) {
        inline else => |comptime_id| {
            const D = devices.DeviceId.Type(comptime_id);
            net_devices.addSingleDevice(self, D, dev) catch |err| return net_devices.named(dev, err);
            // ngspice's VBIC `i(q1)` is its excess-phase branch, made only
            // when TD > 0 (vbicsetup.c:510-525). Node xf2 carries only a
            // 1 ohm load, so that current equals v(xf2): alias the column.
            if (comptime_id == .vbic13_4t) {
                const td = net_cards.kvNumber(dev.kv, "td") orelse if (dev.model) |m| net_cards.kvNumber(m.kv, "td") orelse 0 else 0;
                if (td > 0) try net_branches.addBranchProbe(self, dev.name, net_devices.internalRow(D, "xf2", self.b.n));
            }
        },
    }
}

/// B card. Only a V-mode B gets an i() column: ngspice makes the branch
/// only for ASRC_VOLTAGE (asrcset.c:81-88). Our bsource declares the
/// unknown either way; the I-mode one stays unprobed rather than
/// published as a column ngspice never writes.
pub fn addB(self: *NetBuilder, dev: Device) !void {
    if (try net_tape.addBsource(self, dev)) |row| try net_branches.addBranchProbe(self, dev.name, row);
}

// ---- private ----
