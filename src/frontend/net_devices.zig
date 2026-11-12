//! Built-in device cards. In: a card with a letter and maybe a `.model`.
//! Out: its `DeviceId` (letter, LEVEL or module name), its Model bound once
//! per card and copied per instance, `derive`d, and its instance stored
//! with memoised collapse maps.
//! Cites: ngspice inpdomod.c; Verilog-A LRM §9.18 ($simparam), derive.
//!
//! Contents:
//! - `pub const simparam_fields`
//! - `pub fn resolveDeviceId(letter: u8, dev: Device) !devices.DeviceId`
//! - `pub fn named(dev: Device, err: anyerror) anyerror`
//! - `pub fn inferDeviceFromModel(dev: Device) !?devices.DeviceId`
//! - `pub fn simparamValues(b: *const builder.Builder) [simparam_fields.len]f64`
//! - `pub fn deriveModel(comptime D: type, model: *D.Model, b: *const builder.Builder, pins: usize) void`
//! - `pub fn addSingleDevice(self: *NetBuilder, comptime D: type, dev: Device) !void`
//! - `pub fn boundCard(self: *NetBuilder, comptime D: type, base: D.Model, m: Model, row: u32) !D.Model`
//! - `pub fn deviceNodes(nb: *NetBuilder, comptime D: type, dev: Device) ![D.num_ports]u32`
//! - `pub fn internalRow(comptime D: type, comptime tag: []const u8, end: u32) u32`
//! - `pub fn ownerOf(comptime T: type) struct { []const u8, bool }`
//! - `pub fn switchFlag(dev: Device, from: usize) error{UnknownParameter}!?f64`

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
const net_cards = @import("net_cards.zig");
const builder = @import("builder.zig");
const NetBuilder = net_builder.NetBuilder;
const Builder = builder.Builder;

/// VerA's reserved Model fields for §9.15 `$simparam`, parallel to
/// `simparamValues`: tnom (degC), reltol, abstol (A), vntol (V), gmin (S).
/// `source_scale__` keeps its default 1 until source stepping. See VerA's
/// `Lower.simparamHostField`.
pub const simparam_fields = [_][]const u8{ "nom_temp__", "reltol__", "abstol__", "vntol__", "gmin__" };

/// The built-in model kinds of each semiconductor letter. A card whose model
/// is another letter's kind is refused, as ngspice's "incorrect model type"
/// (#75); a kind outside these (an HDL module) is not checked.
const letter_kinds = std.StaticStringMap(u8).initComptime(.{
    .{ "nmos", 'm' },   .{ "pmos", 'm' },   .{ "vdmos", 'm' },
    .{ "vdmosn", 'm' }, .{ "vdmosp", 'm' }, .{ "npn", 'q' },
    .{ "pnp", 'q' },    .{ "d", 'd' },      .{ "njf", 'j' },
    .{ "pjf", 'j' },    .{ "nmf", 'z' },    .{ "pmf", 'z' },
    .{ "nhfet", 'z' },  .{ "phfet", 'z' },
});

/// The N and P kinds of each letter: ngspice reads each as a flag that sets
/// polarity, whether it names the card's kind or follows as a word.
const n_kinds = [_][]const u8{ "nmos", "npn", "njf", "nmf", "nhfet" };
const p_kinds = [_][]const u8{ "pmos", "pnp", "pjf", "pmf", "phfet" };

/// Each polarity field `setPolarity` writes, the first a Model has winning,
/// with the card key that binds it. The names are VerA output: Verilog-A
/// `type` becomes `typeZ` (a Zig keyword), a declared `type_` becomes
/// `typeZ5f`. A misspelled field is silently absent and runs a P-type card
/// as N-type, so do not rename them.
// ponytail: the VerA spellings (`typez`, `typez5f`) also bind those fields;
// no card writes them, so they are not keys here.
const polarity_fields = [_][2][]const u8{
    .{ "typeZ", "type" }, // i64 on most, f64 on mos1/mos2/bsim3
    .{ "typeZ5f", "type_" },
    .{ "dev_type", "dev_type" },
    .{ "mtype", "mtype" },
    .{ "TYPE", "type" }, // bsimsoi/hisim2/hisimhv/PSP: +1=NMOS, -1=PMOS
    .{ "jtype", "jtype" }, // jfet/jfet2: PJF (#75)
    .{ "ztype", "ztype" }, // mes: PMF
    .{ "type_nfet", "type_nfet" }, // hfet2: PHFET
    .{ "ty", "ty" }, // vdmos: `vdmosp`, or `pchan`
};

/// The built-ins on which ngspice-44.2 drops the model when its card gives
/// `type` (`polarityFree`). Measured 2026-11-11, `.model x <kind> level=L
/// type=-1` and `type=1` at an OP, for every built-in level: MOS 1, 2, 3, 6
/// and 9, VDMOS: "could not find a valid modelname"; BJT 1, 4, 8 and 9:
/// "Unable to find definition of given model" (45 too, though its HICUM
/// table lists `type` settable); JFET 1 and 2, MES 1, MESA 2, HFET 5 and 6:
/// "no such parameter on this device or parameter is missing". MOS 4, 5, 8,
/// 10, 14, 49, 54, 55, 56, 58, 68 and 73 warn "unrecognized parameter
/// (type) - ignored" and run by the kind. src/tests/card_keys.zig refuses
/// a card of each family.
const type_drops_model = [_][]const u8{
    "mos1",       "mos2", "mos3",  "mos6", "mos9", "vdmos", "gummel_poon", "vbic13_4t",
    "hicumL2_va", "jfet", "jfet2", "mes",  "mesa", "hfet1", "hfet2",
};

/// The built-in device a card letter and its model's LEVEL select.
pub fn resolveDeviceId(letter: u8, dev: Device) !devices.DeviceId {
    const id = try deviceIdOf(letter, dev);
    // PSP 103 ships as two devices, as upstream does (psp103.va,
    // psp103_nqs.va): the NQS build carries 48 unknowns per instance where
    // the QS one carries 12, whatever SWNQS is, so only a card that asks
    // for NQS pays for it.
    if (id == .psp103) {
        const swnqs = net_cards.kvNumber(dev.kv, "swnqs") orelse
            if (dev.model) |m| net_cards.kvNumber(m.kv, "swnqs") orelse 0 else 0;
        if (swnqs != 0) return .psp103_nqs;
    }
    // The diode heats itself only where ngspice heats it, and only then
    // pays for the thermal port and the temperature map in its eval.
    if (id == .diode and try heatsDiode(dev)) return .diode_t;
    return id;
}

/// `err`, logged with the card and its model when it is `UnsupportedDevice`,
/// so the refusal names what to fix (#75).
pub fn named(dev: Device, err: anyerror) anyerror {
    if (err == error.UnsupportedDevice and !@import("builtin").is_test) {
        const m = dev.model orelse return err;
        std.log.err("{s}: model '{s}' ({s}) is not a device this card can use", .{ dev.name, m.name, m.kind });
    }
    return err;
}

/// The device a card with no built-in letter gets from its `.model` kind
/// (`N1 d g s b nmos_model`); null when the kind names none.
pub fn inferDeviceFromModel(dev: Device) !?devices.DeviceId {
    const m = dev.model orelse return null;
    const l = try modelLevel(dev);
    if (isVdmos(m.kind))
        return .vdmos;
    // The Verilog-A module name an OSDI deck loads the model under.
    var lower: [32]u8 = undefined;
    if (m.kind.len <= lower.len) {
        if (devices.module_map.get(std.ascii.lowerString(&lower, m.kind))) |id| return id;
    }
    if (eqlAny(m.kind, &.{ "nmos", "pmos" }))
        return devices.mosfetDeviceId(l) catch null;
    if (eqlAny(m.kind, &.{ "npn", "pnp" }))
        return devices.bjtDeviceId(l) catch null;
    if (std.ascii.eqlIgnoreCase(m.kind, "d"))
        return devices.diodeDeviceId(l) catch null;
    if (eqlAny(m.kind, &.{ "njf", "pjf" }))
        return devices.jfetDeviceId(l) catch null;
    if (eqlAny(m.kind, &.{ "nmf", "pmf", "nhfet", "phfet" }))
        return devices.mesDeviceId(l) catch null;
    return null;
}

pub fn simparamValues(b: *const builder.Builder) [simparam_fields.len]f64 {
    return .{ b.nom_temp_c, b.tol.reltol, b.tol.abstol, b.tol.vntol, b.tol.gmin };
}

/// Runs §6.3.4/§3.4.5 `derive` through the device's own object: calling
/// `D.derive` directly would compile the generated body (thousands of lines
/// for bsim4) into the executable a second time.
///
/// `.options tnom` is written immediately before `derive`: VerA lowers
/// `parameter real tnom = $simparam("tnom")` to `if (!model.tnom__given)
/// model.tnom = model.nom_temp__`, ngspice's `if (!BSIM4tnomGiven)
/// BSIM4tnom = ckt->CKTnomTemp` (b4set.c:1950). A card TNOM/TREF set
/// `__given` in `applyKv`, so it still wins.
///
/// A card with `pins` nodes leaves the module's later ports unconnected:
/// §9.19 `$port_connected` reads `Model.port_connected__` (bit p = port p,
/// all ones by default), written here because `derive` may read it. A
/// 4-terminal card on HiSIM_HV's 6-port module clears `sub` and `temp`, as
/// its 4-node path expects.
pub fn deriveModel(comptime D: type, model: *D.Model, b: *const builder.Builder, pins: usize) void {
    inline for (simparam_fields, simparamValues(b)) |f, v| {
        if (comptime @hasField(D.Model, f)) @field(model, f) = v;
    }
    if (comptime @hasField(D.Model, "port_connected__")) {
        if (pins < 64) model.port_connected__ &= (@as(u64, 1) << @intCast(pins)) - 1;
    }
    if (comptime device.modelName(D)) |name| {
        if (device.vtable(name).derive) |f| f(@ptrCast(model));
    } else if (comptime @hasDecl(D, "derive")) D.derive(model);
}

/// Binds one card onto built-in `D`: model card, polarity, card pairs, derive.
pub fn addSingleDevice(self: *NetBuilder, comptime D: type, dev: Device) !void {
    const b = self.b;
    if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
    try refuseDroppedTerminals(D, dev);
    try refuseSelfHeating(D, dev);
    var model: D.Model = .{};
    var instance: D.Instance = .{};
    // VBIC: a card without the fifth (thermal) node has it tied to ground in
    // ngspice (inp2q.c:85-87), so dT = 0 whatever RTH says. Our `dt` is an
    // internal node, so self-heating is off unless the card names it; an
    // explicit SW_ET on the card still wins through applyKv below.
    if (comptime @hasField(D.Model, "sw_et")) {
        if (dev.pins.len < 5) model.sw_et = 0;
    }
    const key = try memoKey(self, D, dev);
    if (key) |k| if (self.memo.get(k)) |hit| return b.addDeviceRow(D, dev.name, hit.row, @ptrCast(@alignCast(hit.instance)), hit.col, try deviceNodes(self, D, dev));
    if (dev.model) |m| model = try boundCard(self, D, model, m, dev.model_row);
    // An E or G gain that folded to no number (an undefined name, or
    // `temper`, which numparam lacks there) stops ngspice-44.2
    // ("Undefined parameter [x]"), where 0 would run silently.
    if (comptime @hasField(D.Model, "gain") or @hasField(D.Instance, "gain"))
        if (dev.positional.len > 0 and dev.positional[0] == .expr) return error.UnresolvedParameter;
    _ = try net_builder.setParam(D, &model, &instance, "gain", Value.numberAt(dev.positional, 0) orelse 0);
    // INP2Q/D/J/Z: a bare number after the model name is the area; area=
    // below still wins.
    switch (dev.kind) {
        'q', 'd', 'j', 'z' => if (Value.numberAt(dev.positional, 1)) |a| {
            _ = try net_builder.setParam(D, &model, &instance, "area", a);
        },
        // SWzero_stateGiven (swparam.c:21-28) seeds the .op's in-band state,
        // vswitch.va's `ic`.
        's' => if (try switchFlag(dev, 1)) |on| {
            if (!try net_builder.setParam(D, &model, &instance, "ic", on)) return error.UnknownParameter;
        },
        else => {},
    }
    // Card pairs go to both structs: VerA puts every Verilog-A `parameter`
    // (W and L included) on Model. `model` is a per-device copy, so this
    // overrides the model card for this instance only.
    // LRM §6.3.6: `m=` on the instance card is the multiplier. A model
    // without an `m` of its own (bsim4va, hicum, hisim, bsimsoi), or whose
    // `m` is a shape (`cardM`: diode grading, hfet/mesa knee), takes it as
    // the instance's $mfactor (#48); the shape keeps the model card's value.
    const shape_m = comptime std.mem.eql(u8, cardM(D) orelse "", "m");
    const to_mfactor = comptime (!@hasField(D.Model, "m") or shape_m) and @hasField(D.Instance, "mfactor");
    var kv = dev.kv;
    if (to_mfactor) if (net_cards.kvNumber(dev.kv, "m")) |mv| {
        instance.mfactor = mv;
        kv = try renamedKey(self.arena, dev.kv, "m", null);
    };
    try net_cards.applyKv(&model, kv);
    try net_cards.applyKv(&instance, kv);
    try refuseUnknownKeys(self.arena, D, dev, kv);
    // §6.3.4/§3.4.5: derived parameters after the last write; explicit card
    // values win through `__given`.
    deriveModel(D, &model, b, dev.pins.len);
    try b.addDevice(D, dev.name, &model, &instance, try deviceNodes(self, D, dev));
    const k = key orelse return;
    const t = comptime Library.builtin(device.modelName(D).?);
    const vt = b.lib.vtable(t);
    const last = vt.proto_last_row orelse return;
    const n_u = comptime @typeInfo(D.U).@"enum".field_names.len;
    const col = try self.arena.alloc(i32, n_u);
    @memset(col, -1);
    if (comptime n_u > D.num_ports) if (vt.collapse) |collapse| collapse(@ptrCast(&model), @ptrCast(&instance), col.ptr);
    const kept = try self.arena.create(D.Instance);
    kept.* = instance;
    try self.memo.put(self.arena, try self.arena.dupe(u8, k), .{ .row = last((try b.protoOf(t)).ctx), .instance = kept, .col = col });
}

/// `base` with model card `m` (netlist row `row`) and its polarity bound,
/// its keys checked once per row (`net_cards.checkModelKeys`: fails with
/// `UnmodelledParameter` on a key ngspice models and `D` lacks, away from
/// its inert value; a noise-only one appends a `noise_gaps` row instead,
/// which refuses `.noise` and nothing else). Stored per row;
/// read back only when `base` is `.{}`, which holds for every device but
/// VBIC's `sw_et` pre-set. `addSingleDevice` and net_passive's R, C and L
/// cards bind through it.
pub fn boundCard(self: *NetBuilder, comptime D: type, base: D.Model, m: Model, row: u32) !D.Model {
    const t = comptime Library.builtin(device.modelName(D).?);
    const cacheable = comptime !@hasField(D.Model, "sw_et");
    if (cacheable and row != netlist.none) if (self.bound_cards[row]) |c| if (c.type == t)
        return @as(*const D.Model, @ptrCast(@alignCast(c.model))).*;
    var model = base;
    // ngspice binds a card key through the model table first, where `m` is
    // the shape `cardM` names; with none there, `m` is read and dropped,
    // never the multiplier (inpgmod.c:133-145, SpiceRack R9).
    const own = if (kindSetsPolarity(m.kind)) try polarityFree(D, self.arena, m) else m.kv;
    const kv = if (ngspiceKind(m.kind)) try renamedKey(self.arena, own, "m", comptime cardM(D)) else m.kv;
    try net_cards.applyKv(&model, kv);
    const first = row == netlist.none or self.bound_cards[row] == null;
    // Polarity comes from the kind and its flag words, outside applyKv.
    if (cardPolarity(D, m, first)) |p| try setPolarity(D, &model, p);
    if (first) {
        // Dropped with no word, gf180's BJT tempcos gave a wrong number and
        // no error: a key ngspice models for this device fails away from its
        // inert value, any other warns as ngspice does (inpgmod.c:189).
        const ngspice: ?[]const u8 = if (ngspiceKind(m.kind)) comptime device.modelName(D).? else null;
        for (try net_cards.checkModelKeys(self.arena, D.Model, ngspice, m.name, kv)) |key|
            try self.noise_gaps.append(self.arena, .{ .card = m.name, .key = key });
    }
    if (row != netlist.none and self.bound_cards[row] == null) {
        const slot = try self.arena.create(D.Model);
        slot.* = model;
        self.bound_cards[row] = .{ .type = t, .model = slot };
    }
    return model;
}

/// Rows of `D`'s ports from the card's pins; missing pins are ground.
pub fn deviceNodes(nb: *NetBuilder, comptime D: type, dev: Device) ![D.num_ports]u32 {
    var out: [D.num_ports]u32 = undefined;
    inline for (0..D.num_ports) |idx| {
        out[idx] = if (idx < dev.pins.len) try nb.rowOf(dev.pins[idx]) else GROUND;
    }
    return out;
}

/// Row `Builder.addDevice` gave `D`'s internal unknown `tag`, where `end`
/// is `b.n` sampled right after the call. Internal rows follow `D.U` order
/// and end at `end`, so the precondition is that no internal after `tag`
/// collapsed onto another node. Counting from the end, not from `b.n`
/// before the call, keeps it right when the card's own pins or probed nets
/// take fresh rows inside the call, and when an earlier internal collapses.
///
/// VerA names a Verilog-A `branch (a, b)` as the U member `flowZ28aZ2cbZ29`
/// (`(` = Z28, `,` = Z2c, `)` = Z29). Naming the member rather than writing
/// `first + 1` makes a wrong branch a compile error instead of a mislabelled
/// current column: ccvs declares two branches, the sense one first.
pub fn internalRow(comptime D: type, comptime tag: []const u8, end: u32) u32 {
    const off = comptime blk: {
        const names = @typeInfo(D.U).@"enum".field_names;
        for (names, 0..) |name, i| {
            if (std.mem.eql(u8, name, tag)) {
                if (i < D.num_ports) @compileError(@typeName(D) ++ ": `" ++ tag ++ "` is a port, not an internal unknown");
                break :blk names.len - i;
            }
        }
        @compileError(@typeName(D) ++ ": no unknown named `" ++ tag ++ "`");
    };
    return end - @as(u32, @intCast(off));
}

/// The catalog device whose Model (true) or Instance (false) `T` is.
pub fn ownerOf(comptime T: type) struct { []const u8, bool } {
    for (device.catalog) |e| {
        if (@hasDecl(e.type, "Model") and e.type.Model == T) return .{ e.name, true };
        if (@hasDecl(e.type, "Instance") and e.type.Instance == T) return .{ e.name, false };
    }
    @compileError(@typeName(T) ++ " is no catalog device's Model or Instance");
}

/// An S or W card's initial-state words, `positional[from..]` after its
/// model: 1 for ON, 0 for OFF, the last one winning, null for none
/// (swparam.c:21-28, cswparam.c:24-31). Any other word fails as ngspice's
/// `unknown parameter` (INPdevParse).
pub fn switchFlag(dev: Device, from: usize) error{UnknownParameter}!?f64 {
    var on: ?f64 = null;
    for (from..@max(from, dev.positional.len)) |i| {
        const word = Value.nameAt(dev.positional, i) orelse "";
        if (std.ascii.eqlIgnoreCase(word, "on")) on = 1 else if (std.ascii.eqlIgnoreCase(word, "off")) on = 0 else {
            if (!@import("builtin").is_test) std.log.err("{s}: only ON or OFF may follow the switch model", .{dev.name});
            return error.UnknownParameter;
        }
    }
    return on;
}

// ---- private ----

fn deviceIdOf(letter: u8, dev: Device) !devices.DeviceId {
    if (dev.model) |m| if (std.mem.indexOfScalar(u8, "mqdjz", letter) != null) {
        var buf: [8]u8 = undefined;
        const owner = if (m.kind.len <= buf.len) letter_kinds.get(std.ascii.lowerString(&buf, m.kind)) else null;
        if (owner != null and owner.? != letter) return error.UnsupportedDevice;
    };
    const level = try modelLevel(dev);
    return switch (letter) {
        // `.model X VDMOS(...)` has no LEVEL; the model kind selects it, as
        // in ngspice inpdomod.c.
        'm' => blk: {
            if (dev.model) |mm| {
                if (isVdmos(mm.kind)) break :blk .vdmos;
            }
            break :blk try devices.mosfetDeviceId(level);
        },
        'q' => try devices.bjtDeviceId(level),
        'd' => try devices.diodeDeviceId(level),
        'j' => try devices.jfetDeviceId(level),
        'z' => try devices.mesDeviceId(level),
        else => devices.letter_map.get(&.{letter}) orelse
            (try inferDeviceFromModel(dev)) orelse error.UnsupportedDevice,
    };
}

/// ngspice's DIOselfheat (diodefs.h:31-33, dioload_44.c:77): a third
/// node, the `thermal` flag (the word on the card, or a non-zero `thermal`
/// on the model card, which ngspice takes as the instance default) and a
/// given, non-zero RTH0. An RTH0 that does not fold to a number cannot be
/// judged: `UnsupportedSelfHeating`.
fn heatsDiode(dev: Device) !bool {
    const m = dev.model orelse return false;
    if (dev.pins.len != 3) return false;
    if (!thermalWord(dev) and (net_cards.kvNumber(m.kv, "thermal") orelse 0) == 0) return false;
    const rth0 = for (m.kv) |kv| {
        if (std.mem.eql(u8, kv.key, "rth0")) break kv.value;
    } else return false;
    const r = rth0.number() orelse {
        if (!@import("builtin").is_test) std.log.err("{s}: rth0 on model {s} is not a number", .{ dev.name, m.name });
        return error.UnsupportedSelfHeating;
    };
    return r != 0;
}

/// True when the card carries the bare word `thermal` past its model name
/// (dio.c:27, vdmos.c).
fn thermalWord(dev: Device) bool {
    for (dev.positional[@min(1, dev.positional.len)..]) |p| {
        if (p == .name and std.ascii.eqlIgnoreCase(p.name, "thermal")) return true;
    }
    return false;
}

fn eqlAny(a: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (std.ascii.eqlIgnoreCase(a, c)) return true;
    return false;
}

/// ngspice's three VDMOS model kinds (inpdomod.c:195-197).
fn isVdmos(kind: []const u8) bool {
    return eqlAny(kind, &.{ "vdmos", "vdmosn", "vdmosp" });
}

/// A P-channel VDMOS card: kind `vdmosp`, or a VDMOS kind with the `pchan`
/// flag anywhere, which inpcom.c:8409-8440 rewrites to `vdmosp` before
/// vdmosmpar.c:95-99 sets VDMOStype = -1.
fn vdmosP(m: Model) bool {
    if (std.ascii.eqlIgnoreCase(m.kind, "vdmosp")) return true;
    if (!isVdmos(m.kind)) return false;
    for (m.kv) |kv| {
        if (kv.key.len == 0 and kv.value == .name and std.ascii.eqlIgnoreCase(kv.value.name, "pchan")) return true;
    }
    return false;
}

/// True for a `.model` kind ngspice parses itself (inpdomod.c), whose card
/// keys `checkModelKeys` holds to ngspice's tables; false for an HDL module.
fn ngspiceKind(kind: []const u8) bool {
    var buf: [8]u8 = undefined;
    if (kind.len > buf.len) return false;
    const k = std.ascii.lowerString(&buf, kind);
    return letter_kinds.has(k) or eqlAny(k, &.{ "r", "c", "l", "res" });
}

/// True for a kind that sets its card's polarity: an ngspice semiconductor
/// kind (`letter_kinds`) but the diode's `d`, which sets none and leaves
/// juncap200's TYPE (`d level=6`) the card's to give.
fn kindSetsPolarity(kind: []const u8) bool {
    return ngspiceKind(kind) and !eqlAny(kind, &.{ "d", "r", "c", "l", "res" });
}

/// The `D.Model` field an ngspice `.model` card's `m` sets: the shape the
/// device's model table holds, the diode's grading (dio.c:71), the HFET and
/// MESA knee (hfet.c:59, hfet2.c:68, mesa.c:72), the VDMOS body diode's
/// grading, our `mj` (vdmos.c:121, vdmosmpar.c:79-83). Null elsewhere: there
/// `m` is in the instance table only, the multiplier (vdmos.c:15 too).
fn cardM(comptime D: type) ?[]const u8 {
    const T = devices.DeviceId.Type;
    if (D == T(.vdmos)) return "mj";
    if (D == T(.diode) or D == T(.diode_t) or D == T(.hfet1) or D == T(.hfet2) or D == T(.mesa)) return "m";
    return null;
}

/// `m`'s keys with `D`'s polarity key settled as ngspice-44.2 settles it,
/// on a card whose kind sets polarity (`kindSetsPolarity`; SpiceRack
/// P4-013). `type` on a `type_drops_model` built-in drops ngspice's model,
/// so the card is refused. Elsewhere `D`'s own key (`polarityField`:
/// `type`, `jtype`, `ztype`, `type_nfet`, `ty`) binds only where ngspice's
/// table holds it (`ngspiceKey`); otherwise ngspice warns "unrecognized
/// parameter (key) - ignored" and runs by the kind, and so does this,
/// dropping it. Measured: `type` on MOS levels 4-73, `njf jtype=-1`,
/// `vdmos ty=-1`, `nmf ztype=-1` and `nhfet level=6 type_nfet=-1`, each
/// drawing what the card draws without it. ESPice's own levels (no
/// ngspice table) follow the same rule: the kind owns polarity. Before,
/// the key bound the polarity field: `nmos level=54 type=-1` drew -3.26e-8
/// A where ngspice draws -1.1614e-4 A, and `njf jtype=-1` -617.8 A where
/// ngspice draws -3.0e-4 A.
fn polarityFree(comptime D: type, arena: std.mem.Allocator, m: Model) ![]const Kv {
    const name = comptime device.modelName(D).?;
    if (comptime eqlAny(name, &type_drops_model)) {
        for (m.kv) |item| if (std.mem.eql(u8, item.key, "type")) {
            if (!@import("builtin").is_test) std.log.err("{s}: `type` on a {s} card: ngspice-44.2 drops the model; its kind sets the polarity", .{ m.name, m.kind });
            return error.UnsupportedCard;
        };
    }
    const key = comptime if (polarityField(D)) |f| f[1] else "";
    if (key.len == 0) return m.kv;
    const kv = try renamedKey(arena, m.kv, key, null);
    if (kv.len == m.kv.len or net_cards.ngspiceKey(name, key) != null) return m.kv;
    if (!@import("builtin").is_test) std.log.warn("{s}: unrecognized parameter ({s}) - ignored", .{ m.name, key });
    return kv;
}

/// The polarity ngspice gives card `m` on `D`, written as its model
/// parameters write it (SpiceRack P4-013): the kind first (-1 for `pmos`,
/// `pnp`, `pjf`, `pmf`, `phfet` and a P-channel VDMOS), then each flag word
/// of `n_kinds` or `p_kinds` in card order, the last write winning. A word
/// writes only where ngspice's table for `D` holds it (`ngspiceKey`);
/// elsewhere ngspice warns "unrecognized parameter (word) - ignored", and
/// so does this when `warn`. Null when nothing writes it: `D`'s default, N.
/// Measured on ngspice-44.2: `nmos level=1 pmos` draws -617.8 A as `pmos`
/// does, `nmos level=1 pmos nmos` -2.0e-4 A as `nmos` does, `nmos level=1
/// npn` and `vdmos pmos` warn and run N. Before, every word was dropped.
fn cardPolarity(comptime D: type, m: Model, warn: bool) ?i8 {
    var p: ?i8 = if (eqlAny(m.kind, &p_kinds) or vdmosP(m)) -1 else null;
    if (!kindSetsPolarity(m.kind)) return p;
    const name = comptime device.modelName(D).?;
    for (m.kv) |item| {
        if (item.key.len != 0 or item.value != .name) continue;
        const word = item.value.name;
        const sign: i8 = if (eqlAny(word, &n_kinds)) 1 else if (eqlAny(word, &p_kinds)) -1 else continue;
        var buf: [8]u8 = undefined;
        if (net_cards.ngspiceKey(name, std.ascii.lowerString(&buf, word)) != null) {
            p = sign;
        } else if (warn and !@import("builtin").is_test) std.log.warn("{s}: unrecognized parameter ({s}) - ignored", .{ m.name, word });
    }
    return p;
}

/// `kv` with each `key` pair renamed `to`, or dropped when `to` is null;
/// `kv` itself when that changes nothing. A copy lives in `arena`.
fn renamedKey(arena: std.mem.Allocator, kv: []const Kv, key: []const u8, to: ?[]const u8) ![]const Kv {
    if (to) |t| if (std.mem.eql(u8, t, key)) return kv;
    for (kv) |item| {
        if (std.mem.eql(u8, item.key, key)) break;
    } else return kv;
    const out = try arena.alloc(Kv, kv.len);
    var n: usize = 0;
    for (kv) |item| {
        if (!std.mem.eql(u8, item.key, key)) {
            out[n] = item;
        } else if (to) |t| {
            out[n] = item;
            out[n].key = t;
        } else continue;
        n += 1;
    }
    return out[0..n];
}

/// Refuses a card that names a node past `D`'s ports, or the `thermal`
/// flag: either would be dropped with no word. A VDMOS's fourth and fifth
/// nodes (vdmos.c) are thermal nodes: `UnsupportedSelfHeating`. A diode's
/// third node (inp2d.c) and its flag pass: `resolveDeviceId` builds
/// `diode_t` where ngspice heats, and elsewhere ngspice runs the diode
/// isothermal, as `diode` does (measured on 44.2). Any other extra node is
/// `WrongNodeCount`.
fn refuseDroppedTerminals(comptime D: type, dev: Device) !void {
    const diode = comptime (D == devices.DeviceId.Type(.diode) or D == devices.DeviceId.Type(.diode_t));
    const flag = !diode and thermalWord(dev);
    if (dev.pins.len <= (if (diode) 3 else D.num_ports) and !flag) return;
    const thermal = flag or comptime D == devices.DeviceId.Type(.vdmos);
    if (!@import("builtin").is_test) {
        if (thermal) {
            std.log.err("{s}: a thermal node or the `thermal` flag asks for self-heating, which is unsupported", .{dev.name});
        } else std.log.err("{s}: {d} nodes, but {s} has {d} ports", .{ dev.name, dev.pins.len, device.modelName(D) orelse "the device", D.num_ports });
    }
    return if (thermal) error.UnsupportedSelfHeating else error.WrongNodeCount;
}

/// Refuses an instance ngspice heats and `D`'s file runs isothermal, on
/// ngspice's own condition: VDMOS with `thermal` on and RTHJC given
/// (vdmosload.c:81; vdmosset.c:401 makes the thermal nodes itself), and
/// B3SOI-FD/DD with SHMOD=1 and an RTH0 that is not 0 (b3soifdld.c:283,
/// b3soiddld.c:313; the instance's RTH0 defaults to the model's,
/// b3soifdset.c:905). Off that condition ngspice computes what ESPice does.
fn refuseSelfHeating(comptime D: type, dev: Device) !void {
    const vdmos = comptime D == devices.DeviceId.Type(.vdmos);
    const soi = comptime (D == devices.DeviceId.Type(.b3soifd) or D == devices.DeviceId.Type(.b3soidd));
    if (comptime !vdmos and !soi) return;
    const m = dev.model orelse return;
    const kvNumber = net_cards.kvNumber;
    const heats = if (vdmos)
        (kvNumber(dev.kv, "thermal") orelse kvNumber(m.kv, "thermal") orelse 0) != 0 and kvNumber(m.kv, "rthjc") != null
    else
        (kvNumber(m.kv, "shmod") orelse 0) == 1 and (kvNumber(dev.kv, "rth0") orelse kvNumber(m.kv, "rth0") orelse 0) != 0;
    if (!heats) return;
    if (!@import("builtin").is_test) std.log.err("{s}: ngspice self-heats it (model {s}), which is unsupported", .{ dev.name, m.name });
    return error.UnsupportedSelfHeating;
}

/// `D`'s polarity field and the card key that binds it, the first of
/// `polarity_fields` its Model has; null for a model with none (mesa).
fn polarityField(comptime D: type) ?[2][]const u8 {
    inline for (polarity_fields) |f| {
        if (@hasField(D.Model, f[0])) return f;
    }
    return null;
}

/// Writes polarity `p` (+1 N, -1 P) into `D`'s polarity field, marked
/// given (bsim4va: `if (!$param_given(type)) type = NMOS`).
fn setPolarity(comptime D: type, model: *D.Model, p: i8) !void {
    if (comptime polarityField(D)) |f| {
        // `-1` and `1` coerce to the field's i8, i64 or f64.
        if (p < 0) @field(model.*, f[0]) = -1 else @field(model.*, f[0]) = 1;
        markGiven(model, f[0]);
    } else if (p < 0) {
        // ponytail: mesa has no polarity parameter, so a P-type card on it
        // is refused rather than run N-type (silent NaN). Upgrade path: a
        // `type` parameter in the .va, as mos1 has.
        return error.UnsupportedDevice;
    }
}

/// The bytes that decide what `addSingleDevice` binds for `dev`: its type,
/// letter, pin count, model card row, the two positional numbers it reads
/// and every pair (all numbers). Null, so nothing is memoized, for a card
/// without a model row, a pair that is not a number, or a device that
/// calls VPI applications or keeps a row per instance. Borrows
/// `memo_key` until the next call.
fn memoKey(self: *NetBuilder, comptime D: type, dev: Device) !?[]const u8 {
    if (comptime device.modelName(D) == null) return null;
    const t = comptime Library.builtin(device.modelName(D).?);
    const vt = self.b.lib.vtable(t);
    if (vt.proto_add_row == null or vt.systf_calls.len != 0) return null;
    if (dev.model != null and dev.model_row == netlist.none) return null;
    for (dev.kv) |item| if (item.value != .num) return null;
    // A word after the model (an S card's ON) is not in the key: its card
    // builds its own row.
    for (dev.positional[@min(1, dev.positional.len)..]) |p| if (p == .name) return null;
    const k = &self.memo_key;
    k.clearRetainingCapacity();
    const head = [_]u64{
        @backingInt(t),                                                       dev.kind,
        dev.pins.len,                                                         if (dev.model == null) netlist.none else dev.model_row,
        @bitCast(Value.numberAt(dev.positional, 0) orelse std.math.nan(f64)), @bitCast(Value.numberAt(dev.positional, 1) orelse std.math.nan(f64)),
        dev.kv.len,
    };
    try k.appendSlice(self.arena, std.mem.asBytes(&head));
    for (dev.kv) |item| {
        const v: u64 = @bitCast(item.value.num);
        try k.appendSlice(self.arena, std.mem.asBytes(&[_]u64{ item.key.len, v }));
        try k.appendSlice(self.arena, item.key);
    }
    return k.items;
}

/// Refuses a card pair that neither `D.Model` nor `D.Instance` binds, as
/// ngspice refuses an unknown instance parameter: `ww=10u` for `w=10u`
/// would otherwise run with the default width (#35). `D`'s polarity key
/// (`polarityField`) is refused too where the model's kind sets polarity:
/// it binds Model here, but no ngspice instance table holds it, and
/// ngspice-44.2 stops on `m1 d g 0 0 nm type=-1` ("unknown parameter
/// (type)", nmos levels 1 and 14). Before, it flipped the device: -617.8 A
/// at level 1 (SpiceRack P4-013).
fn refuseUnknownKeys(arena: std.mem.Allocator, comptime D: type, dev: Device, kv: []const Kv) !void {
    const params = try arena.alloc(batch.Param, kv.len);
    for (kv, params) |item, *p| p.* = .{ .key = item.key, .value = null };
    const known = try arena.alloc(bool, kv.len);
    @memset(known, false);
    batch.bind.markKnown(D.Model, params, known);
    batch.bind.markKnown(D.Instance, params, known);
    const polarity = comptime if (polarityField(D)) |f| f[1] else "";
    const owned = polarity.len != 0 and (if (dev.model) |m| kindSetsPolarity(m.kind) else false);
    for (kv, known) |item, hit| if (!hit or (owned and std.mem.eql(u8, item.key, polarity))) {
        if (!@import("builtin").is_test) std.log.err("{s}: unknown instance parameter '{s}'", .{ dev.name, item.key });
        return error.UnknownParameter;
    };
}

/// The model card's LEVEL, 1 when absent.
fn modelLevel(dev: Device) !u16 {
    if (dev.model) |m| {
        if (try net_cards.numericParameter(m.kv, "level")) |l| return try castField(u16, l);
    }
    return 1;
}
