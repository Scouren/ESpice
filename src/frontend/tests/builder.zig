//! Builder tests: netlist devices → `device.Circuit` stamps and source waveforms, against hand-worked values.
const std = @import("std");
const builder = @import("builder");
const devices = @import("builder").spice;
const device = @import("device");
const netlist = @import("netlist");
const Value = netlist.Value;
const Builder = builder.Builder;
const applySourceWaveform = builder.test_access.applySourceWaveform;
const pwlSlot = builder.test_access.pwlSlot;
const pwlCapacity = builder.test_access.pwlCapacity;
const Wave = builder.test_access.Wave;
const castField = device.abi.bind.castField;
const bindKv = builder.test_access.bindKv;
const ta = builder.test_access;

/// A pinless, modelless card view: what the source binders read.
fn cardWith(name: []const u8, kind: u8, positional: []const Value, kv: []const netlist.Kv) netlist.Netlist.View {
    return .{ .name = name, .kind = kind, .pins = &.{}, .positional = positional, .kv = kv, .model = null, .subckt_instance = 0 };
}

const Compiled = struct { nb: builder.NetBuilder, circuit: device.Circuit };

/// `source` (an ngspice deck, title line first) parsed and built on `a`,
/// then frozen with the protos and circuit on `gpa` (`Builder.gpa`). The
/// caller deinits `circuit`; `nb` stays readable while `a` lives.
fn compileDeck(a: std.mem.Allocator, gpa: std.mem.Allocator, source: []const u8) !Compiled {
    const nl = try netlist.parse(a, source);
    const lib = try a.create(device.Library);
    lib.* = try device.Library.init(a);
    const b = try a.create(Builder);
    b.* = try Builder.init(gpa, lib);
    errdefer b.deinit();
    var nb = try builder.NetBuilder.init(a, b, nl);
    try nb.build();
    const circuit = try b.compile();
    nb.b = undefined; // consumed by compile; a test that reads it trips in Debug
    return .{ .nb = nb, .circuit = circuit };
}

/// The value of the first parameter `name` the circuit's first batch collects.
fn firstParam(a: std.mem.Allocator, circuit: *const device.Circuit, name: []const u8) !f64 {
    var params: std.ArrayList(device.abi.ParamRef) = .empty;
    const batch = circuit.batches[0];
    try batch.hooks.collect_params(batch.ctx, a, &params).unwrap();
    for (params.items) |param| if (std.mem.eql(u8, param.param_name, name)) return param.get();
    return error.MissingParameter;
}

/// checkModelKeys on a card of catalog model `id` that holds `key=value` only.
fn checkOne(a: std.mem.Allocator, comptime id: devices.DeviceId, key: []const u8, value: f64) ![]const []const u8 {
    const kv = [_]netlist.Kv{.{ .key = key, .value = .{ .num = value } }};
    return ta.checkModelKeys(a, devices.DeviceId.Type(id).Model, @tagName(id), "m", &kv);
}

/// Whether the builder made a prototype of built-in device `type_name`.
fn hasProto(b: *const Builder, comptime type_name: []const u8) bool {
    for (b.protos.items) |p| if (std.mem.eql(u8, p.type_name, device.vtable(type_name).name)) return true;
    return false;
}

// Source binding: the two things that break silently when the .va and the
// binder drift apart. The flattened PWL table (a typo in a mangled field name
// is skipped by @hasField, not caught) and the -1 PULSE sentinels (if a
// default stops being -1, an unspecified PULSE becomes a 2 ns square wave).

test "V card: PWL table lands in the flattened Model slots" {
    const items = [_]Value{
        .{ .name = "PWL" },
        .{ .num = 0.0 },
        .{ .num = 0.0 },
        .{ .num = 10e-3 },
        .{ .num = 5.0 },
        .{ .num = 20e-3 },
        .{ .num = 0.0 },
    };
    const positional = [_]Value{.{ .group = .{ .items = &items } }};
    const dev = cardWith("Vc", 'v', &positional, &.{});

    var model: devices.vsource.Model = .{};
    applySourceWaveform(&model, dev);

    try std.testing.expectEqual(@as(i64, @backingInt(Wave.pwl)), @as(i64, model.waveform));
    try std.testing.expectEqual(@as(i64, 3), @as(i64, model.pwl_len));
    try std.testing.expectEqual(@as(f64, 0.0), @field(model, pwlSlot("pwl_times", 0)));
    try std.testing.expectEqual(@as(f64, 10e-3), @field(model, pwlSlot("pwl_times", 1)));
    try std.testing.expectEqual(@as(f64, 5.0), @field(model, pwlSlot("pwl_values", 1)));
    try std.testing.expectEqual(@as(f64, 20e-3), @field(model, pwlSlot("pwl_times", 2)));
    // Slot 3 is past the table and must stay at its default, or the model's
    // `pwl_len`-bounded loops would walk into stale data.
    try std.testing.expectEqual(@as(f64, 0.0), @field(model, pwlSlot("pwl_times", 3)));
    try std.testing.expect(pwlCapacity(devices.vsource.Model) >= 3);
}

test "V/I cards: unspecified PULSE edges stay at the -1 sentinel" {
    // PULSE(0 5): no TR/TF/PW/PER. resolvePulseDefaults fills these from the
    // .tran card; until it runs they must still read as "unset".
    const items = [_]Value{ .{ .name = "PULSE" }, .{ .num = 0.0 }, .{ .num = 5.0 } };
    const positional = [_]Value{.{ .group = .{ .items = &items } }};
    const dev = cardWith("V1", 'v', &positional, &.{});

    inline for (.{ devices.vsource, devices.isource }) |D| {
        var model: D.Model = .{};
        applySourceWaveform(&model, dev);
        try std.testing.expectEqual(@as(f64, 5.0), model.pulse_v2);
        try std.testing.expect(model.pulse_tr < 0);
        try std.testing.expect(model.pulse_tf < 0);
        try std.testing.expect(model.pulse_pw < 0);
        try std.testing.expect(model.pulse_per < 0);
    }
}

const ModeBlob = struct { mode: i8 = 7 };

fn bindMode(dest: [*]u8, params: []const device.abi.Param) device.abi.BindStatus {
    return device.abi.bind.apply(@as(*ModeBlob, @ptrCast(@alignCast(dest))), params);
}

test "numeric field binding rejects invalid native and dynamic parameter values" {
    try std.testing.expectEqual(@as(i8, -128), try castField(i8, -128));
    try std.testing.expectEqual(@as(i8, 127), try castField(i8, 127));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i8, 128));
    try std.testing.expectEqual(@as(i8, 2), try castField(i8, 1.5));
    try std.testing.expectEqual(@as(i8, -1), try castField(i8, -1.5));
    try std.testing.expectEqual(@as(u16, 104), try castField(u16, 103.60));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i8, 127.5));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u16, -1));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u16, 65536));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i64, 0x1p63));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u64, 0x1p64));
    try std.testing.expectEqual(std.math.minInt(i64), try castField(i64, -0x1p63));
    try std.testing.expectError(error.NonFiniteParameter, castField(i64, std.math.inf(f64)));
    try std.testing.expectError(error.NonFiniteParameter, castField(bool, std.math.nan(f64)));
    try std.testing.expectError(error.ParameterOutOfRange, castField(f32, 1e300));

    var blob: ModeBlob = .{};
    try bindKv(bindMode, @ptrCast(&blob), &.{.{ .key = "unknown", .value = .{ .num = 1e300 } }});
    try std.testing.expectEqual(@as(i8, 7), blob.mode);
    try std.testing.expectError(error.ParameterOutOfRange, bindKv(bindMode, @ptrCast(&blob), &.{.{ .key = "mode", .value = .{ .num = 128 } }}));
    try std.testing.expectError(error.UnresolvedParameter, bindKv(bindMode, @ptrCast(&blob), &.{.{ .key = "mode", .value = .{ .name = "unresolved" } }}));
}

test "a BJT card's ignored keys are the ones ngspice 44.2 calls unrecognized" {
    // Oracle: ngspice 44.2 on `.model qn npn level=1 vje=0.7 cbcp=1e-15
    // tbf1=5e-3 tref=25 vbe_max=1 bogus=1` prints "unrecognized parameter"
    // for cbcp and bogus only (inpgmod.c:189). Before the fix gummel_poon
    // had no vje or tbf1, and they were dropped with no word.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const kv = [_]netlist.Kv{
        .{ .key = "level", .value = .{ .num = 1 } },
        .{ .key = "vje", .value = .{ .num = 0.7 } },
        .{ .key = "cbcp", .value = .{ .num = 1e-15 } },
        .{ .key = "tbf1", .value = .{ .num = 5e-3 } },
        .{ .key = "tref", .value = .{ .num = 25 } },
        .{ .key = "vbe_max", .value = .{ .num = 1 } },
        .{ .key = "bogus", .value = .{ .num = 1 } },
        .{ .key = "", .value = .{ .name = "npn" } },
    };
    const got = try ta.ignoredKeys(arena.allocator(), devices.DeviceId.Type(.gummel_poon).Model, &kv);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "cbcp", "bogus" }), got);
}

test "an alternate spelling binds on the models ngspice 44.2 accepts it on, and warns on the rest" {
    // Oracle: ngspice 44.2 on `.model qv npn level=4 is=1e-16 ik=1e-3
    // ikf=1e-3 tref=25 me=0.33 bogus=1`, `.model mv vdmos vto=1 kp=1 cj0=1p
    // cj=1p pb=0.8 cjo=1p vj=0.8 vt0=1 trs1=1e-3 bogus=1`, `.model m1m nmos
    // level=1 vto=1 kp=1e-4 tref=25 vt0=1 tnom=27 bogus=1` and `.model rr r
    // r=1 tref=25 noise=1 bogus=1` prints "unrecognized parameter" for these
    // keys only. Before the fix one alias table served every model, so VBIC
    // bound ik, VDMOS cj0/cj/pb/vt0 and every model with a tnom tref.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (model, the card's keys, the keys ngspice calls unrecognized)
    inline for (.{
        .{ devices.DeviceId.Type(.vbic13_4t), "level is ik ikf tref me bogus", "ik bogus" },
        .{ devices.DeviceId.Type(.vdmos), "vto kp cj0 cj pb cjo vj vt0 trs1 bogus", "cj0 cj pb vt0 bogus" },
        .{ devices.DeviceId.Type(.mos1), "level vto kp tref vt0 tnom bogus", "tref bogus" },
        .{ devices.resistor, "r tref noise bogus", "tref bogus" },
    }) |case| {
        var kv: std.ArrayList(netlist.Kv) = .empty;
        var keys = std.mem.tokenizeScalar(u8, case[1], ' ');
        while (keys.next()) |key| try kv.append(a, .{ .key = key, .value = .{ .num = 1 } });
        const got = try ta.ignoredKeys(a, case[0].Model, kv.items);
        try std.testing.expectEqualStrings(case[2], try std.mem.join(a, " ", got));
    }
}

test "every alternate spelling binds exactly where ngspice's table holds it" {
    // Oracle: ngspice-45's model tables (ngspice_model_keys.tsv, generated
    // from the source), over the spellings the shared alias table once
    // bound on every model with the field. Each pair listed is a key ngspice
    // accepts and the model lacks: bsim3.va is a DC core with no junction
    // capacitance (cj, pb), and HiSIM's noise selector is noise-only. Those
    // reach checkModelKeys, which refuses them away from their inert value.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spellings = [_][]const u8{ "vt0", "va", "vb", "ik", "ccs", "me", "mc", "ms", "tref", "cj0", "cj", "pb", "trs1", "ctc", "tvj", "noise" };
    var wrong: std.ArrayList(u8) = .empty;
    inline for (.{
        .gummel_poon, .vbic13_4t,  .hicumL2_va, .diode,    .mos1,    .mos2,       .mos3,    .mos6,
        .mos9,        .bsim1,      .bsim2,      .bsim3,    .bsim4va, .bsimsoi_va, .b3soifd, .b3soidd,
        .hisim2_va,   .hisimhv_va, .jfet,       .jfet2,    .mes,     .mesa,       .hfet1,   .hfet2,
        .vdmos,       .resistor,   .capacitor,  .inductor,
    }) |id| {
        const name = @tagName(@as(devices.DeviceId, id));
        for (spellings) |key| {
            const kv = [_]netlist.Kv{.{ .key = key, .value = .{ .num = 1 } }};
            const binds = (try ta.ignoredKeys(a, devices.DeviceId.Type(id).Model, &kv)).len == 0;
            if (binds != (ta.ngspiceKey(name, key) != null)) try wrong.print(a, "{s}:{s} ", .{ name, key });
        }
    }
    try std.testing.expectEqualStrings("bsim3:cj bsim3:pb hisim2_va:noise hisimhv_va:noise ", wrong.items);
}

test "a key ngspice also lacks warns and the card runs" {
    // Oracle: ngspice 44.2 prints "unrecognized parameter" for a BJT card's
    // cbcp and bogus and runs (inpgmod.c:189).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "cbcp", "bogus" }) |key| {
        try std.testing.expect(ta.ngspiceKey("gummel_poon", key) == null);
        try std.testing.expectEqual(@as(usize, 0), (try checkOne(a, .gummel_poon, key, 1)).len);
    }
    // An HDL module card has no ngspice table, so even rco only warns.
    const kv = [_]netlist.Kv{.{ .key = "rco", .value = .{ .num = 10 } }};
    try std.testing.expectEqual(@as(usize, 0), (try ta.checkModelKeys(a, devices.DeviceId.Type(.gummel_poon).Model, null, "m", &kv)).len);
    try std.testing.expect(ta.ngspiceKey("psp103", "rco") == null);
}

test "a key an ESPice-only LEVEL's model lacks warns, and the card runs" {
    // Oracle: Xyce on `.model nm nmos level=103 ... cgovo=2e-10` warns "No
    // model parameter CGOVO found ..., parameter ignored", the rule ngspice
    // applies to a key its table lacks (inpgmod.c:189); PSP 103 declares no
    // CGOVO (SpiceRack P4-013). ESPice's own `nmos` LEVELs (1040, 72, 76, 77,
    // 78) name models ngspice has no table for, so `boundCard` passes their
    // catalog name and such a key takes `checkModelKeys`' warning branch:
    // `ignoredKeys` lists it and no ngspice row holds it. The 2026-11-10
    // binary, older than `checkModelKeys`, ran it with no word.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kv = [_]netlist.Kv{.{ .key = "cgovo", .value = .{ .num = 2e-10 } }};
    inline for (.{ .psp103, .bsimcmg, .l_utsoi, .bsimbulk, .bsimimg }) |id| {
        const name = @tagName(@as(devices.DeviceId, id));
        try std.testing.expectEqualDeep(@as([]const []const u8, &.{"cgovo"}), try ta.ignoredKeys(a, devices.DeviceId.Type(id).Model, &kv));
        try std.testing.expect(ta.ngspiceKey(name, "cgovo") == null);
        try std.testing.expectEqual(@as(usize, 0), (try checkOne(a, id, "cgovo", 2e-10)).len);
    }
}

test "a key ngspice models and ESPice does not runs at its inert value, with no word" {
    // Oracle: ngspice 44.2 gives the same operating point with each key at
    // this value as with it absent: a diode at -2 V draws 2.010e-12 A with or
    // without rth0=0; a BJT at vbe=0.7 draws ic=56.7035 uA
    // with or without quasimod=0. Source: hicumL2.cpp:1114 skips ich=0,
    // b3soifdset.c:69 defaults version to 2, inpdomod.c:283 runs BSIM3 3.3.0
    // for version 3.3, b4set.c:650 defaults lintnoi to 0.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { id: devices.DeviceId, key: []const u8, value: f64 };
    inline for ([_]Row{
        .{ .id = .diode, .key = "rth0", .value = 0 },
        .{ .id = .gummel_poon, .key = "quasimod", .value = 0 },
        .{ .id = .hicumL2_va, .key = "ich", .value = 0 },
        .{ .id = .b3soifd, .key = "version", .value = 2 },
        .{ .id = .bsim3, .key = "version", .value = 3.3 },
        .{ .id = .bsim4va, .key = "lintnoi", .value = 0 },
        .{ .id = .resistor, .key = "kf", .value = 0 },
        // Inert at any value: ngspice-45's BJT reads rth0 only in its SOA
        // check (bjtsoachk.c:114), HiSIM_HV overwrites rth0r with 0
        // (hsmhvset.c:418); diode rth0, VDMOS thermal and B3SOI shmod only
        // reach ngspice's answer through self-heating, which net_devices
        // refuses on ngspice's own condition (src/tests/card_keys.zig).
        .{ .id = .diode, .key = "rth0", .value = 1e6 },
        .{ .id = .gummel_poon, .key = "rth0", .value = 100 },
        .{ .id = .hisimhv_va, .key = "rth0r", .value = 1 },
        .{ .id = .vdmos, .key = "thermal", .value = 1 },
        .{ .id = .vbic13_4t, .key = "selft", .value = 0 },
        .{ .id = .b3soifd, .key = "shmod", .value = 1 },
    }) |row| {
        try std.testing.expect(ta.ngspiceKey(@tagName(row.id), row.key) != null);
        try std.testing.expectEqual(@as(usize, 0), (try checkOne(a, row.id, row.key, row.value)).len);
    }
}

test "a key ngspice models and ESPice does not is refused at any other value" {
    // Oracle: ngspice 44.2. ibe=0 with ibc=0 drops ic from 56.7035 uA to
    // 3.3 pA (bjttemp.c:169 reads both Given flags), so ibe has no inert
    // value. inpdomod.c:280 runs BSIM3v32 for version 3.2. Before the fix
    // every one of these ran with no error.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { id: devices.DeviceId, key: []const u8, value: f64 };
    inline for ([_]Row{
        .{ .id = .gummel_poon, .key = "ibe", .value = 0 },
        .{ .id = .gummel_poon, .key = "ibc", .value = 1e-16 },
        .{ .id = .gummel_poon, .key = "quasimod", .value = 1 },
        .{ .id = .gummel_poon, .key = "rco", .value = 10 },
        .{ .id = .hicumL2_va, .key = "ich", .value = 1e-3 },
        .{ .id = .bsim3, .key = "version", .value = 3.2 },
    }) |row| try std.testing.expectError(error.UnmodelledParameter, checkOne(a, row.id, row.key, row.value));
}

test "a noise-only key at a non-inert value is returned for .noise, never refused" {
    // Oracle: ngspice source. resnoise.c:109-111 is the one read of kf, af,
    // ef and (through RESeffNoiseArea, ressetup.c:61) lf and wf; b4noi.c:53
    // is the one read of lintnoi that computes anything. gf180's poly
    // resistors carry kf=3.6e-23 af=1.684; their .dc must still run.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"kf"}), try checkOne(a, .resistor, "kf", 3.6e-23));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"af"}), try checkOne(a, .resistor, "af", 1.684));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"lintnoi"}), try checkOne(a, .bsim4va, "lintnoi", 1e-8));
    for ([_][]const u8{ "kf", "af", "ef", "lf", "wf" }) |key| try std.testing.expect(ta.ngspiceKey("resistor", key).?.noise_only);
}

test "a BSIM4 card spelling every ngspice default runs, with no word" {
    // Oracle: ngspice's own defaults, read off b4set.c into
    // ngspice_model_keys.tsv (lintnoi's is 0, b4set.c:650). A card giving
    // each key at that default leaves ngspice's answer as it is, so no key
    // bsim4va.va lacks may refuse or record a noise gap.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 0), ta.ngspiceKey("bsim4va", "lintnoi").?.inert.at);
    var kv: std.ArrayList(netlist.Kv) = .empty;
    var rows = std.mem.splitScalar(u8, ta.ngspice_model_keys, '\n');
    while (rows.next()) |row| {
        var cols = std.mem.splitScalar(u8, row, '\t');
        if (!std.mem.eql(u8, cols.first(), "bsim4va")) continue;
        const key = cols.next().?;
        switch (ta.ngspiceKey("bsim4va", key).?.inert) {
            .at => |v| try kv.append(a, .{ .key = key, .value = .{ .num = v } }),
            .none, .any => {},
        }
    }
    try std.testing.expect(kv.items.len > 0);
    const noise = try ta.checkModelKeys(a, devices.DeviceId.Type(.bsim4va).Model, "bsim4va", "m", kv.items);
    try std.testing.expectEqual(@as(usize, 0), noise.len);
}

test "an R, C or L card's ignored keys are the ones ngspice 44.2 calls unrecognized" {
    // Oracle: ngspice 44.2 on these three cards, every key ngspice's R, C and
    // L model tables hold plus one bogus key each, prints "unrecognized
    // parameter" for defl and the bogus keys only. ESPice also drops R's
    // flicker-noise keys (resistor.va has none), so they are listed too;
    // checkModelKeys decides whether a listed key warns or refuses. Before
    // the fix every geometry and coil key the builder reads was listed, and
    // R's tc1r/tc2r bound nothing. temp and dtemp bind: ngspice applies a
    // model card's as the instance default (ac/passive_model_temp.sp).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (model, the card's keys, the keys that warn)
    inline for (.{
        .{ devices.resistor, "rsh narrow short defw tc1 tc2 tce tnom temp dtemp dw dlr res tc1r tc2r kf af lf wf ef l w defl r bv_max bogusr", "kf af lf wf ef defl bogusr" },
        .{ devices.capacitor, "cap cj cox cjsw capsw defw w defl l narrow short del di thick tc1 tc2 tnom temp dtemp bv_max c bogusc", "bogusc" },
        .{ devices.inductor, "ind tc1 tc2 tnom temp dtemp csect dia length nt mu l bogusl", "bogusl" },
    }) |case| {
        var kv: std.ArrayList(netlist.Kv) = .empty;
        var keys = std.mem.tokenizeScalar(u8, case[1], ' ');
        while (keys.next()) |key| try kv.append(a, .{ .key = key, .value = .{ .num = 1 } });
        const got = try ta.ignoredKeys(a, case[0].Model, kv.items);
        try std.testing.expectEqualStrings(case[2], try std.mem.join(a, " ", got));
    }
}

test "R, C and L cards bind their model card once per row, the path that warns" {
    // Oracle: ngspice warns once per .model card (inpgmod.c:189), not once
    // per instance. The warning runs where a row is first bound
    // (net_devices.boundCard), which stores the row; before the fix R, C
    // and L cards bound their model with applyKv, left the row empty and
    // never warned.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* passive model rows\nv1 a 0 1\nr1 a 0 rm\nc1 a 0 cm\nc2 a 0 cm\nl1 a b lm\nr2 b 0 1\n" ++
        ".model rm r(r=1k bogus=1)\n.model cm c(cap=1p bogus=1)\n.model lm l(ind=1u bogus=1)\n.end\n");
    defer c.circuit.deinit();
    try std.testing.expectEqual(@as(usize, 3), c.nb.bound_cards.len);
    for (c.nb.bound_cards) |card| try std.testing.expect(card != null);
}

test "a model card's m binds the shape ngspice's model table names, never the multiplier" {
    // Oracle: ngspice binds a .model key through the device's model table
    // and reads and drops an `m` that table lacks (inpgmod.c:133-145), so a
    // model card never sets the multiplier, which is instance-only. The
    // tables holding an `m`: dio.c:71 (grading), hfet.c:59, hfet2.c:68 and
    // mesa.c:72 (knee), vdmos.c:121 (the body diode's grading, vdmos.va's
    // `mj`). One row per catalog device whose Model has an `m`, by name, so
    // a new one fails the build until it has a verdict. SpiceRack R9: a
    // VDMOS card's m=0.548 was its multiplicity, and every multiplier
    // device's card m was too.
    const Row = struct { name: []const u8, deck: []const u8, sets: ?[]const u8 };
    const mos = "m1 d g 0 0 x\n.model x nmos level=";
    const soi = " version=2 tox=4.1e-9 vth0=0.35 u0=280";
    const rows = [_]Row{
        .{ .name = "mos1", .deck = mos ++ "1", .sets = null },
        .{ .name = "mos2", .deck = mos ++ "2", .sets = null },
        .{ .name = "mos3", .deck = mos ++ "3", .sets = null },
        .{ .name = "bsim1", .deck = mos ++ "4", .sets = null },
        .{ .name = "bsim2", .deck = mos ++ "5", .sets = null },
        .{ .name = "mos6", .deck = mos ++ "6", .sets = null },
        .{ .name = "bsim3", .deck = mos ++ "8", .sets = null },
        .{ .name = "mos9", .deck = mos ++ "9", .sets = null },
        .{ .name = "b3soifd", .deck = mos ++ "55" ++ soi, .sets = null },
        .{ .name = "b3soidd", .deck = mos ++ "56" ++ soi, .sets = null },
        .{ .name = "gummel_poon", .deck = "q1 c b 0 x\n.model x npn", .sets = null },
        // vbic.c:26 holds `m` in the instance table only, none at :64 on.
        .{ .name = "vbic13_4t", .deck = "q1 c b 0 0 x\n.model x npn level=4", .sets = null },
        .{ .name = "jfet", .deck = "j1 d g 0 x\n.model x njf", .sets = null },
        .{ .name = "jfet2", .deck = "j1 d g 0 x\n.model x njf level=2", .sets = null },
        .{ .name = "mes", .deck = "z1 d g 0 x\n.model x nmf", .sets = null },
        .{ .name = "vdmos", .deck = "m1 d g s x\n.model x vdmos", .sets = "mj" },
        .{ .name = "diode", .deck = "d1 a 0 x\n.model x d", .sets = "m" },
        .{ .name = "diode_t", .deck = "d1 a 0 t x thermal\n.model x d rth0=100", .sets = "m" },
        .{ .name = "hfet1", .deck = "z1 d g 0 x\n.model x nhfet level=5", .sets = "m" },
        .{ .name = "hfet2", .deck = "z1 d g 0 x\n.model x nhfet level=6", .sets = "m" },
        .{ .name = "mesa", .deck = "z1 d g 0 x\n.model x nmf level=2", .sets = "m" },
    };
    // F and G cards take no .model card.
    const no_card = [_][]const u8{ "cccs", "vccs" };
    comptime {
        @setEvalBranchQuota(1_000_000);
        for (device.catalog) |e| {
            if (!@hasDecl(e.type, "Model") or !@hasField(e.type.Model, "m")) continue;
            const listed = for (rows) |r| {
                if (std.mem.eql(u8, r.name, e.name)) break true;
            } else for (no_card) |n| {
                if (std.mem.eql(u8, n, e.name)) break true;
            } else false;
            if (!listed) @compileError("no model card m verdict for catalog device " ++ e.name);
        }
    }
    // The rows whose card m=0.3 did not land where ngspice puts it.
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(std.testing.allocator);
    for (rows) |row| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var c = try compileDeck(a, a, try std.mem.concat(a, u8, &.{ "* card m\n", row.deck, " m=0.3\n.end\n" }));
        defer c.circuit.deinit();
        const got = c.circuit.batches[0].type_name;
        const shape = if (row.sets) |field| try firstParam(a, &c.circuit, field) else 0.3;
        const mult = try firstParam(a, &c.circuit, "m");
        const want: f64 = if (std.mem.eql(u8, row.sets orelse "", "m")) 0.3 else 1;
        // `0.3` reads as 3 * pow(10, -1) = 0.30000000000000004, as
        // ngspice's INPevaluate reads it: the test is where m lands.
        const near = struct {
            fn f(x: f64, y: f64) bool {
                return std.math.approxEqRel(f64, x, y, 1e-15);
            }
        }.f;
        if (std.mem.eql(u8, got, row.name) and near(shape, 0.3) and near(mult, want)) continue;
        std.debug.print("{s} ({s}): card m=0.3 left m={d}, {s}={d}\n", .{ row.name, got, mult, row.sets orelse "-", shape });
        try failed.append(std.testing.allocator, row.name);
    }
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{}), failed.items);
}

test "control source binding rejects a missing and an unknown name" {
    // net_passive.zig: an F card whose first value is no name has no
    // control source; one naming no V card has an unknown one.
    for ([_]struct { []const u8, anyerror }{
        .{ "F1 out 0 2", error.MissingControlSource },
        .{ "F1 out 0 vmissing 2", error.UnknownControlSource },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "* sensing\nVCase in 0 2\nRin in 0 1k\n{s}\nRout out 0 1k\n.end\n", .{case[0]});
        const nl = try netlist.parse(a, source);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try std.testing.expectError(case[1], nb.build());
    }
}

test "an unknown instance parameter fails the card; a model or alias key binds" {
    for ([_]struct { []const u8, ?anyerror }{
        .{ "M1 d g 0 0 nm ww=10u l=1u", error.UnknownParameter },
        .{ "M1 d g 0 0 nm w=10u l=1u m=2", null },
        .{ "M1 d g 0 0 nm w=10u l=1u vt0=1", null },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "unknown key\nVD d 0 5\nVG g 0 2\n{s}\n.model nm nmos level=1 vto=1 kp=20u\n.op\n.end\n", .{case[0]});
        const nl = try netlist.parse(a, source);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        if (case[1]) |err| try std.testing.expectError(err, nb.build()) else try nb.build();
    }
}

test "transmission-line cards route to their convolution algorithms" {
    const cases = .{
        .{ "O1 a 0 b 0 line\n.model line LTRA r=0.5 l=250n c=100p len=2\n", "ltra" },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 c=100p len=2\n", "ltra" },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=12.45 l=8.972n c=0.468p length=16\n", "txl" },
        // r=0: ReadTxL's lossless line (txlsetup.c), txl.va's lsl branch.
        .{ "Y1 a 0 b 0 line\n.model line TXL r=0 l=250n g=0 c=100p length=1\n", "txl" },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=0.2 0 0.2 l=9.13n 3.3n 9.13n c=0.365p -0.09p 0.365p length=10\n", "coupled_ltra" },
        .{ "P1 a b c 0 d e f 0 line\n.model line CPL r=0.2 0 0 0.2 0 0.2 l=9n 3n 0 9n 3n 9n c=0.3p -0.03p 0 0.3p -0.03p 0.3p length=10\n", "coupled_ltra3" },
        .{ "P1 a b c d 0 e f g h 0 line\n.model line CPL r=0.2 0 0 0 0.2 0 0 0.2 0 0.2 l=9n 3n 0 0 9n 3n 0 9n 3n 9n c=0.3p -0.03p 0 0 0.3p -0.03p 0 0.3p -0.03p 0.3p length=10\n", "coupled_ltra4" },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try netlist.parse(a, "* line routing\n" ++ case[0] ++ ".end\n");
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        var compiled = false;
        defer if (!compiled) b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try nb.build();
        try std.testing.expectEqual(@as(usize, 1), b.protos.items.len);
        try std.testing.expectEqualStrings(device.vtable(case[1]).name, b.protos.items[0].type_name);
        if (case[0][0] == 'Y' or case[0][0] == 'P') {
            try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(nb.br.len)));
            try std.testing.expectEqual(b.n - 1, nb.br.items(.row)[0]);
        }
        var circuit = try b.compile();
        compiled = true;
        defer circuit.deinit();
        // The lines hold their history as §5.10 state, staged per converged
        // solve, and evaluate on the GPU too (#171).
        try std.testing.expect(circuit.batches[0].hooks.commit_state == null);
        try std.testing.expect(circuit.batches[0].hooks.update_state != null);
        try std.testing.expect(circuit.batches[0].hooks.gpu_payload != null);
    }
}

test "held variables and switch latches stage per converged solve" {
    // `stateCtl(.revert)` restores vbic13_4t's @(initial_step) held values
    // and the switch's hysteresis latch alike, so both stage per solve.
    const cases = .{
        "Q1 c b 0 qm\n.model qm NPN LEVEL=4\n",
        "S1 a 0 c 0 sw\n.model sw SW vt=0.5\n",
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var c = try compileDeck(a, a, "* held state routing\n" ++ case ++ ".end\n");
        defer c.circuit.deinit();
        const hooks = c.circuit.batches[0].hooks;
        try std.testing.expect(hooks.update_state != null and hooks.state_ctl != null);
    }
}

test "source breakpoints match an uncached walk, forward and backward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* breakpoint cache\n" ++
        "V1 a 0 PULSE(0 1 1n 1n 1n 5n 20n)\nV2 b 0 PWL(0 0 3n 1 7n 0)\nR1 a b 1k\n.end\n");
    defer c.circuit.deinit();
    const src = for (c.circuit.batches) |bt| {
        if (bt.hooks.next_breakpoint != null) break bt;
    } else return error.TestUnexpectedResult;
    // Timer-only sources run no per-step state pass.
    try std.testing.expect(src.hooks.update_state == null and src.hooks.bound_step == null);
    const next = src.hooks.next_breakpoint.?;
    const ts = [_]f64{ 0, 0.5e-9, 1e-9, 1.5e-9, 2e-9, 3e-9, 2.5e-9, 6.9e-9, 7e-9, 30e-9, 1e-9, 100e-9, 0 };
    for (ts) |t| {
        const cached = next(src.ctx, t);
        _ = src.hooks.recompute.?(src.ctx); // empties the cache
        try std.testing.expectEqual(next(src.ctx, t), cached);
    }
}

// A failed TXL or CPL fit passes the builder and the run refuses it; see
// "a failed line fit refuses every analysis" in src/tests/analyses.zig.
test "unsupported transmission-line cards never select approximate fallbacks" {
    const cases = .{
        .{ "P1 a b c d e 0 f g h i j 0 line\n.model line CPL length=1\n", error.UnsupportedCoupledLineDimension },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=1 l=1n c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1e6 l=1n c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1e200 l=1e200 c=1e-100 length=1e150\n", error.UnsupportedTransmissionLineParameters },
        // r=0 off ReadTxL's lossless branch (g >= 1e-2) reaches y_pade's
        // division by R/L; a model without r= is E_BADPARM (txlsetup.c:93-97).
        .{ "Y1 a 0 b 0 line\n.model line TXL r=0 l=250n g=0.02 c=100p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL l=250n g=0 c=100p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=-1 l=250n g=0 c=100p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=12.45 l=8.972n g=unresolved c=0.468p length=16\n", error.UnresolvedParameter },
        .{ "Y1 a 0 b 0 line len=unresolved\n.model line TXL r=12.45 l=8.972n c=0.468p length=16\n", error.UnresolvedParameter },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=0.5 l=250n c=100p len=unresolved\n", error.UnresolvedParameter },
        // An LTRA model's length is len= alone: ngspice 44.2 ignores
        // length= there, then refuses "lossy line length must be given".
        .{ "O1 a 0 b 0 line\n.model line LTRA r=0.5 l=250n c=100p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "P1 a b 0 c d 0 line length=unresolved\n.model line CPL r=0.2 0 0.2 l=9n 0 9n c=0.3p 0 0.3p length=10\n", error.UnresolvedParameter },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 l=1n len=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 l=1u g=1e-320 c=1p len=1e-10\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 l=1e-320 c=1p len=1e-10\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1e200 g=1e200 len=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 g=1 len=1000\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1e-200 g=1e-200 len=1e200\n", error.UnsupportedTransmissionLineParameters },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try netlist.parse(a, "* invalid line routing\n" ++ case[0] ++ ".end\n");
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try std.testing.expectError(case[1], nb.build());
        try std.testing.expectEqual(@as(usize, 0), b.protos.items.len);
    }
}

// Oracle: ngspice 44.2 refuses `len=`, `length=` and `r=` on an O card
// ("unknown parameter (len)"): ltra.c LTRApTable gives the instance only
// v1, v2, i1, i2 and ic, so the line's length is its model's.
test "RG line takes its length from the model and refuses a card length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* static RG model length\nO1 a 0 b 0 line\n.model line LTRA r=1 g=1 len=2\n.end\n");
    defer c.circuit.deinit();
    try std.testing.expectEqual(@as(f64, 2), try firstParam(a, &c.circuit, "len"));
    inline for (.{ "len=2", "length=2", "r=2" }) |key| {
        errdefer std.debug.print("O card key: {s}\n", .{key});
        const deck = "* O card length\nO1 a 0 b 0 line " ++ key ++ "\n.model line LTRA r=1 g=1 len=1\n.end\n";
        try std.testing.expectError(error.UnknownParameter, compileDeck(a, a, deck));
    }
}

// Oracle: ngspice 44.2 reads an O or T card's v1, v2, i1 and i2 (`ic=` is
// their vector) only under uic, as the line's history at t <= 0
// (ltraload.c:289-300, traload.c:61-66): a 50 ohm RLC O line with v1=1
// i1=0.01 reads v(in) 0.4997502 V at 1 ns, a 50 ohm 5 ns T line v(out)
// 0.75 V, and both 0 V without them. Without uic the operating point
// overwrites them, and an RG line never reads them (ltraload.c:228).
test "line initial conditions are refused under uic and ignored without it" {
    const o = "O1 a 0 b 0 line v1=1 ic=1,0.01\n";
    const t = "T1 a 0 b 0 z0=50 td=5n v1=1 ic=1,0.01,0,0\n";
    const cases = .{
        .{ "O RLC, uic", o ++ ".model line LTRA r=0.5 l=250n c=100p len=1\n.tran 0.1n 10n uic\n", true },
        .{ "O LC, uic", o ++ ".model line LTRA l=250n c=100p len=1\n.tran 0.1n 10n uic\n", true },
        .{ "O RC, uic", o ++ ".model line LTRA r=50 c=100p len=1\n.tran 0.1n 10n uic\n", true },
        .{ "O RLC, no uic", o ++ ".model line LTRA r=0.5 l=250n c=100p len=1\n.tran 0.1n 10n\n", false },
        .{ "O RG, uic", o ++ ".model line LTRA r=1 g=1 len=1\n.tran 0.1n 10n uic\n", false },
        .{ "T, uic", t ++ ".tran 0.1n 10n uic\n", true },
        .{ "T, no uic", t ++ ".tran 0.1n 10n\n", false },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        errdefer std.debug.print("line: {s}\n", .{case[0]});
        const deck = "* line initial conditions\n" ++ case[1] ++ ".end\n";
        if (case[2]) {
            try std.testing.expectError(error.UnsupportedCard, compileDeck(a, a, deck));
        } else {
            var c = try compileDeck(a, a, deck);
            c.circuit.deinit();
        }
    }
    // tline.va's ic_v1 is no ngspice key, and nothing reads it yet.
    var t_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t_arena.deinit();
    const t_alloc = t_arena.allocator();
    try std.testing.expectError(error.UnknownParameter, compileDeck(t_alloc, t_alloc, "* T ic_v1\nT1 a 0 b 0 z0=50 td=5n ic_v1=1\n.end\n"));
}

// Oracle: ngspice's own precedence. A Y card's `len` beats its TXL model's
// `length` (inp2y.c, ReadTxL in txlsetup.c), and a Y card's `length=` is
// not read at all (inp2y.c; ngspice 44.2 runs it with the model's length).
// A P card's `length` or `len` beats its CPL model's (inp2p.c,
// cplsetup.c:483-485). The rest of the line class has no card length: T
// has no model (tra.c), U's model has no length (urc.c), and an O card
// refuses one (the test above).
test "a line card's own length beats its model's, element by element" {
    const cases = .{
        .{ "Y TXL, card len=", "Y1 a 0 b 0 line len=2\n.model line TXL r=12.45 l=8.972n c=0.468p length=1\n", "len", 2 },
        .{ "Y TXL, card length= ignored", "Y1 a 0 b 0 line length=2\n.model line TXL r=12.45 l=8.972n c=0.468p length=1\n", "len", 1 },
        .{ "P CPL, card len=", "P1 a b 0 c d 0 line len=2\n.model line CPL r=0.2 0 0.2 l=9.13n 3.3n 9.13n c=0.365p -0.09p 0.365p length=1\n", "length", 2 },
        .{ "P CPL, card length=", "P1 a b 0 c d 0 line length=2\n.model line CPL r=0.2 0 0.2 l=9.13n 3.3n 9.13n c=0.365p -0.09p 0.365p length=1\n", "length", 2 },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        errdefer std.debug.print("element: {s}\n", .{case[0]});
        var c = try compileDeck(a, a, "* line length precedence\n" ++ case[1] ++ ".end\n");
        defer c.circuit.deinit();
        try std.testing.expectEqual(@as(f64, case[3]), try firstParam(a, &c.circuit, case[2]));
    }
}

test "V card: PWL td= and r= suffixes bind, and r=0 means repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* pwl suffixes\nV1 a 0 pwl(0 0 1n 1 2n 0) td=0.5n r=0\n.end\n");
    defer c.circuit.deinit();
    try std.testing.expectEqual(@as(f64, 0.5e-9), try firstParam(a, &c.circuit, "pwl_td"));
    try std.testing.expectEqual(@as(f64, 0), try firstParam(a, &c.circuit, "pwl_repeat"));
}

test "branch probes land on the branch row when the card's nets are new" {
    // Each card's first net (and B1's probed net c) is new to the builder
    // when the card is added, so the device's internal rows start past them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* probes\nB1 x 0 V=2*V(c)\nE1 y 0 d 0 3\nV1 c 0 1\nV2 d 0 1\n.end\n");
    defer c.circuit.deinit();
    const circuit = &c.circuit;
    const published = try c.nb.publish(a, circuit, null);
    var found: u8 = 0;
    for (published.probe_labels, published.probes) |label, row| {
        if (label[0] != 'i') continue;
        // No branch column may alias a named node's row.
        for (1..circuit.n) |i| if (circuit.nodeName(@intCast(i)).len != 0)
            try std.testing.expect(row != i);
        found += 1;
    }
    try std.testing.expectEqual(@as(u8, 4), found);
}

test "compile frees the BBD permutation it does not return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, std.testing.allocator,
        \\* two subcircuit instances
        \\.subckt rc p q
        \\r1 p m 1k
        \\r2 m q 1k
        \\.ends
        \\x1 in mid rc
        \\x2 mid 0 rc
        \\.end
    );
    c.circuit.deinit();
}

test "source cards: DC, AC, DISTOF and waveform keywords read as ngspice reads them" {
    const n = struct {
        fn num(v: f64) Value {
            return .{ .num = v };
        }
        fn name(v: []const u8) Value {
            return .{ .name = v };
        }
    };
    // DC, as ngspice-44.2 reads it (measured): the bare number straight
    // after the nodes beats any keyword, else the last `DC v`, `DC(v)`,
    // `dc=v` or I's `c=v`. `ac 1 0 3` holds no DC value (ngspice stops on
    // the card: AC takes two numbers).
    try std.testing.expectEqual(@as(?f64, 9), ta.sourceDc(cardWith("v1", 'v', &.{n.num(9)}, &.{.{ .key = "dc", .value = n.num(2) }})));
    try std.testing.expectEqual(@as(?f64, 7), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("dc"), n.num(7) }, &.{})));
    try std.testing.expectEqual(@as(?f64, 3), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("dc"), n.num(2), n.name("dc"), n.num(3) }, &.{})));
    try std.testing.expectEqual(@as(?f64, 2), ta.sourceDc(cardWith("i1", 'i', &.{}, &.{ .{ .key = "dc", .value = n.num(3) }, .{ .key = "c", .value = n.num(2) } })));
    try std.testing.expectEqual(@as(?f64, 4), ta.sourceDc(cardWith("v1", 'v', &.{.{ .group = .{ .items = &.{ n.name("dc"), n.num(4) } } }}, &.{})));
    try std.testing.expectEqual(@as(?f64, null), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("ac"), n.num(1), n.num(0), n.num(3) }, &.{})));
    try std.testing.expectEqual(@as(?f64, null), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("distof1"), n.num(1), n.num(0) }, &.{})));
    try std.testing.expectEqual(@as(?f64, null), ta.sourceDc(cardWith("v1", 'v', &.{}, &.{})));

    // AC: bare is 1∠0, one number the magnitude, two magnitude and phase in
    // degrees; a waveform keyword after the magnitude is no phase.
    const bare = ta.sourceAc(cardWith("v1", 'v', &.{n.name("ac")}, &.{})).?;
    try std.testing.expectEqual(@as(f64, 1), bare.re);
    try std.testing.expectEqual(@as(f64, 0), bare.im);
    const quad = ta.sourceAc(cardWith("v1", 'v', &.{ n.name("ac"), n.num(2), n.num(90) }, &.{})).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), quad.re, 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 2), quad.im, 1e-15);
    const then_sin = ta.sourceAc(cardWith("v1", 'v', &.{ n.name("ac"), n.num(3), n.name("sin"), n.num(0), n.num(1) }, &.{})).?;
    try std.testing.expectEqual(@as(f64, 3), then_sin.re);
    try std.testing.expectEqual(@as(f64, 0), then_sin.im);
    const grouped = ta.sourceAc(cardWith("v1", 'v', &.{.{ .group = .{ .items = &.{ n.name("ac"), n.num(5) } } }}, &.{})).?;
    try std.testing.expectEqual(@as(f64, 5), grouped.re);
    try std.testing.expect(ta.sourceAc(cardWith("v1", 'v', &.{n.num(1)}, &.{})) == null);

    // DISTOF: absent is no drive, bare is 1∠0.
    try std.testing.expectEqual([2]f64{ 0, 0 }, ta.sourceDisto(cardWith("v1", 'v', &.{}, &.{}), "distof1"));
    try std.testing.expectEqual([2]f64{ 1, 0 }, ta.sourceDisto(cardWith("v1", 'v', &.{n.name("distof1")}, &.{}), "distof1"));
    try std.testing.expectEqual([2]f64{ 0.5, 30 }, ta.sourceDisto(cardWith("v1", 'v', &.{ n.name("distof2"), n.num(0.5), n.num(30) }, &.{}), "distof2"));
    try std.testing.expectEqual([2]f64{ 2, 0 }, ta.sourceDisto(cardWith("v1", 'v', &.{}, &.{.{ .key = "distof2", .value = n.num(2) }}), "distof2"));

    try std.testing.expectEqual(Wave.pulse, ta.waveKind("PULSE").?);
    try std.testing.expectEqual(Wave.sffm, ta.waveKind("Sffm").?);
    try std.testing.expect(ta.waveKind("dc") == null);
    try std.testing.expect(ta.waveKind("pulsewidth") == null); // longer than any keyword
}

test "source cards: portnum and z0" {
    const port = (try ta.sourcePort(cardWith("v1", 'v', &.{}, &.{.{ .key = "portnum", .value = .{ .num = 1 } }}))).?;
    try std.testing.expectEqual(@as(u16, 1), port.num);
    try std.testing.expectEqual(@as(f64, 50), port.z0);
    const positional = (try ta.sourcePort(cardWith("v1", 'v', &.{ .{ .name = "portnum" }, .{ .num = 2 }, .{ .name = "z0" }, .{ .num = 75 } }, &.{}))).?;
    try std.testing.expectEqual(@as(u16, 2), positional.num);
    try std.testing.expectEqual(@as(f64, 75), positional.z0);
    try std.testing.expect((try ta.sourcePort(cardWith("v1", 'v', &.{}, &.{}))) == null);
    for ([_][]const netlist.Kv{
        &.{.{ .key = "portnum", .value = .{ .num = 0 } }},
        &.{.{ .key = "portnum", .value = .{ .num = 1025 } }},
        &.{ .{ .key = "portnum", .value = .{ .num = 1 } }, .{ .key = "z0", .value = .{ .num = 0 } } },
        &.{ .{ .key = "portnum", .value = .{ .num = 1 } }, .{ .key = "hblin_h", .value = .{ .num = 0.5 } } },
        &.{ .{ .key = "portnum", .value = .{ .num = 1 } }, .{ .key = "hblin_s", .value = .{ .num = 2 } } },
    }) |kv| try std.testing.expectError(error.InvalidAnalysisArguments, ta.sourcePort(cardWith("v1", 'v', &.{}, kv)));
}

test "POLE root products pair conjugates and refuse an unpaired root" {
    try std.testing.expectEqual(@as(f64, 1), try ta.rootProduct(&.{}));
    try std.testing.expectEqual(@as(f64, 1), try ta.rootProduct(&.{ 0, 0 })); // a root at 0 is skipped
    try std.testing.expectEqual(@as(f64, -6), try ta.rootProduct(&.{ 2, 0, -3, 0 }));
    // (−1 + 2j)(−1 − 2j) = 5, in either order.
    try std.testing.expectEqual(@as(f64, 5), try ta.rootProduct(&.{ -1, 2, -1, -2 }));
    try std.testing.expectEqual(@as(f64, 5), try ta.rootProduct(&.{ -1, -2, -1, 2 }));
    try std.testing.expectError(error.UnpairedPoleRoot, ta.rootProduct(&.{ -1, 2 }));
    try std.testing.expectError(error.UnpairedPoleRoot, ta.rootProduct(&.{ -1, 2, -1, -2.1 }));
}

test "CPL and RLGC matrices read their packed triangles" {
    const kv = [_]netlist.Kv{
        .{ .key = "r", .value = .{ .num = 0.2 } },  .{ .key = "", .value = .{ .num = 0 } }, .{ .key = "", .value = .{ .num = 0.3 } },
        .{ .key = "l", .value = .{ .num = 1e-9 } },
    };
    var out: [3]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try ta.cplVector(&kv, "r", &out));
    try std.testing.expectEqualSlices(f64, &.{ 0.2, 0, 0.3 }, &out);
    try std.testing.expectEqual(@as(usize, 1), try ta.cplVector(&kv, "l", &out));
    try std.testing.expectEqual(@as(usize, 0), try ta.cplVector(&kv, "c", &out));
    try std.testing.expectError(error.UnsupportedTransmissionLineParameters, ta.cplVector(&kv, "r", out[0..2]));
    try std.testing.expectError(error.NonFiniteParameter, ta.cplVector(&.{.{ .key = "g", .value = .{ .num = std.math.inf(f64) } }}, "g", &out));
    try std.testing.expectError(error.InvalidParameterValue, ta.cplVector(&.{.{ .key = "g", .value = .{ .name = "x" } }}, "g", &out));
}

/// Builds `source` (title line first) and returns `needs_tran_op`. The
/// Builder is never compiled.
fn buildDeck(source: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, source);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    return b.needs_tran_op;
}

test "topology: V/L shorts must agree on KVL, current sources need a DC path" {
    try std.testing.expectError(error.VoltageSourceLoop, buildDeck("* loop\nV1 a 0 5\nV2 a 0 3\n.end\n"));
    // Agreeing sources in a loop leave its current free (#70).
    try std.testing.expectError(error.NonuniqueOperatingPoint, buildDeck("* parallel\nV1 a 0 5\nV2 a 0 5\nR1 a 0 1k\n.end\n"));
    // A chain of shorts listed against its order, closed by a fourth source:
    // v(c) = 3 agrees with it, 2 does not.
    try std.testing.expectError(error.NonuniqueOperatingPoint, buildDeck("* chain\nV3 c b 1\nV2 b a 1\nV1 a 0 1\nV4 c 0 3\n.end\n"));
    try std.testing.expectError(error.VoltageSourceLoop, buildDeck("* chain\nV3 c b 1\nV2 b a 1\nV1 a 0 1\nV4 c 0 2\n.end\n"));
    // An inductor is a 0 V short.
    try std.testing.expectError(error.VoltageSourceLoop, buildDeck("* l loop\nV1 a 0 1\nL1 a 0 1u\n.end\n"));
    try std.testing.expectError(error.CurrentSourceCutset, buildDeck("* cutset\nI1 0 out 1m\nC1 out 0 1u\n.end\n"));
    // Current sources that balance on a capacitor node are an island (#70);
    // unequal ones are a cutset.
    try std.testing.expect(try buildDeck("* balanced\nI1 0 a 1m\nI2 a b 1m\nR1 b 0 1k\nC1 a 0 1p\n.end\n"));
    try std.testing.expectError(error.CurrentSourceCutset, buildDeck("* unbalanced\nI1 0 a 1m\nI2 a b 2m\nR1 b 0 1k\nC1 a 0 1p\n.end\n"));
    // A `.ic` node is held through a transient's operating point (ngspice
    // cktload.c, MODETRANOP), a DC path for that solve: ngspice 44.2 runs
    // the cutset deck with it, v(out) 0 at t = 0 and the exact 1 V/ms ramp,
    // with no warning. A `.ic` on another node holds nothing here (ngspice:
    // singular matrix at out).
    try std.testing.expect(try buildDeck("* held\nI1 0 out 1m\nC1 out 0 1u\n.ic v(out)=0\n.tran 1u 1m\n.end\n"));
    try std.testing.expectError(error.CurrentSourceCutset, buildDeck("* held elsewhere\nI1 0 out 1m\nC1 out 0 1u\nV1 a 0 1\nR1 a 0 1k\n.ic v(a)=1\n.tran 1u 1m\n.end\n"));
    // A node only capacitors reach needs the transient operating point,
    // also behind a series short that touches no ground (#90).
    try std.testing.expect(try buildDeck("* cap node\nV1 a 0 1\nC1 a b 1p\nC2 b 0 1p\n.end\n"));
    try std.testing.expect(try buildDeck("* ammeter\nV1 a 0 1\nC1 a m 1p\nVam m b 0\nC2 b 0 1p\n.end\n"));
    try std.testing.expect(try buildDeck("* series r\nV1 a 0 1\nC1 a m 1p\nR1 m b 1m\nC2 b 0 1p\n.end\n"));
    try std.testing.expect(!try buildDeck("* divider\nV1 a 0 1\nR1 a b 1k\nR2 b 0 1k\n.end\n"));
    // A node only an expression reads has no equation at all (#92).
    try std.testing.expectError(error.FloatingNode, buildDeck("* sense\nB1 o 0 V={v(a)+1}\nR1 o 0 1k\n.end\n"));
}

test "cards the builder refuses instead of misbinding" {
    // K naming an L card that does not exist.
    try std.testing.expectError(error.KinducUnknownInductor, buildDeck("* k\nL1 a 0 1u\nR1 a 0 1\nK1 L1 L2 0.5\n.end\n"));
    // URC K = 1 sizes every lump as 0/0.
    try std.testing.expectError(error.InvalidParameterValue, buildDeck("* urc\nU1 a b 0 um l=1 n=3\n.model um URC k=1\n.end\n"));
}

test "a B expression past one tape's control ports splits into chained bsources" {
    // Sources on n1..n9, so no net is only read (#92).
    const drives = "V1 n1 0 1\nV2 n2 0 2\nV3 n3 0 3\nV4 n4 0 4\nV5 n5 0 5\nV6 n6 0 6\nV7 n7 0 7\nV8 n8 0 8\nV9 n9 0 9\n";
    // Nine probed nets, one past the eight control ports (SpiceRack #7):
    // the sum over n1..n8 becomes a bsource of its own, whose row B1 reads
    // beside n9. src/tests/expressions.zig solves these against hand sums;
    // before the split both decks were refused.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* b\nB1 x 0 V=V(n1)+V(n2)+V(n3)+V(n4)+V(n5)+V(n6)+V(n7)+V(n8)+V(n9)\n" ++ drives ++ ".end\n");
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    try std.testing.expectEqual(@as(u32, 2), instances(&b, "bsource"));
    // A behavioural resistor's B, whose v(x,0) takes x's port on top of
    // n1..n8, splits the same.
    _ = try buildDeck("* r\nR1 x 0 '1k+0*(v(n1)+v(n2)+v(n3)+v(n4)+v(n5)+v(n6)+v(n7)+v(n8))' noise=0\nVx x 0 1\n" ++ drives ++ ".end\n");
}

/// Instances `b` added of catalog device `name`.
fn instances(b: *const Builder, comptime name: []const u8) u32 {
    const i = @backingInt(device.Library.builtin(name));
    return if (i < b.card_counts.items.len) b.card_counts.items[i] else 0;
}

test "URC expands into its lump ladder" {
    const cases = .{
        // N given: 2N resistors and 2N - 1 capacitors.
        .{ "U1 a b 0 um l=2 n=4\n.model um URC k=2 rperl=100 cperl=1p\n", 4, false },
        // No N: few enough lumps at this FMAX that the URCsetup floor of 3 holds.
        .{ "U1 a b 0 um\n.model um URC\n", 3, false },
        // ISPERL given, even as 0, swaps the capacitors for diodes.
        .{ "U1 a b 0 um l=1 n=3\n.model um URC isperl=0\n", 3, true },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try netlist.parse(a, "* urc\n" ++ case[0] ++ ".end\n");
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try nb.build();
        const lumps: u32 = case[1];
        try std.testing.expectEqual(2 * lumps, instances(&b, "resistor"));
        try std.testing.expectEqual(if (case[2]) 0 else 2 * lumps - 1, instances(&b, "capacitor"));
        try std.testing.expectEqual(if (case[2]) 2 * lumps - 1 else 0, instances(&b, "diode"));
        // Ground, a, b and the 2N - 1 ladder nodes.
        try std.testing.expectEqual(2 * lumps + 2, b.n);
    }
}

/// Builds and freezes `body` (no title, no `.end`) and returns its
/// published `.sp` ports, or publish's error.
fn publishPorts(a: std.mem.Allocator, comptime body: []const u8) ![]const @import("core").query.Port {
    var c = try compileDeck(a, a, "* ports\n" ++ body ++ ".end\n");
    defer c.circuit.deinit();
    return (try c.nb.publish(a, &c.circuit, null)).bindings.ports;
}

test "publish orders .sp ports by portnum and refuses a gapped set, a third card on a number or unequal legs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A card error wins over a gap wherever it sits, as in vsrctemp.c.
    inline for ([_]struct { []const u8, anyerror }{
        .{ "V1 a 0 0 AC 1 portnum 2\nR1 a 0 50\n", error.MissingPortNumber },
        .{ "V1 a 0 0 AC 1 portnum 1\nV2 b 0 0 AC 1 portnum 3\nR1 a b 50\n", error.MissingPortNumber },
        .{ "V1 a 0 0 AC 1 portnum 5\nV2 b 0 0 AC 1 portnum 5\nR1 a b 50\n", error.MissingPortNumber },
        .{ "V1 a 0 0 AC 1 portnum 1\nV2 b 0 0 AC 1 portnum 1\nV3 c 0 0 portnum 1\nR1 a b 50\nR2 c 0 50\n", error.DuplicatePortNumber },
        .{ "V1 a 0 0 AC 1 portnum 5\nV2 b 0 0 AC 1 portnum 5\nV3 c 0 0 portnum 5\nR1 a b 50\nR2 c 0 50\n", error.DuplicatePortNumber },
        .{ "V1 a 0 0 AC 1 portnum 1\nV2 b 0 0 AC 1 portnum 1 z0 75\nR1 a b 50\n", error.UnbalancedPort },
        .{ "V1 a r 0 AC 1 portnum 1\nV2 b 0 0 AC 1 portnum 1\nR1 a b 50\nR2 r 0 50\n", error.UnbalancedPort },
        .{ "V1 a 0 0 AC 1 portnum 5\nV2 b 0 0 AC 1 portnum 5 z0 25\nR1 a b 50\n", error.UnbalancedPort },
    }) |case| try std.testing.expectError(case[1], publishPorts(a, case[0]));
    // Two cards on one number are one balanced port, each leg against its
    // own n-; the first in deck order, Vb, is the + leg, and as it is
    // stamped first its branch row is the lower.
    const pair = try publishPorts(a, "V9 x 0 0 portnum 2\nVb b r 0 portnum 1\nVa a r 0 portnum 1\nR1 a b 50\nR2 r 0 50\nR3 x a 50\n");
    try std.testing.expectEqual(@as(usize, 2), pair.len);
    const minus = pair[0].balanced orelse return error.TestUnexpectedResult;
    try std.testing.expect(pair[0].branch < minus.branch);
    try std.testing.expect(pair[0].node != minus.node);
    try std.testing.expectEqual(pair[0].neg, minus.neg);
    try std.testing.expect(pair[0].neg != 0);
    try std.testing.expectEqual(@as(f64, 50), pair[0].z0);
    try std.testing.expect(pair[1].balanced == null);
    try std.testing.expectEqual(@as(usize, 0), (try publishPorts(a, "V1 a 0 0 AC 1\nR1 a 0 50\n")).len);
    const ports = try publishPorts(a, "V2 b 0 0 AC 1 portnum 2 z0 75\nV1 a 0 0 AC 1 portnum 1\nR1 a b 50\n");
    try std.testing.expectEqual(@as(usize, 2), ports.len);
    try std.testing.expectEqual(@as(f64, 50), ports[0].z0);
    try std.testing.expectEqual(@as(f64, 75), ports[1].z0);
}

test "publish maps .sp port rows through the BBD permutation" {
    // Two subcircuit instances make a permutation; the port's node and
    // branch must land where the V card's own rows do.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a,
        \\* port behind a bbd permutation
        \\.subckt rc p q
        \\r1 p m 1k
        \\r2 m q 1k
        \\.ends
        \\Vp in 0 0 AC 1 portnum 1 z0 50
        \\x1 in mid rc
        \\x2 mid 0 rc
        \\.end
    );
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var perm: ?[]const u32 = null;
    var circuit = try b.compilePerm(&perm);
    compiled = true;
    defer circuit.deinit();
    try std.testing.expect(perm != null);
    const bindings = (try nb.publish(a, &circuit, perm)).bindings;
    try std.testing.expectEqual(@as(usize, 1), bindings.ports.len);
    try std.testing.expectEqual(bindings.v_pos[0], bindings.ports[0].node);
    try std.testing.expectEqual(bindings.v_branches[0], bindings.ports[0].branch);
}

test "AC sources land in one stacked excitation" {
    // I1 0 a AC 2 pushes 2 A into a; V1's AC drives its branch row.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* ac\nV1 b 0 0 AC 1 90\nI1 0 a AC 2\nR1 a 0 1\nR2 b 0 1\n.end\n");
    defer c.circuit.deinit();
    const out = try c.nb.publish(a, &c.circuit, null);
    const n = c.circuit.n;
    try std.testing.expectEqual(2 * @as(usize, n), out.ac_drive.len);
    const row_a = for (out.probe_labels, out.probes) |label, row| {
        if (std.mem.eql(u8, label, "v(a)")) break row;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 2), out.ac_drive[row_a]);
    const br = out.bindings.v_branches[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0), out.ac_drive[br], 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 1), out.ac_drive[n + br], 1e-15);
    var total: f64 = 0;
    for (out.ac_drive) |v| total += @abs(v);
    try std.testing.expectApproxEqRel(@as(f64, 3), total, 1e-12);
}

// Both sides of the W/S keyword rule (card_table.isDataElement): a card
// with a `key=value` field is ESPice's RLGC line or N-port (HSPICE's
// spelling, [CR] W and S elements); without one it is ngspice's
// current or voltage switch (inp2w.c, inp2s.c).
test "a W or S card with key=value fields is a line or N-port; without, ngspice's switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = try device.Library.init(a);
    const decks = .{
        .{ "W1 a 0 b 0 rlgcmodel=wm n=1 l=0.2\n.model wm w modeltype=rlgc n=1 lo=300n co=120p ro=5\nr1 a 0 1k\nr2 b 0 1k\n", "wline_1", "cswitch" },
        .{ "W1 a 0 v1 sw OFF\n.model sw csw(it=1m ih=0)\nv1 c 0 1\nr1 c 0 1k\nr2 a 0 1k\n", "cswitch", "wline_1" },
        .{ "S1 a 0 c 0 sm\n.model sm sw(vt=0.5)\nv1 c 0 1\nr1 a 0 1k\n", "vswitch", "wline_1" },
    };
    inline for (decks) |d| {
        const nl = try netlist.parse(a, "* w and s\n" ++ d[0] ++ ".end\n");
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try nb.build();
        try std.testing.expect(hasProto(&b, d[1]));
        try std.testing.expect(!hasProto(&b, d[2]));
    }
    // The N-port's data file is read by `prepare`; the reader already sets
    // it apart: every field keyed, no positional model or ON/OFF word.
    const nl = try netlist.parse(a, "* s\nS1 a b mname=sm\n.model sm s tstonefile=f.s2p\nr1 a 0 1k\nr2 b 0 1k\n.end\n");
    const s1 = for (0..nl.deviceCount()) |e| {
        const v = nl.device(.from(e));
        if (std.mem.eql(u8, v.name, "s1")) break v;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), s1.positional.len);
    try std.testing.expectEqualStrings("mname", s1.kv[0].key);
}

/// The scans `branch_index` replaced (#177): the first V, else the first L,
/// else the first `br` row of that name.
fn scanBranchRow(nb: *const builder.NetBuilder, name: []const u8) ?u32 {
    if (netlist.nameIndex(nb.v.items(.name), name)) |k| return nb.v.items(.branch)[k];
    if (netlist.nameIndex(nb.l.items(.name), name)) |k| return nb.l.items(.branch)[k];
    if (netlist.nameIndex(nb.br.items(.name), name)) |k| return nb.br.items(.row)[k];
    return null;
}

fn expectScans(nb: *const builder.NetBuilder, names: []const []const u8) !void {
    for (names) |name| {
        try std.testing.expectEqual(scanBranchRow(nb, name), ta.branchRow(nb, name));
        const v = netlist.nameIndex(nb.v.items(.name), name);
        try std.testing.expectEqual(if (v) |k| @as(?u32, @intCast(k)) else null, ta.vRow(nb, name));
        try std.testing.expectEqual(netlist.nameIndex(nb.l.items(.name), name), ta.lRow(nb, name));
    }
}

test "F, H, W and K in subcircuit instances bind the instance's own V and L (positive-definite-1.sp, ltra1_4_line.sp)" {
    // ngspice subckt.c:1422-1436, 1475-1486 flattens the sensed source and
    // the coupled inductors with the instance's path, so each instance
    // builds against its own `v.xN.vs` and `l.xN.l1`; ESPice refused both
    // cards inside any subcircuit (UnknownControlSource, KinducUnknownInductor).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, a, "* refs in subcircuits\n.subckt cell a\nvs a b 0\nr1 b 0 1k\nf1 c 0 vs 2\nr2 c 0 1k\n" ++
        "h1 d 0 vs 100\nr3 d 0 1k\nw1 e 0 vs sw\nr4 e 0 1k\nl1 b g 1u\nrg g 0 1\nl2 c h 1u\nrh h 0 1\nk1 l1 l2 0.5\n.ends\n" ++
        ".model sw csw(it=1m ih=0)\nx1 1 cell\nx2 2 cell\nv1 1 0 1\nv2 2 0 2\n.end\n");
    defer c.circuit.deinit();
    // Each instance's H carries its own output branch, ngspice's i(h.x1.h1).
    for ([_][]const u8{ "h.x1.h1", "h.x2.h1" }) |name| try std.testing.expect(ta.branchRow(&c.nb, name) != null);
}

test "a refused card names what it failed on: the V or L card it lacks, the values that are no number" {
    // Oracle: the cards' own text. K1 couples an l2 no card defines, F1
    // senses a vx no card defines, M1's w and V1's sin amplitude name no
    // .param; m1's own model name is no subject.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* subjects\nl1 a 0 1u\nr0 a 0 1\nk1 l1 l2 0.5\n.end\n");
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try std.testing.expectError(error.KinducUnknownInductor, nb.build());
    var buf: [128]u8 = undefined;
    const k = nl.device(nl.bucket('k')[0]);
    try std.testing.expectEqualStrings("no L card 'l2' to couple", ta.subject(&nb, &buf, k, error.KinducUnknownInductor).?);
    const f = cardWith("f1", 'f', &.{ .{ .name = "vx" }, .{ .num = 2 } }, &.{});
    try std.testing.expectEqualStrings("no V card 'vx' to sense", ta.subject(&nb, &buf, f, error.UnknownControlSource).?);
    var m = cardWith("m1", 'm', &.{.{ .name = "nch" }}, &.{ .{ .key = "w", .value = .{ .name = "wfin" } }, .{ .key = "l", .value = .{ .num = 1e-6 } } });
    m.model = .{ .name = "nch", .kind = "nmos", .kv = &.{} };
    try std.testing.expectEqualStrings("not a number: w='wfin'", ta.subject(&nb, &buf, m, error.UnresolvedParameter).?);
    const sin: netlist.Group = .{ .items = &.{ .{ .name = "sin" }, .{ .num = 0 }, .{ .name = "ampl" }, .{ .num = 1e3 } } };
    const v = cardWith("v1", 'v', &.{.{ .group = sin }}, &.{});
    try std.testing.expectEqualStrings("not a number: 'ampl'", ta.subject(&nb, &buf, v, error.UnresolvedParameter).?);
    try std.testing.expectEqual(null, ta.subject(&nb, &buf, f, error.OutOfMemory));
}

test "an UnsupportedDevice names why: the model the card cannot use, the model it lacks, or its letter" {
    // Oracle: the cards' own text. M1 names an nmos model as a diode would
    // not; M2 names no model a .model defines (or no bin held its L, W);
    // A1 has a letter no device takes.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* subjects\nr0 a 0 1\n.end\n");
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    var buf: [160]u8 = undefined;
    var d = cardWith("d1", 'd', &.{.{ .name = "nch" }}, &.{});
    d.model = .{ .name = "nch", .kind = "nmos", .kv = &.{} };
    try std.testing.expectEqualStrings("model 'nch' (nmos) is not a device this card can use", ta.subject(&nb, &buf, d, error.UnsupportedDevice) orelse "");
    const m = cardWith("m2", 'm', &.{.{ .name = "nbin" }}, &.{});
    try std.testing.expectEqualStrings("no .model this card can use: its model name is not defined, or no bin of it holds the card's L and W", ta.subject(&nb, &buf, m, error.UnsupportedDevice) orelse "");
    const u = cardWith("a1", 'a', &.{}, &.{});
    try std.testing.expectEqualStrings("no device has the card letter 'a'", ta.subject(&nb, &buf, u, error.UnsupportedDevice) orelse "");
}

test "the branch-name index answers as the first-match scans did, duplicates included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Doubled V, L and E names; B1 reads one of each, B2 reads B1's own
    // branch, which lands in `br` while the deferred cards resolve; K1 and
    // F1 resolve through the same index.
    const nl = try netlist.parse(a,
        \\* duplicate branch names
        \\v1 a 0 1
        \\v1 b 0 2
        \\l1 a c 1u
        \\l1 b d 2u
        \\l2 x 0 3u
        \\e1 e 0 a 0 2
        \\e1 f 0 b 0 3
        \\r1 c 0 1
        \\r2 d 0 1
        \\r3 e 0 1
        \\r4 f 0 1
        \\r5 g 0 1
        \\r6 h 0 1
        \\r7 x 0 1
        \\r8 o 0 1
        \\k1 l1 l2 0.5
        \\f1 o 0 v1 2
        \\b1 g 0 v=i(v1)+i(l1)+i(e1)
        \\b2 h 0 v=i(b1)
        \\.end
        \\
    );
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    const names = [_][]const u8{ "v1", "l1", "l2", "e1", "b1", "b2", "r1", "k1", "f1", "nope", "" };
    try expectScans(&nb, &names);
    try std.testing.expectEqual(nb.v.items(.branch)[0], ta.branchRow(&nb, "v1").?);
    try std.testing.expectEqual(nb.l.items(.branch)[0], ta.branchRow(&nb, "l1").?);
    // A V and an L of one name (no ngspice deck spells one): the V wins
    // the branch, and the L is still found for a K card.
    try nb.l.append(nb.arena, .{ .name = "v1", .branch = 12345, .value = 1e-6, .model = .{} });
    try ta.indexBranchNames(&nb);
    try expectScans(&nb, &names);
    try std.testing.expectEqual(nb.l.len - 1, ta.lRow(&nb, "v1").?);
}

test "BBD: no permutation without two instances, and no row past u32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try device.Library.init(arena.allocator());
    var b = try Builder.init(std.testing.allocator, &lib);
    defer b.deinit();
    for (0..3) |_| _ = try b.addNode();
    try std.testing.expectEqual(null, try ta.computeBbd(&b)); // untagged
    // One instance, a coupling row and a top-level row still order nothing.
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 2 }, .{ 2, 5 }, .{ 3, 0 }, .{ 0, 7 } }) |tag| try ta.tagNodeInstance(&b, tag[0], tag[1]);
    try std.testing.expectEqual(null, try ta.computeBbd(&b));
    const n = b.n;
    b.n = std.math.maxInt(u32);
    try std.testing.expectError(error.TooManyNodes, b.addNode());
    b.n = n;
}

test "BBD blocks follow first-seen instance order over sparse instance ordinals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib = try device.Library.init(arena.allocator());
    var b = try Builder.init(std.testing.allocator, &lib);
    defer b.deinit();
    for (0..6) |_| _ = try b.addNode();
    // Rows 1 and 3 in instance 3, row 2 in instance 1, row 4 shared by
    // both (coupling), row 5 top level, row 6 never tagged.
    for ([_][2]u32{ .{ 1, 3 }, .{ 2, 1 }, .{ 3, 3 }, .{ 4, 1 }, .{ 4, 3 }, .{ 5, 0 } }) |tag|
        try ta.tagNodeInstance(&b, tag[0], tag[1]);
    const bbd = (try ta.computeBbd(&b)).?;
    const perm = bbd.perm;
    defer std.testing.allocator.free(perm);
    const info = bbd.info;
    defer std.testing.allocator.free(info.blocks);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 2, 4, 5, 6 }, perm);
    try std.testing.expectEqual(@as(usize, 2), info.blocks.len);
    try std.testing.expectEqual(@as(u32, 1), info.blocks[0].start);
    try std.testing.expectEqual(@as(u32, 2), info.blocks[0].size);
    try std.testing.expectEqual(@as(u32, 3), info.blocks[1].start);
    try std.testing.expectEqual(@as(u32, 1), info.blocks[1].size);
    try std.testing.expectEqual(@as(u32, 4), info.coupling_start);
    try std.testing.expectEqual(@as(u32, 3), info.coupling_size);
}

test "equal device cards bind once and share a Model row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compileDeck(a, std.testing.allocator, "* memo\nV1 d 0 1\nR1 d a 1k\nR2 a b 1k\nR3 b 0 2k\n.model nch nmos level=54\n" ++
        "M1 d a 0 0 nch w=1u l=0.1u\nM2 d b 0 0 nch w=1u l=0.1u\nM3 a b 0 0 nch w=2u l=0.1u\n.end\n");
    defer c.circuit.deinit();
    // Two MOSFET inputs; R and V cards bind on their own paths.
    try std.testing.expectEqual(@as(u32, 2), c.nb.memo.count());
    var seen = false;
    for (c.circuit.batches) |batch| {
        if (!std.mem.eql(u8, batch.type_name, "bsim4va")) continue;
        seen = true;
        const l = try batch.hooks.param_layout.?(batch.ctx).unwrap();
        try std.testing.expectEqual(@as(u32, 3), l.count);
        // Two distinct rows among three instances, whatever order the
        // batch keeps them in.
        const m = l.model_of;
        const distinct = 1 + @as(u32, @intFromBool(m[1] != m[0])) + @intFromBool(m[2] != m[0] and m[2] != m[1]);
        try std.testing.expectEqual(@as(u32, 2), distinct);
    }
    try std.testing.expect(seen);
}
