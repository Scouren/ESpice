//! Passive and controlled cards. In: R, C, L, K, E, F, G, H and switch
//! cards. Out: their instances; F, H and W cards bound to the V card whose
//! branch they sense.
//! Cites: ngspice res.c, resparam.c, restemp.c, capparam.c, capsetup.c,
//! indparam.c, indsetup.c, mutsetup.c, muttemp.c, cccsset.c, ccvsset.c.
//!
//! Contents:
//! - `pub fn addPassive(self: *NetBuilder, comptime D: type, dev: Device, comptime value_field: []const u8, comptime aliases: []const []const u8) !u32`
//! - `pub fn addBranchRef(self: *NetBuilder, comptime D: type, dev: Device, comptime default_gain: ?f64) !void`
//! - `pub fn addKinduc(self: *NetBuilder, dev: Device) !void`

const std = @import("std");
const core = @import("core");
const requests = core.query;
const numerics = core.numerics;
const devices = @import("spice.zig");
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
const net_branches = @import("net_branches.zig");
const net_devices = @import("net_devices.zig");
const net_cards = @import("net_cards.zig");
const NetBuilder = net_builder.NetBuilder;

/// ngspice const.h's CONSTmuZero, H/m, in its own order of operations.
const mu0 = 4.0 * std.math.pi * 1e-7;

/// R, C or L card. The value (`R1 a b 1k`) goes to parameter
/// `value_field`; `aliases` are card spellings only (`resistance=1k`),
/// never fields. Returns the row of the device's first internal unknown.
pub fn addPassive(
    self: *NetBuilder,
    comptime D: type,
    dev: Device,
    comptime value_field: []const u8,
    comptime aliases: []const []const u8,
) !u32 {
    if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
    if (comptime !@hasField(D.Model, value_field) and !@hasField(D.Instance, value_field))
        @compileError(@typeName(D) ++ ": no parameter `" ++ value_field ++ "` on Model or Instance");
    var model: D.Model = .{};
    var instance: D.Instance = .{};
    // The value before or after the model name (`R1 a b 1k rm`, `R1 a b rm
    // 1k`): ngspice 44.2 reads both, for R, C and L alike.
    const at: usize = if (dev.model != null and Value.nameAt(dev.positional, 0) != null) 1 else 0;
    // A value that did not fold (an undefined parameter) is an error, not
    // the 1 mOhm or zero that a missing value defaults to.
    if (dev.positional.len > at and Value.numberAt(dev.positional, at) == null) return error.UnresolvedParameter;
    // A value pair beats the positional value: ngspice parses the card's
    // pairs after INP2R/INP2C/INP2L read it (`R1 a b 1k r=2k` is 2k).
    const keyed = try net_cards.numericParameter(dev.kv, value_field) orelse for (aliases) |key| {
        if (try net_cards.numericParameter(dev.kv, key)) |v| break v;
    } else null;
    const given = keyed orelse Value.numberAt(dev.positional, at);
    var value = if (given) |v| (if (D == devices.resistor) net_cards.resistanceFloor(v) else v) else blk: {
        // Semiconductor resistor (ngspice restemp.c RESupdate_conduct):
        // R = RSH*(L-2*SHORT)/(W-2*NARROW), L and W defaulting to the
        // model's DEFL (`l`) and DEFW (`defw`, `w`), each 10u (ngspice 44.2:
        // `rsh=100` and `w=2u` read 500 Ohm), with res.c's IOPR spellings
        // `dw`, `dlr` and `res`. A non-positive result reads as open, as
        // ngspice's unchecked divide leaves it.
        if (comptime D == devices.resistor) {
            if (dev.model) |m| {
                const rsh = net_cards.kvNumber(m.kv, "rsh") orelse 0;
                const l = net_cards.kvNumber(dev.kv, "l") orelse net_cards.kvNumber(m.kv, "l") orelse 10e-6;
                const w = net_cards.kvNumber(dev.kv, "w") orelse net_cards.kvNumber(m.kv, "defw") orelse
                    net_cards.kvNumber(m.kv, "w") orelse 10e-6;
                if (l * w * rsh > 0) {
                    const narrow = net_cards.kvNumber(m.kv, "narrow") orelse net_cards.kvNumber(m.kv, "dw") orelse 0;
                    const rshort = net_cards.kvNumber(m.kv, "short") orelse net_cards.kvNumber(m.kv, "dlr") orelse 0;
                    const rr = (l - 2 * rshort) / (w - 2 * narrow) * rsh;
                    break :blk if (std.math.isFinite(rr) and rr > 0) rr else 1e30;
                }
                if (net_cards.kvNumber(m.kv, "r") orelse net_cards.kvNumber(m.kv, "res")) |mr| break :blk mr;
            }
            // restemp.c: "resistance too low or not given, set to 1 mOhm".
            break :blk 1e-3;
        }
        const card = dev.model orelse break :blk 0;
        if (comptime D == devices.capacitor) break :blk modelCapacitance(dev.kv, card.kv);
        if (comptime D == devices.inductor) break :blk modelInductance(dev.kv, card.kv);
        break :blk 0;
    };
    // ngspice instance factors, conduct = m/(R*scale), apply to an
    // explicit value too (`R5 6 0 10 scale=1K`, `R4 ... m=2`).
    if (comptime D == devices.resistor) {
        const scale = net_cards.kvNumber(dev.kv, "scale") orelse 1;
        const mult = net_cards.kvNumber(dev.kv, "m") orelse 1;
        value *= scale;
        value /= mult;
        // `ac=` is an AC-only resistance (restemp.c:112-118) with the same
        // instance factors; Circuit.linearizeAc swaps it in.
        if (net_cards.kvNumber(dev.kv, "ac")) |ac_r|
            try self.ac_res.append(self.arena, .{ .name = dev.name, .value = net_cards.resistanceFloor(ac_r) * scale / mult });
    }
    // The same factors on C and L: captemp.c:94 and indtemp.c:79 scale the
    // value; capload.c:74-79 and capacld.c:32-35 stamp m times the
    // capacitor, indload.c:111-113 and indacld.c:29 integrate L/m. C takes
    // m as its $mfactor, which every stamp path (DC, transient, AC, noise,
    // GPU and lane kernels) applies once. L folds it into the value
    // instead, so its one branch row carries the card's whole current, the
    // one i(L), `ic=` (indload.c:43) and a K card read. The temperature
    // factor (captemp.c:77-94, indtemp.c:63-79) multiplies in the model,
    // so it follows `.temp` and `.dc temp` without a rebind.
    var coupled: f64 = 0;
    if (comptime D == devices.capacitor or D == devices.inductor) {
        value *= try net_cards.numericParameter(dev.kv, "scale") orelse 1;
        const mult = try net_cards.numericParameter(dev.kv, "m") orelse 1;
        if (comptime D == devices.capacitor) instance.mfactor = mult else {
            coupled = value;
            value /= mult;
        }
    }
    // The model card first (`.model rm R(TC1=2e-3 TNOM=25)`), so the
    // instance pairs win over it, as in ngspice's RESmodel; the value last,
    // so the folded one binds, not the card's own `r=` or `c=` pair. A card
    // key no field binds and the lines above do not read warns once per
    // model, as ngspice's does (inpgmod.c:189).
    if (dev.model) |m| model = try net_devices.boundCard(self, D, model, m, dev.model_row);
    try net_cards.applyKv(&model, dev.kv);
    try net_cards.applyKv(&instance, dev.kv);
    _ = try net_builder.setParam(D, &model, &instance, value_field, value);
    // `$simparam` defaults after the last write: `tnom` is ngspice's
    // CKTnomTemp for R's tc1/tc2 (restemp.c), a card TNOM still wins.
    net_devices.deriveModel(D, &model, self.b, dev.pins.len);
    const nodes = try net_devices.deviceNodes(self, D, dev);
    const br = self.b.n;
    const card_row = self.b.cards.items.len;
    try self.b.addDevice(D, dev.name, &model, &instance, nodes);
    // `noisy=0`, or `noise=0` once `derive` copied it over: ngspice's
    // resnoise.c:57 skips the resistor, so `.noise` gives it no column.
    if (comptime D == devices.resistor) if (model.noisy == 0) {
        std.debug.assert(self.b.cards.items.len == card_row + 1);
        try self.quiet.append(self.arena, @intCast(card_row));
    };
    // A K card's M = k*sqrt(L1*L2) reads each L with its `scale` but
    // without its m (muttemp.c:50-56 on indtemp.c:79's value).
    if (comptime D == devices.inductor)
        try self.l.append(self.arena, .{ .name = dev.name, .branch = br, .value = coupled, .model = model });
    return br;
}

/// F, H or W card: a device whose 0 V control branch is the next link of
/// the sensed V card's chain (`VCard.tap`). `default_gain` null: no gain parameter.
pub fn addBranchRef(self: *NetBuilder, comptime D: type, dev: Device, comptime default_gain: ?f64) !void {
    if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
    const ctrl_name = Value.nameAt(dev.positional, 0) orelse return error.MissingControlSource;
    const ctrl = net_branches.vRow(self, ctrl_name) orelse return error.UnknownControlSource;

    var model: D.Model = .{};
    // W card: `W n+ n- Vctrl model`, model at positional[1] after the
    // control source. F/H put a number there, so fall back to positional[0].
    if (Value.nameAt(dev.positional, 1) orelse Value.nameAt(dev.positional, 0)) |name| {
        if (self.nl.findModel(name)) |m| try net_cards.applyKv(&model, m.kv);
    }
    // W: ngspice reads ON or OFF (cswparam.c:24-31), but no .op sees it:
    // cswload.c:65-71 takes the in-band state from CKTstate1, which the .op
    // never writes, so cswitch.va starts the band off whatever the word.
    // ponytail: `.tran uic` is the exception. Its load seeds HYST_ON into
    // state0 (cswload.c:39-56), dctran.c:387-392 copies that to state1, and
    // ngspice's W starts on in the band where ours starts off (KNOWN GAP
    // tran/switch_w_on_uic.sp). The model cannot tell a uic start from the
    // transient's .op: both evaluate with kind .ic and initial_step. Once
    // VerA can say so, the word maps to cswitch.va's state at a uic start.
    if (comptime D == devices.cswitch) _ = try net_devices.switchFlag(dev, 2);
    var instance: D.Instance = .{};
    if (comptime default_gain) |dflt| {
        // A gain that folded to no number (an undefined name) stops
        // ngspice-44.2 ("Undefined parameter [x]"), where the default
        // would run silently.
        if (dev.positional.len > 1 and dev.positional[1] == .expr) return error.UnresolvedParameter;
        _ = try net_builder.setParam(D, &model, &instance, "gain", Value.numberAt(dev.positional, 1) orelse net_cards.kvNumber(dev.kv, "gain") orelse dflt);
    }
    // F's m multiplies its output current (cccspar.c), cccs.va's own `m`.
    // H and W take none and never get here with one (`net_card.addDevice`).
    if (comptime @hasField(D.Model, "m")) if (try net_cards.numericParameter(dev.kv, "m")) |mv| {
        _ = try net_builder.setParam(D, &model, &instance, "m", mv);
    };
    try net_cards.applyKv(&instance, dev.kv);

    // (p, n, cp, cn): the model's `branch (cp, cn) ctrl` at `vsense` = 0
    // is an ammeter in series with the sensed source.
    const left = &self.v.items(.sensors)[ctrl];
    std.debug.assert(left.* != 0); // init counted this card
    left.* -= 1;
    const tap = &self.v.items(.tap)[ctrl];
    const cp = tap.*;
    tap.* = if (left.* == 0) self.v.items(.neg)[ctrl] else try self.b.addNode();
    const nodes = [4]u32{
        if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND,
        if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND,
        cp,
        tap.*,
    };
    try self.b.addDevice(D, dev.name, &model, &instance, nodes);
    // H also carries its own output branch, and ngspice names it i(h1).
    if (comptime @hasDecl(D, "U") and D == devices.ccvs)
        try net_branches.addBranchProbe(self, dev.name, net_devices.internalRow(D, "flowZ28pZ2cnZ29", self.b.n));
}

/// K card: mutual inductance between two L cards' branches.
pub fn addKinduc(self: *NetBuilder, dev: Device) !void {
    if (comptime !@hasDecl(devices.kinduc, "eval") or !@hasDecl(devices.inductor, "eval")) return error.UnsupportedDevice;
    const l1_name = Value.nameAt(dev.positional, 0) orelse return error.KinducMissingInductor;
    const l2_name = Value.nameAt(dev.positional, 1) orelse return error.KinducMissingInductor;
    const li1 = net_branches.lRow(self, l1_name) orelse return error.KinducUnknownInductor;
    const li2 = net_branches.lRow(self, l2_name) orelse return error.KinducUnknownInductor;
    const ibr1 = self.l.items(.branch)[li1];
    const ibr2 = self.l.items(.branch)[li2];
    var model: devices.kinduc.Model = .{};
    if (Value.numberAt(dev.positional, 2)) |k| model.k = try castField(@TypeOf(model.k), k);
    if (dev.model) |m| try net_cards.applyKv(&model, m.kv);
    try net_cards.applyKv(&model, dev.kv);
    // The card gives the coupling k; the device stamps M = k*sqrt(L1*L2)
    // (ngspice INDsetup).
    model.k = try castField(@TypeOf(model.k), model.k *
        @sqrt(self.l.items(.value)[li1] * self.l.items(.value)[li2]));
    // That M follows both windings' temperature factors, as ngspice's does
    // (muttemp.c:50-56 reads INDinduct after indtemp.c:63-79 scales it).
    winding(&model, "l1", self.l.items(.model)[li1]);
    winding(&model, "l2", self.l.items(.model)[li2]);
    try self.b.addDevice(devices.kinduc, dev.name, &model, &.{}, [2]u32{ ibr1, ibr2 });
}

// ---- private ----

/// A C card's capacitance from its model card `mkv` and its own pairs
/// `kv`: the model's CAP, else CJ*(W-NARROW)*(L-SHORT) +
/// 2*CJSW*((L-SHORT)+(W-NARROW)) (capsetup.c:31-97, captemp.c:54-73).
/// An instance without L is 0 long: ngspice reads DEFL but never uses it.
fn modelCapacitance(kv: []const Kv, mkv: []const Kv) f64 {
    if (net_cards.kvNumber(mkv, "cap")) |c| return c;
    const del = net_cards.kvNumber(mkv, "del") orelse 0;
    const w = (net_cards.kvNumber(kv, "w") orelse net_cards.kvNumber(mkv, "defw") orelse net_cards.kvNumber(mkv, "w") orelse 10e-6) -
        (net_cards.kvNumber(mkv, "narrow") orelse 2 * del);
    const l = (net_cards.kvNumber(kv, "l") orelse 0) - (net_cards.kvNumber(mkv, "short") orelse 2 * del);
    // const.h: epsZero = 1/(muZero c^2), SiO2's relative 3.9.
    const eps0 = 1.0 / (mu0 * 299792458.0 * 299792458.0);
    const thick = net_cards.kvNumber(mkv, "thick") orelse 0;
    const cj = net_cards.kvNumber(mkv, "cj") orelse net_cards.kvNumber(mkv, "cox") orelse
        if (thick > 0) (net_cards.kvNumber(mkv, "di") orelse 3.9) * eps0 / thick else 0;
    const cjsw = net_cards.kvNumber(mkv, "cjsw") orelse net_cards.kvNumber(mkv, "capsw") orelse 0;
    return cj * w * l + cjsw * 2 * (l + w);
}

/// An L card's inductance from its model card `mkv` and its own pairs
/// `kv` (indsetup.c:31-85, indtemp.c:54-59): the card's NT squared times
/// the coil's one-turn inductance, else the model's IND, else the model's
/// NT squared times it. One turn is MU*mu0*CSECT/LENGTH (CSECT from DIA
/// when given), times Lundin's correction when LENGTH and DIA or CSECT are.
fn modelInductance(kv: []const Kv, mkv: []const Kv) f64 {
    const length = net_cards.kvNumber(mkv, "length");
    const dia = net_cards.kvNumber(mkv, "dia");
    const csect = if (dia) |d| std.math.pi * d * d / 4 else net_cards.kvNumber(mkv, "csect") orelse 0;
    const len = length orelse 0;
    const turn = if (len > 0) (net_cards.kvNumber(mkv, "mu") orelse 1) * mu0 * csect / len else 0;
    const one = if (length != null and (dia != null or net_cards.kvNumber(mkv, "csect") != null)) turn * lundin(len, csect) else turn;
    if (net_cards.kvNumber(kv, "nt")) |nt| return one * nt * nt;
    if (net_cards.kvNumber(mkv, "ind")) |ind| return ind;
    const nt = net_cards.kvNumber(mkv, "nt") orelse 0;
    return one * nt * nt;
}

/// Nagaoka's coefficient by Lundin's handbook formula, x the coil's
/// diameter over its length (indsetup.c:142-172); 1 below 1 um, where
/// ngspice warns that it skips the correction.
fn lundin(len: f64, csect: f64) f64 {
    if (csect < 1e-12 or len < 1e-6) return 1;
    const x = @sqrt(csect / std.math.pi) * 2 / len;
    const xx = x * x;
    const xxxx = xx * xx;
    if (x < 1) return (1 + 0.383901 * xx + 0.017108 * xxxx) / (1 + 0.258952 * xx) - 4 * x / (3 * std.math.pi);
    const num = (@log(4 * x) - 0.5) * (1 + 0.383901 / xx + 0.017108 / xxxx);
    const kk = 0.093842 / xx + 0.002029 / xxxx - 0.000801 / (xx * xxxx);
    return 2 * (num / (1 + 0.258952 / xx) + kk) / (std.math.pi * x);
}

/// Copies L card `lm`'s temperature inputs onto winding `w` ("l1" or
/// "l2") of a K model, its `temp` only when the card gave one.
fn winding(k: *devices.kinduc.Model, comptime w: []const u8, lm: devices.inductor.Model) void {
    inline for (.{ "tnom", "dtemp", "tc1", "tc2" }) |f| @field(k, w ++ f) = @field(lm, f);
    const temp_bit = comptime for (devices.inductor.Model.given_params, 0..) |name, i| {
        if (std.mem.eql(u8, name, "temp")) break i;
    } else @compileError("inductor.va no longer asks $param_given(temp)");
    if (lm.given__.isSet(temp_bit)) {
        @field(k, w ++ "temp") = lm.temp;
        markGiven(k, w ++ "temp");
    }
}
