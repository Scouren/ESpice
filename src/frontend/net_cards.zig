//! Card value readers. In: a card's positional and `key=value` values.
//! Out: numbers, names, a source's DC/AC/DISTO/port settings, and refusals
//! logged with the card.
//! Cites: ngspice vsrcpar.c, isrcpar.c (source keywords).
//!
//! Contents:
//! - `pub fn sourceDc(dev: Device) ?f64`
//! - `pub fn sourcePort(dev: Device) !?struct { num: u16, z0: f64, band: requests.Port.Band }`
//! - `pub const SourceAc = struct`
//! - `pub fn sourceAc(dev: Device) ?SourceAc`
//! - `pub fn sourceDisto(dev: Device, key: []const u8) [2]f64`
//! - `pub fn finiteLineCoefficients(value: anytype) bool`
//! - `pub fn cplVector(kv: []const Kv, key: []const u8, out: []f64) !usize`
//! - `pub fn refuse(dev: Device, letter: u8, why: []const u8) error{UnsupportedCard}`
//! - `pub fn kvName(kv: []const Kv, key: []const u8) ?[]const u8`
//! - `pub fn numericParameter(kv: []const Kv, key: []const u8) !?f64`
//! - `pub fn applyKv(target: anytype, kv: []const Kv) !void`
//! - `pub fn bindKv(bind: *const fn ([*]u8, []const batch.Param) batch.BindStatus, blob: [*]u8, kv: []const Kv) !void`
//! - `pub fn ignoredKeys(arena: std.mem.Allocator, comptime T: type, kv: []const Kv) ![]const []const u8`
//! - `pub const NgspiceKey`
//! - `pub const ngspice_model_keys: []const u8`
//! - `pub fn checkModelKeys(arena: std.mem.Allocator, comptime T: type, model: ?[]const u8, card: []const u8, kv: []const Kv) ![]const []const u8`
//! - `pub fn ngspiceKey(model: []const u8, key: []const u8) ?NgspiceKey`
//! - `pub fn copyNames(arena: std.mem.Allocator, names: []const []const u8) ![]const []const u8`
//! - `pub fn kvNumber(kv: []const Kv, key: []const u8) ?f64`
//! - `pub fn resistanceFloor(r: f64) f64`

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

const net_devices = @import("net_devices.zig");

/// A source's AC excitation (`sourceAc`): re + j·im, and `unit`, its
/// derivative in the magnitude.
pub const SourceAc = struct { re: f64, im: f64, unit: [2]f64 };

/// What ngspice does with one `.model` key of one device: a row of
/// ngspice_model_keys.tsv.
pub const NgspiceKey = struct {
    /// The values at which ngspice computes what it computes with the key
    /// absent: none known, one (`at`), or `any`: a key nothing reads, only a
    /// SOA warning reads, only self-heating behind a thermal node or flag
    /// the builder refuses reads, or the builder applies itself.
    inert: union(enum) { none, at: f64, any },
    /// True when only ngspice's noise analysis reads the key.
    noise_only: bool,
    /// ngspice's description of the key: the physics it sets.
    what: []const u8,
};

/// Per ESPice catalog model, one row per key an ngspice `.model` card of
/// that device sets (its model and instance IFparm tables,
/// inpgmod.c:131-160): model, key, inert value (`-` none, `*` any),
/// `noise` or `-`, and ngspice's description. Generated from ngspice-45 by
/// tools/ngspice_model_keys.py, whose doc says how each column is read off
/// the source. ngspice 44.2 takes every key but ngspice-45's additions:
/// diode isw nz perim tbv1 vjsw, bsimsoi ddmod noimod, hisim2 lpgd3 pgd3
/// ppgd3 wpgd3, mes ic.
pub const ngspice_model_keys: []const u8 = @embedFile("ngspice_model_keys.tsv");

/// Model card keys the frontend reads itself rather than binding: LEVEL and
/// SWNQS pick the device (`resolveDeviceId`), LMIN..WMAX and WNFLAG pick the
/// bin (card_table.zig, reader_models.zig), the rest are prepared_soa.zig's
/// SOA limits. M, like LEVEL, ngspice skips on a model card with no word
/// (inpgmod.c:139-143).
const read_by_builder = std.StaticStringMap(void).initComptime(.{
    .{"level"},   .{"m"},       .{"swnqs"},   .{"lmin"},    .{"lmax"},    .{"wmin"},
    .{"wmax"},    .{"wnflag"},  .{"vgs_max"}, .{"vgd_max"}, .{"vgb_max"}, .{"vds_max"},
    .{"vbs_max"}, .{"vbd_max"}, .{"vbe_max"}, .{"vbc_max"}, .{"vce_max"}, .{"bv_max"},
});

/// Model card keys net_passive.addPassive reads itself for an R, C or L
/// card (res.c, cap.c and ind.c spellings no .va declares), per type so a
/// MOS card's stray `l=` still warns.
const read_by_passive = .{
    .{ devices.resistor, &[_][]const u8{ "rsh", "narrow", "dw", "short", "dlr", "defw", "w", "l", "res" } },
    .{ devices.capacitor, &[_][]const u8{ "cap", "cj", "cox", "cjsw", "capsw", "defw", "w", "defl", "l", "narrow", "short", "del", "di", "thick" } },
    .{ devices.inductor, &[_][]const u8{ "ind", "csect", "dia", "length", "nt", "mu" } },
};

/// A source card's DC value as ngspice-44.2 sets it (inp2v.c, inp2i.c):
/// a bare number straight after the nodes, over every keyword; else the
/// last `DC v`, `DC(v)`, `dc=v` or, on an I card, `c=v` (isrc.c's second
/// name for `dc`). Null when the card gives none. Measured into 1k: `v1 a
/// 0 1 dc=3` is 1 V, `dc 2 dc 3` is 3 V, `i1 0 a dc=3m c=2m` is 2 V, and
/// no other bare number is DC: `v1 a 0 3 ac 1` is 3 V, while `pulse(...)
/// 3`, `ac 1 3`, `pwl(...) r 0` and `td 1n` hold 0, and `portnum 1 z0 50
/// 3` stops the deck. The parser keeps no order between `DC v` and
/// `dc=v`; `net_waves.refuseUnknownKey` refuses a card with both.
pub fn sourceDc(dev: Device) ?f64 {
    if (dev.positional.len > 0 and dev.positional[0] == .num) return dev.positional[0].num;
    var dc: ?f64 = null;
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .group => |group| {
            if (std.mem.eql(u8, group.name(), "dc") and group.args().len > 0)
                dc = group.args()[0].number() orelse 0;
        },
        .name => |name| if (std.mem.eql(u8, name, "dc")) {
            dc = Value.numberAt(dev.positional, idx + 1) orelse dc;
        },
        else => {},
    };
    for (dev.kv) |item| if (std.mem.eql(u8, item.key, "dc") or std.mem.eql(u8, item.key, "c")) {
        dc = item.value.number() orelse dc;
    };
    return dc;
}

/// The RF port of a V card (`VP1 in 0 DC 0 AC 1 portnum 1 z0 50`), null
/// when `portnum` is not given (ngspice vsrctemp.c:74-82). `z0` defaults
/// to 50 ohm. Both `portnum 1` and `portnum=1` are accepted. A given
/// `portnum` outside 1..1024 or a non-positive `z0` is an error, not a
/// plain source. `hblin_h=` and `hblin_s=` (ESPice's) name the port's
/// `.hblin` sideband.
pub fn sourcePort(dev: Device) !?struct { num: u16, z0: f64, band: requests.Port.Band } {
    const num_f = blk: {
        if (kvNumber(dev.kv, "portnum")) |v| break :blk v;
        for (dev.positional, 0..) |pos, idx| {
            if (pos != .name or !std.mem.eql(u8, pos.name, "portnum")) continue;
            break :blk Value.numberAt(dev.positional, idx + 1) orelse return null;
        }
        return null;
    };
    const z0 = blk: {
        if (kvNumber(dev.kv, "z0")) |v| break :blk v;
        for (dev.positional, 0..) |pos, idx| {
            if (pos != .name or !std.mem.eql(u8, pos.name, "z0")) continue;
            break :blk Value.numberAt(dev.positional, idx + 1) orelse 50.0;
        }
        break :blk 50.0;
    };
    if (!(num_f >= 1) or num_f > 1024 or !(z0 > 0)) return error.InvalidAnalysisArguments;
    const h = kvNumber(dev.kv, "hblin_h") orelse 0;
    const s = kvNumber(dev.kv, "hblin_s") orelse 1;
    if (h != @trunc(h) or @abs(h) > 1024 or @abs(s) != 1) return error.InvalidAnalysisArguments;
    return .{ .num = @intFromFloat(num_f), .z0 = z0, .band = .{ .harmonic = @intFromFloat(h), .sign = @intFromFloat(s) } };
}

/// The `AC` spec of a source card as its complex excitation
/// mag * e^(j*phase*pi/180) and its derivative in mag, `unit`; null when the
/// card names no `AC`, so an .ac run does not drive it (ngspice
/// vsrcacld.c:171, isrcacld.c:36). Bare `AC` is mag 1 phase 0 and `AC mag`
/// is phase 0 (vsrcpar.c:59-72, vsrctemp.c:38-43); the keyword forms
/// `ac=mag`, `acmag=` and `acphase=` are vsrc.c's and isrc.c's "ac",
/// "acmag" and "acphase" parameters (sens-ac-1.sp's `ac=42mA`). Phase is
/// in degrees.
pub fn sourceAc(dev: Device) ?SourceAc {
    var mag: f64 = 1;
    var phase: f64 = 0;
    var given = false;
    if (kvNumber(dev.kv, "ac") orelse kvNumber(dev.kv, "acmag")) |m| {
        mag = m;
        given = true;
    }
    if (kvNumber(dev.kv, "acphase")) |p| {
        phase = p;
        given = true;
    }
    if (!given) for (dev.positional, 0..) |pos, idx| {
        switch (pos) {
            // `AC 1 SIN 0 1 1k`: numberAt returns null on the next
            // keyword, so the trailing waveform never reads as a phase.
            .name => |name| {
                if (!std.mem.eql(u8, name, "ac")) continue;
                if (Value.numberAt(dev.positional, idx + 1)) |m| {
                    mag = m;
                    if (Value.numberAt(dev.positional, idx + 2)) |p| phase = p;
                }
            },
            .group => |group| {
                if (!std.mem.eql(u8, group.name(), "ac")) continue;
                if (group.args().len > 0) mag = group.args()[0].number() orelse mag;
                if (group.args().len > 1) phase = group.args()[1].number() orelse phase;
            },
            else => continue,
        }
        given = true;
        break;
    };
    if (!given) return null;
    const rad = phase * (std.math.pi / 180.0);
    const unit = [2]f64{ @cos(rad), @sin(rad) };
    return .{ .re = mag * unit[0], .im = mag * unit[1], .unit = unit };
}

/// `DISTOF1 [mag [phase]]` or `DISTOF2 ...` (`key`) on a source card
/// (ngspice vsrcpar.c:180-205): the bare keyword is mag 1 phase 0, one
/// number sets the magnitude, two set both. `{0, 0}` when the card never
/// names it, so it is no drive.
pub fn sourceDisto(dev: Device, key: []const u8) [2]f64 {
    if (kvNumber(dev.kv, key)) |mag| return .{ mag, 0 };
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .name => |name| if (std.mem.eql(u8, name, key)) return .{
            Value.numberAt(dev.positional, idx + 1) orelse 1.0,
            Value.numberAt(dev.positional, idx + 2) orelse 0.0,
        },
        else => {},
    };
    return .{ 0, 0 };
}

/// True when every float in `value`, nested arrays and structs included, is
/// finite. Setup-time only.
pub fn finiteLineCoefficients(value: anytype) bool {
    switch (@typeInfo(@TypeOf(value))) {
        .float => return std.math.isFinite(value),
        .bool => {},
        .array => for (value) |item| {
            if (!finiteLineCoefficients(item)) return false;
        },
        .@"struct" => |info| inline for (info.field_names) |name| {
            if (!finiteLineCoefficients(@field(value, name))) return false;
        },
        else => @compileError("unexpected native line coefficient type"),
    }
    return true;
}

/// Reads the CPL matrix `key` into `out` and returns its entry count: the
/// packed upper triangle is the `key=` value and the unnamed values after it.
/// 0 when the card has no `key`.
pub fn cplVector(kv: []const Kv, key: []const u8, out: []f64) !usize {
    for (kv, 0..) |entry, start| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        var i = start;
        var n: usize = 0;
        while (i < kv.len and (i == start or kv[i].key.len == 0)) : (i += 1) {
            const value = kv[i].value.number() orelse return error.InvalidParameterValue;
            if (!std.math.isFinite(value)) return error.NonFiniteParameter;
            if (n == out.len) return error.UnsupportedTransmissionLineParameters;
            out[n] = value;
            n += 1;
        }
        return n;
    }
    return 0;
}

/// Logs why element `dev` (card letter `letter`) is refused.
pub fn refuse(dev: Device, letter: u8, why: []const u8) error{UnsupportedCard} {
    if (!@import("builtin").is_test) std.log.err("{c} element '{s}': {s}", .{ letter, dev.name, why });
    return error.UnsupportedCard;
}

pub fn kvName(kv: []const Kv, key: []const u8) ?[]const u8 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
        .name => |n| n,
        else => null,
    };
    return null;
}

/// The number `key=` gives, null when absent. A present key that is not a
/// finite number is an error, never a silent fall back to the default.
pub fn numericParameter(kv: []const Kv, key: []const u8) !?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) {
        const value = item.value.number() orelse return error.UnresolvedParameter;
        if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        return value;
    };
    return null;
}

/// Binds card pairs onto a built-in's Model or Instance through the
/// device's own binder, the one every loaded device uses too.
pub fn applyKv(target: anytype, kv: []const Kv) !void {
    const name, const is_model = comptime net_devices.ownerOf(@TypeOf(target.*));
    const vt = device.vtable(name);
    try bindKv(if (is_model) vt.bind_model else vt.bind_instance, @ptrCast(target), kv);
}

/// Binds `kv` onto a param blob. A non-numeric value reaches the binder as
/// null, which it rejects for a key it knows.
pub fn bindKv(bind: *const fn ([*]u8, []const batch.Param) batch.BindStatus, blob: [*]u8, kv: []const Kv) !void {
    var buf: [4096]u8 align(@alignOf(batch.Param)) = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&buf, core.gpa);
    const a = fallback.allocator();
    const params = try a.alloc(batch.Param, kv.len);
    defer a.free(params);
    for (kv, params) |item, *p| p.* = .{ .key = item.key, .value = item.value.number() };
    try bind(blob, params).unwrap();
}

/// The keys of model card pairs `kv` that model type `T` does not bind and
/// the builder does not read, in card order: what ngspice prints as
/// "unrecognized parameter (key) - ignored" (inpgmod.c:189). The slice
/// lives in `arena`.
pub fn ignoredKeys(arena: std.mem.Allocator, comptime T: type, kv: []const Kv) ![]const []const u8 {
    const params = try arena.alloc(batch.Param, kv.len);
    for (kv, params) |item, *p| p.* = .{ .key = item.key, .value = null };
    const known = try arena.alloc(bool, kv.len);
    @memset(known, false);
    batch.bind.markKnown(T, params, known);
    const own: []const []const u8 = comptime blk: {
        for (read_by_passive) |row| {
            if (@hasDecl(row[0], "Model")) if (row[0].Model == T) break :blk row[1];
        }
        break :blk &.{};
    };
    var ignored: std.ArrayList([]const u8) = .empty;
    for (kv, known) |item, hit| {
        const passive = for (own) |key| {
            if (std.mem.eql(u8, key, item.key)) break true;
        } else false;
        if (hit or passive or item.key.len == 0 or read_by_builder.has(item.key)) continue;
        try ignored.append(arena, item.key);
    }
    return ignored.items;
}

/// Checks model card `card`'s pairs `kv` against model type `T`, by
/// ngspice's tables for catalog model `model`, for each key `T` leaves
/// unbound and the builder does not read:
/// - a key ngspice also lacks logs ngspice's "unrecognized parameter (key)
///   - ignored" (inpgmod.c:189) and runs;
/// - a key at its inert value (`NgspiceKey.inert`: one value or any, or a
///   bsim3 VERSION that picks bsim3.va's code) runs with no word:
///   ngspice's answer is the same;
/// - a noise-only key at any other value is returned, for the caller to
///   record as a gap only a noise analysis refuses;
/// - any other key logs what it sets, and the card fails with
///   `UnmodelledParameter`: ESPice would give a wrong number with no error.
/// `model` is null for an HDL module card, whose keys only warn. The
/// returned keys live in `arena`.
pub fn checkModelKeys(arena: std.mem.Allocator, comptime T: type, model: ?[]const u8, card: []const u8, kv: []const Kv) ![]const []const u8 {
    const quiet = @import("builtin").is_test;
    const m = model orelse "";
    var refused = false;
    var noise: std.ArrayList([]const u8) = .empty;
    for (try ignoredKeys(arena, T, kv)) |key| {
        const k = ngspiceKey(m, key) orelse {
            if (!quiet) std.log.warn("model {s}: unrecognized parameter ({s}) - ignored", .{ card, key });
            continue;
        };
        const value = kvNumber(kv, key);
        const at_inert = switch (k.inert) {
            .none => false,
            .at => |i| if (value) |v| v == i else false,
            .any => true,
        };
        if (at_inert or versionPicksModel(m, key, value)) continue;
        if (k.noise_only) {
            try noise.append(arena, key);
            continue;
        }
        refused = true;
        if (quiet) continue;
        if (k.inert == .at)
            std.log.err("model {s}: '{s}' ({s}) changes ngspice's answer and ESPice's {s} does not model it; only {s}={d} runs", .{ card, key, k.what, m, key, k.inert.at })
        else
            std.log.err("model {s}: '{s}' ({s}) changes ngspice's answer and ESPice's {s} does not model it", .{ card, key, k.what, m });
    }
    if (refused) return error.UnmodelledParameter;
    return noise.items;
}

/// The ngspice_model_keys.tsv row of key `key` (lowercase) of ESPice catalog
/// model `model`; null when ngspice's tables for it lack the key, and for a
/// model ngspice has no built-in table for.
pub fn ngspiceKey(model: []const u8, key: []const u8) ?NgspiceKey {
    const table = ngspice_model_keys;
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\n{s}\t{s}\t", .{ model, key }) catch return null;
    const at = std.mem.indexOf(u8, table, needle) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, table, at + 1, '\n') orelse table.len;
    var cols = std.mem.splitScalar(u8, table[at + needle.len .. end], '\t');
    const inert = cols.next().?;
    const noise = cols.next().?;
    return .{
        // The generator writes `-`, `*` or a Python float repr.
        .inert = if (std.mem.eql(u8, inert, "-")) .none else if (std.mem.eql(u8, inert, "*")) .any else .{ .at = std.fmt.parseFloat(f64, inert) catch unreachable },
        .noise_only = std.mem.eql(u8, noise, "noise"),
        .what = cols.rest(),
    };
}

pub fn copyNames(arena: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copied = try arena.alloc([]const u8, names.len);
    for (names, copied) |name, *copy| copy.* = try arena.dupe(u8, name);
    return copied;
}

pub fn kvNumber(kv: []const Kv, key: []const u8) ?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return item.value.number();
    return null;
}

/// A card's resistance as ngspice resparam.c keeps it: the sign stays and
/// |R| is at least 1e-12 (0 is +1e-12), so `R1 a 0 -2k` is a negative
/// resistor, not the 1 mOhm restemp.c gives a missing value.
pub fn resistanceFloor(r: f64) f64 {
    return if (@abs(r) < 1e-12) std.math.copysign(@as(f64, 1e-12), r) else r;
}

// ---- private ----

/// True when `key` is a bsim3 card's VERSION that picks the code bsim3.va
/// is: ngspice runs BSIM3 3.3.0 for 3.3 and BSIM3v0/v1/v32 for 3.0-3.2
/// (inpdomod.c:271-288). VERSION is a string field there, so the generated
/// table has no inert value for it.
fn versionPicksModel(model: []const u8, key: []const u8, value: ?f64) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, model, "bsim3") and std.mem.eql(u8, key, "version") and v >= 3.3 and v < 3.4;
}
