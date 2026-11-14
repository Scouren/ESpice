//! SPICE device selection. In: a card letter, a `.model` LEVEL or a
//! Verilog-A module name. Out: the `DeviceId` that builds it, whose catalog
//! type is `DeviceId.Type`. Cites ngspice src/spicelib/parser/inpdomod.c
//! for the LEVEL tables, and HSPICE's level numbers where ngspice has none.
//!
//! Contents:
//! - `pub const DeviceId = enum`
//! - `pub fn Type(comptime id: DeviceId) type`
//! - `pub const letter_map: std.StaticStringMap(DeviceId)`
//! - `pub const module_map: std.StaticStringMap(DeviceId)`
//! - `pub const resistor, capacitor, inductor, kinduc, vsource, isource, cccs, ccvs, vcvs, bsource, bsource_i, bsource_d, bsource_di, cswitch, tline, lossy_tline, ltra, vcvs_laplace, vccs_laplace, vcvs_pole, vccs_pole, vcvs_delay, vccs_delay, txl, coupled_ltra, coupled_ltra3, coupled_ltra4, wline_1, wline_2, wline_3, wline_4, sparam_1, sparam_2, sparam_3, sparam_4: type`
//! - `pub const absent_model: []const u8` (on a `Type` with no catalog model)
//! - `pub const Family = struct`
//! - `pub const families: [5]Family`
//! - `pub fn familyOfKind(kind: []const u8) ?u8`
//! - `pub fn levelDeviceId(letter: u8, level: u16) error{UnsupportedDevice}!DeviceId`

const std = @import("std");
const assert = std.debug.assert;
const device = @import("device");

/// Every model name the dispatch policy can name. The type behind a tag
/// comes from the catalog via `Type`. Names with no generated model
/// (B3SOIPD, SOI3) are tags anyway so the level tables can report
/// them by name. Written out rather than reflected from the catalog because
/// `@Enum` cannot attach the `Type` declaration.
pub const DeviceId = enum {
    // Netlist letters.
    resistor,
    capacitor,
    inductor,
    kinduc,
    vsource,
    isource,
    vcvs,
    vccs,
    cccs,
    ccvs,
    bsource,
    bsource_i,
    vswitch,
    cswitch,
    tline,
    lossy_tline,
    txl,
    coupled_tlines,
    diode,
    /// The self-heated diode (diode.va under SELFHEATING); the builder swaps
    /// it in for a diode card ngspice heats (`resolveDeviceId`).
    diode_t,
    // M card levels.
    mos1,
    mos2,
    mos3,
    mos6,
    mos9,
    bsim1,
    bsim2,
    bsim3,
    bsim4va,
    bsimsoi_va,
    b3soifd,
    b3soidd,
    b3soipd,
    soi3,
    hisim2_va,
    hisimhv_va,
    psp103,
    /// PSP 103 with the NQS model built in; the builder swaps it in for a
    /// psp103 card that sets SWNQS != 0.
    psp103_nqs,
    psp103t,
    psp104,
    psp104_nqs,
    psp104t,
    bsimimg,
    bsimcmg,
    bsimbulk,
    l_utsoi,
    hisimsoi,
    hisimsotb,
    mosvar,
    asmhemt,
    mvsg,
    vdmos,
    // Q card levels.
    gummel_poon,
    vbic13_4t,
    hicumL2_va,
    mextram,
    mextram_t,
    hicumL0,
    // D card levels.
    juncap200,
    diode_cmc,
    asmesd,
    asmesd_dio,
    // Resistors by `.model` module name.
    r2_cmc,
    r3_cmc,
    // J / Z card levels.
    jfet,
    jfet2,
    mes,
    mesa,
    hfet1,
    hfet2,

    /// The catalog device type behind a tag. A tag whose model is not in the
    /// catalog resolves to `Absent`, so the build still compiles (consumers
    /// switch `inline else` over every tag) and the instance is rejected
    /// instead of silently running some other device.
    pub fn Type(comptime id: DeviceId) type {
        const name = @tagName(id);
        if (comptime device.has(name)) return device.byName(name);
        return Absent(name);
    }
};

/// Netlist first letter to device. Letters with a LEVEL table (m q j z) are
/// resolved by the *DeviceId functions below; 'd' is listed only so diode
/// cards pass the known-letter gate. Other letters fall through to the
/// runtime-loaded HDL devices.
pub const letter_map = std.StaticStringMap(DeviceId).initComptime(.{
    .{ "r", DeviceId.resistor },
    .{ "c", DeviceId.capacitor },
    .{ "l", DeviceId.inductor },
    .{ "k", DeviceId.kinduc },
    .{ "v", DeviceId.vsource },
    .{ "i", DeviceId.isource },
    .{ "e", DeviceId.vcvs },
    .{ "g", DeviceId.vccs },
    .{ "f", DeviceId.cccs },
    .{ "h", DeviceId.ccvs },
    .{ "b", DeviceId.bsource },
    .{ "s", DeviceId.vswitch },
    .{ "w", DeviceId.cswitch },
    .{ "t", DeviceId.tline },
    .{ "o", DeviceId.lossy_tline },
    // Y cards require the TXL Padé/history algorithm; they are not LTRA cards.
    .{ "y", DeviceId.txl },
    .{ "p", DeviceId.coupled_tlines },
    .{ "d", DeviceId.diode },
});

/// `.model X <module>` on a card with no built-in letter: the Verilog-A
/// module name an OSDI deck loads the model under (ngspice `pre_osdi`
/// decks, IHP SG13G2's `psp103va`), lowercase.
pub const module_map = std.StaticStringMap(DeviceId).initComptime(.{
    .{ "psp103va", DeviceId.psp103 },
    .{ "pspnqs103va", DeviceId.psp103_nqs },
    .{ "psp103tva", DeviceId.psp103t },
    .{ "psp104va", DeviceId.psp104 },
    .{ "pspnqs104va", DeviceId.psp104_nqs },
    .{ "psp104tva", DeviceId.psp104t },
    .{ "juncap200", DeviceId.juncap200 },
    .{ "bsimimg", DeviceId.bsimimg },
    .{ "bsimcmg", DeviceId.bsimcmg },
    .{ "bsimcmg_va", DeviceId.bsimcmg },
    .{ "bsimbulk", DeviceId.bsimbulk },
    .{ "l_utsoi", DeviceId.l_utsoi },
    .{ "bjt505", DeviceId.mextram },
    .{ "bjt505_va", DeviceId.mextram },
    .{ "bjt505t", DeviceId.mextram_t },
    .{ "bjt505t_va", DeviceId.mextram_t },
    .{ "asmhemt", DeviceId.asmhemt },
    .{ "hicuml2va", DeviceId.hicumL2_va },
    .{ "hicuml0va", DeviceId.hicumL0 },
    .{ "hisimhv_va", DeviceId.hisimhv_va },
    .{ "hisimsoi_va", DeviceId.hisimsoi },
    .{ "hisimsotb_va", DeviceId.hisimsotb },
    .{ "mosvar", DeviceId.mosvar },
    .{ "diode_cmc", DeviceId.diode_cmc },
    .{ "r2_cmc", DeviceId.r2_cmc },
    .{ "r3_cmc", DeviceId.r3_cmc },
    .{ "mvsg_cmc", DeviceId.mvsg },
    .{ "asmesd", DeviceId.asmesd },
    .{ "asmesd_dio", DeviceId.asmesd_dio },
});

// Flat aliases for the devices the builder wires by hand instead of
// dispatching through `DeviceId`; each names the cards that build it.

/// R cards, URC lumps and a P card's series z0.
pub const resistor = DeviceId.Type(.resistor);
/// C cards and URC lumps.
pub const capacitor = DeviceId.Type(.capacitor);
/// L cards.
pub const inductor = DeviceId.Type(.inductor);
/// K cards: mutual inductance between two L branches.
pub const kinduc = DeviceId.Type(.kinduc);
/// V and P cards.
pub const vsource = DeviceId.Type(.vsource);
/// I cards.
pub const isource = DeviceId.Type(.isource);
/// F cards.
pub const cccs = DeviceId.Type(.cccs);
/// H cards.
pub const ccvs = DeviceId.Type(.ccvs);
/// Plain E cards.
pub const vcvs = DeviceId.Type(.vcvs);
/// V-mode B cards.
pub const bsource = DeviceId.Type(.bsource);
/// I-mode B cards.
pub const bsource_i = DeviceId.Type(.bsource_i);
/// V-mode B cards whose expression reads `ddt()`.
pub const bsource_d = device.byName("bsource_d");
/// I-mode B cards whose expression reads `ddt()`.
pub const bsource_di = device.byName("bsource_di");
/// ngspice W cards (current-controlled switch).
pub const cswitch = DeviceId.Type(.cswitch);
/// T cards, and lossless LC O cards.
pub const tline = DeviceId.Type(.tline);
/// O cards of a static RG line.
pub const lossy_tline = DeviceId.Type(.lossy_tline);
/// O cards of an RLC or RC line.
pub const ltra = device.byName("ltra");
/// E LAPLACE cards.
pub const vcvs_laplace = device.byName("vcvs_laplace");
/// G LAPLACE cards.
pub const vccs_laplace = device.byName("vccs_laplace");
/// E POLE cards.
pub const vcvs_pole = device.byName("vcvs_pole");
/// G POLE cards.
pub const vccs_pole = device.byName("vccs_pole");
/// E DELAY cards.
pub const vcvs_delay = device.byName("vcvs_delay");
/// G DELAY cards.
pub const vccs_delay = device.byName("vccs_delay");
/// Y cards.
pub const txl = DeviceId.Type(.txl);
/// P (CPL) cards of 2 conductors.
pub const coupled_ltra = device.byName("coupled_ltra");
/// P (CPL) cards of 3 conductors.
pub const coupled_ltra3 = device.byName("coupled_ltra3");
/// P (CPL) cards of 4 conductors.
pub const coupled_ltra4 = device.byName("coupled_ltra4");
/// HSPICE W cards of N = 1.
pub const wline_1 = device.byName("wline_1");
/// HSPICE W cards of N = 2.
pub const wline_2 = device.byName("wline_2");
/// HSPICE W cards of N = 3.
pub const wline_3 = device.byName("wline_3");
/// HSPICE W cards of N = 4.
pub const wline_4 = device.byName("wline_4");
/// HSPICE S cards of 1 port.
pub const sparam_1 = device.byName("sparam_1");
/// HSPICE S cards of 2 ports.
pub const sparam_2 = device.byName("sparam_2");
/// HSPICE S cards of 3 ports.
pub const sparam_3 = device.byName("sparam_3");
/// HSPICE S cards of 4 ports.
pub const sparam_4 = device.byName("sparam_4");

/// A semiconductor letter: the `.model` kinds that name it (ngspice
/// inpdomod.c) and its LEVEL table. A card whose model is another letter's
/// kind is refused, as ngspice's "incorrect model type" (#75); a kind no
/// family names (an HDL module) is not checked.
pub const Family = struct { letter: u8, name: []const u8, kinds: []const []const u8, levels: []const Level };

/// The five semiconductor letters, M Q D J Z.
pub const families = [_]Family{
    .{ .letter = 'm', .name = "MOSFET", .kinds = &.{ "nmos", "pmos", "vdmos", "vdmosn", "vdmosp" }, .levels = &mos_levels },
    .{ .letter = 'q', .name = "BJT", .kinds = &.{ "npn", "pnp" }, .levels = &bjt_levels },
    .{ .letter = 'd', .name = "diode", .kinds = &.{"d"}, .levels = &diode_levels },
    .{ .letter = 'j', .name = "JFET", .kinds = &.{ "njf", "pjf" }, .levels = &jfet_levels },
    .{ .letter = 'z', .name = "MESFET", .kinds = &.{ "nmf", "pmf", "nhfet", "phfet" }, .levels = &mes_levels },
};

/// `.model` LEVEL tables, per ngspice src/spicelib/parser/inpdomod.c.
const Level = struct { level: u16, model: DeviceId };

const mos_levels = [_]Level{
    .{ .level = 1, .model = .mos1 },
    .{ .level = 2, .model = .mos2 },
    .{ .level = 3, .model = .mos3 },
    .{ .level = 4, .model = .bsim1 },
    .{ .level = 5, .model = .bsim2 },
    .{ .level = 6, .model = .mos6 },
    .{ .level = 8, .model = .bsim3 },
    .{ .level = 49, .model = .bsim3 },
    .{ .level = 9, .model = .mos9 },
    .{ .level = 10, .model = .bsimsoi_va },
    .{ .level = 58, .model = .bsimsoi_va },
    .{ .level = 14, .model = .bsim4va },
    .{ .level = 54, .model = .bsim4va },
    .{ .level = 55, .model = .b3soifd },
    .{ .level = 56, .model = .b3soidd },
    .{ .level = 57, .model = .b3soipd },
    .{ .level = 60, .model = .soi3 },
    .{ .level = 68, .model = .hisim2_va },
    .{ .level = 73, .model = .hisimhv_va },
    // ngspice-45 has no PSP LEVEL (PSP103 is OSDI only there); 1040 is the
    // number the VACASK-derived corpus decks use.
    .{ .level = 1040, .model = .psp103 },
    // ngspice-45 has none of these built in; HSPICE's numbers.
    .{ .level = 72, .model = .bsimcmg },
    .{ .level = 76, .model = .l_utsoi },
    .{ .level = 77, .model = .bsimbulk },
    .{ .level = 78, .model = .bsimimg },
};

const bjt_levels = [_]Level{
    .{ .level = 1, .model = .gummel_poon },
    .{ .level = 2, .model = .gummel_poon },
    .{ .level = 4, .model = .vbic13_4t },
    .{ .level = 9, .model = .vbic13_4t },
    .{ .level = 8, .model = .hicumL2_va },
    // HSPICE's Mextram level.
    .{ .level = 6, .model = .mextram },
};

const diode_levels = [_]Level{
    .{ .level = 1, .model = .diode },
    .{ .level = 3, .model = .diode },
    // HSPICE's JUNCAP2 level.
    .{ .level = 6, .model = .juncap200 },
};

const jfet_levels = [_]Level{
    .{ .level = 1, .model = .jfet },
    .{ .level = 2, .model = .jfet2 },
};

const mes_levels = [_]Level{
    .{ .level = 1, .model = .mes },
    .{ .level = 2, .model = .mesa },
    .{ .level = 3, .model = .mesa },
    .{ .level = 4, .model = .mesa },
    .{ .level = 5, .model = .hfet1 },
    .{ .level = 6, .model = .hfet2 },
};

// Each LEVEL table names a level once; `levelId` takes the first match.
comptime {
    for (families) |family| {
        const table = family.levels;
        for (table, 0..) |a, i| for (table[i + 1 ..]) |b| if (a.level == b.level) @compileError("duplicate LEVEL in a device table");
    }
}

/// The family letter whose kinds hold `kind` (any case); null for none.
pub fn familyOfKind(kind: []const u8) ?u8 {
    for (families) |f| for (f.kinds) |k| if (std.ascii.eqlIgnoreCase(kind, k)) return f.letter;
    return null;
}

/// The device a family letter's card runs for `.model ... LEVEL=level`
/// (ngspice inpdomod.c). UnsupportedDevice, with a logged warning, for a
/// level outside the table or one whose model is not in the catalog.
/// Asserts `letter` is a family's.
pub fn levelDeviceId(letter: u8, level: u16) error{UnsupportedDevice}!DeviceId {
    inline for (families) |f| if (f.letter == letter) return levelId(f.name, f.levels, level);
    unreachable;
}

// ---- private ----

/// Stand-in for a policy name with no generated model. It has no `eval`,
/// which is what every consumer gates on.
fn Absent(comptime name: []const u8) type {
    return struct {
        pub const absent_model = name;
    };
}

/// LEVEL to device. An unknown level, or one whose model is not in the
/// catalog, is an unsupported netlist: it logs a warning and returns
/// `UnsupportedDevice`, never a panic and never a different device.
fn levelId(comptime kind: []const u8, comptime table: []const Level, level: u16) error{UnsupportedDevice}!DeviceId {
    inline for (table) |e| {
        if (e.level == level) {
            if (comptime !device.has(@tagName(e.model))) {
                std.log.warn("devices: " ++ kind ++ " LEVEL {d} needs model '" ++
                    @tagName(e.model) ++ "', which is not in the device catalog", .{level});
                return error.UnsupportedDevice;
            }
            return e.model;
        }
    }
    std.log.warn("devices: unsupported " ++ kind ++ " LEVEL {d}", .{level});
    return error.UnsupportedDevice;
}

test "LEVEL tables follow inpdomod.c, and an unknown level is UnsupportedDevice" {
    std.testing.log_level = .err; // An unknown level logs a warning.
    // Each pair: the level and the device inpdomod.c (or HSPICE) names.
    inline for (.{ .{ 1, DeviceId.mos1 }, .{ 3, DeviceId.mos3 }, .{ 8, DeviceId.bsim3 }, .{ 49, DeviceId.bsim3 }, .{ 54, DeviceId.bsim4va }, .{ 14, DeviceId.bsim4va } }) |c|
        if (comptime device.has(@tagName(c[1]))) try std.testing.expectEqual(c[1], try levelDeviceId('m', c[0]));
    if (comptime device.has("gummel_poon")) try std.testing.expectEqual(.gummel_poon, try levelDeviceId('q', 2));
    if (comptime device.has("diode")) try std.testing.expectEqual(.diode, try levelDeviceId('d', 3));
    for ([_]u16{ 0, 7, 11, 999, 65535 }) |level| {
        try std.testing.expectError(error.UnsupportedDevice, levelDeviceId('m', level));
        try std.testing.expectError(error.UnsupportedDevice, levelDeviceId('q', level));
        try std.testing.expectError(error.UnsupportedDevice, levelDeviceId('d', level));
        try std.testing.expectError(error.UnsupportedDevice, levelDeviceId('j', level));
        try std.testing.expectError(error.UnsupportedDevice, levelDeviceId('z', level));
    }
    try std.testing.expectEqual(.vsource, letter_map.get("v").?);
    try std.testing.expectEqual(null, letter_map.get("m"));
}
