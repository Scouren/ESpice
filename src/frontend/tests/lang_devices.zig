//! Tests of the ESPice language's model families and source waves.
//! Oracles: for the family table, the device tables of
//! src/frontend/Circuit/spice.zig read at test time (build.zig declares
//! the file an input): every device a LEVEL table or `module_map` selects
//! is the device of some family, compared as name lists; the spec page's
//! family table names exactly the table's families; one hand-written
//! legacy `.model` card per family, the polarity as devices.md "Polarity"
//! and each module's `TYPE` in models/*.va say the legacy card reads it.
//! For waves: the legacy group written by hand from net_waves.zig
//! `fieldPairs` (each argument's position) and models/vsource.va (its
//! meaning and unit), and a code for each refusal.

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const model = @import("../lang/model.zig");
const Code = lang.diag.Code;

/// Devices the level tables name that no model builds: devices.md
/// "A LEVEL outside these tables (B3SOI-PD at 57, SOI3 at 60 ...) is
/// refused with `UnsupportedDevice`", so no family selects them.
const not_built = [_][]const u8{ "b3soipd", "soi3" };

/// spice.zig's tables as text: module name to device, `.model` kind to
/// its letter's LEVEL table, and `table:level` to device.
const Tables = struct {
    modules: std.StringHashMapUnmanaged([]const u8) = .empty,
    kinds: std.StringHashMapUnmanaged([]const u8) = .empty,
    levels: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn read(a: std.mem.Allocator, src: []const u8) !Tables {
        var t: Tables = .{};
        var table: ?[]const u8 = null;
        var in_modules = false;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (std.mem.startsWith(u8, line, "pub const module_map")) in_modules = true;
            if (std.mem.startsWith(u8, line, "});")) in_modules = false;
            if (std.mem.startsWith(u8, line, "};")) table = null;
            if (std.mem.startsWith(u8, line, "const ") and std.mem.endsWith(u8, line, " = [_]Level{")) table = between(line, "const ", " =").?;
            if (in_modules and std.mem.startsWith(u8, line, ".{ \"")) {
                const name = between(line, "\"", "\"").?;
                try t.modules.put(a, name, between(line, "DeviceId.", " }").?);
            }
            if (std.mem.startsWith(u8, line, ".{ .letter = '")) {
                const levels = between(line, ".levels = &", " }").?;
                var kinds = std.mem.tokenizeAny(u8, between(line, ".kinds = &.{", "}").?, " ,\"");
                while (kinds.next()) |k| try t.kinds.put(a, k, levels);
            }
            if (table) |name| if (std.mem.startsWith(u8, line, ".{ .level = ")) {
                const level = between(line, ".level = ", ",").?;
                try t.levels.put(a, try std.mem.concat(a, u8, &.{ name, ":", level }), between(line, ".model = .", " }").?);
            };
        }
        return t;
    }

    /// The device a `.model <kind> level=<level>` card selects
    /// (net_devices.zig `deviceIdOf`, `inferDeviceFromModel`), or null
    /// for a kind outside the tables (a switch, a line, a passive).
    fn device(t: *const Tables, a: std.mem.Allocator, kind: []const u8, level: ?u16) !?[]const u8 {
        if (t.modules.get(kind)) |id| return id;
        if (std.mem.startsWith(u8, kind, "vdmos")) return "vdmos";
        const table = t.kinds.get(kind) orelse return null;
        return t.levels.get(try std.fmt.allocPrint(a, "{s}:{d}", .{ table, level orelse 1 })) orelse error.NoDeviceAtLevel;
    }
};

// ---- private ----

/// Lowers `.espice 1` + `body` as an include (no title line) and compares.
fn expectLowered(body: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", body, "\n" });
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .include);
    if (got.diags.len != 0) {
        for (got.diags) |d| std.debug.print("{any} at {any}: {s}\n", .{ d.code, lang.diag.lineCol(src, d.at), d.subject });
        return error.UnexpectedRows;
    }
    try testing.expectEqualStrings(want, got.text);
}

/// Lowers `body` and expects exactly one row, of `code`.
fn expectRefused(body: []const u8, code: Code) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", body, "\n" });
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .include);
    errdefer std.debug.print("{s}: {any}\n", .{ body, got.diags });
    try testing.expectEqual(1, got.diags.len);
    try testing.expectEqual(code, got.diags[0].code);
}

fn between(s: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const i = (std.mem.indexOf(u8, s, open) orelse return null) + open.len;
    const j = std.mem.indexOfPos(u8, s, i, close) orelse return null;
    return s[i..j];
}

fn sortedUnique(a: std.mem.Allocator, names: *std.ArrayList([]const u8)) ![]const u8 {
    std.sort.pdq([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    var last: []const u8 = "";
    for (names.items) |n| if (!std.mem.eql(u8, n, last)) {
        try out.print(a, "{s}\n", .{n});
        last = n;
    };
    return out.items;
}

test "every device spice.zig selects from a .model card is some family's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, "src/frontend/Circuit/spice.zig", a, .limited(1 << 20));
    const t = try Tables.read(a, src);
    // A capture with no rows means the capture broke.
    try testing.expect(t.modules.count() > 20 and t.kinds.count() > 10 and t.levels.count() > 30);

    var selected: std.ArrayList([]const u8) = .empty;
    var it = t.levels.valueIterator();
    while (it.next()) |id| try selected.append(a, id.*);
    var mt = t.modules.valueIterator();
    while (mt.next()) |id| try selected.append(a, id.*);
    // `.model x vdmos` selects VDMOS whatever the level (deviceIdOf).
    try selected.append(a, "vdmos");
    var want: std.ArrayList([]const u8) = .empty;
    var seen: usize = 0;
    for (selected.items) |id| {
        const skip = for (not_built) |n| {
            if (std.mem.eql(u8, id, n)) break true;
        } else false;
        seen += @intFromBool(skip);
        if (!skip) try want.append(a, id);
    }
    // A stale entry of `not_built` fails too.
    try testing.expectEqual(not_built.len, seen);

    var got: std.ArrayList([]const u8) = .empty;
    for (model.families.keys(), model.families.values()) |name, f| {
        errdefer std.debug.print("family {s}\n", .{name});
        const id = try t.device(a, f.n, f.level) orelse continue;
        try got.append(a, id);
        // Both polarities of a type-word family select the same device.
        if (f.polarity == .np_kind or f.polarity == .bjt_kind) try testing.expectEqualStrings(id, (try t.device(a, f.p, f.level)).?);
    }
    try testing.expectEqualStrings(try sortedUnique(a, &want), try sortedUnique(a, &got));
}

test "the spec page's family table names exactly the families" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/using/language.md", a, .limited(1 << 20));
    const head = "| Family | Polarity | Legacy `.model` type |\n|---|---|---|\n";
    var rest = page[(std.mem.indexOf(u8, page, head) orelse return error.NoFamilyTable) + head.len ..];
    var named: std.ArrayList([]const u8) = .empty;
    while (std.mem.startsWith(u8, rest, "| ")) {
        const end = std.mem.indexOfScalar(u8, rest, '\n').?;
        const cell = rest[2..std.mem.indexOfScalarPos(u8, rest, 2, '|').?];
        rest = rest[end + 1 ..];
        var words = std.mem.tokenizeScalar(u8, cell, '`');
        var odd = std.mem.startsWith(u8, cell, "`");
        while (words.next()) |w| : (odd = !odd) if (odd) try named.append(a, w);
    }
    var families: std.ArrayList([]const u8) = .empty;
    for (model.families.keys()) |k| try families.append(a, k);
    try testing.expectEqualStrings(try sortedUnique(a, &families), try sortedUnique(a, &named));
}

test "each family lowers to its legacy type, level and polarity" {
    try expectLowered(
        \\.model a1 mos1 type=n
        \\.model a2 mos2 type=p
        \\.model a3 mos3 type=n
        \\.model a4 mos6 type=n
        \\.model a5 mos9 type=n
        \\.model a6 bsim1 type=n
        \\.model a7 bsim2 type=n
        \\.model a8 bsim3 type=n
        \\.model a9 bsim4 type=p
        \\.model b1 bsimsoi type=n
        \\.model b2 b3soifd type=n
        \\.model b3 b3soidd type=n
        \\.model b4 hisim2 type=n
        \\.model b5 hisimhv type=n
        \\.model b6 bsimcmg type=n
        \\.model b7 bsimbulk type=n
        \\.model b8 bsimimg type=n
        \\.model b9 l_utsoi type=n
        \\.model c1 psp103 type=p
        \\.model c2 psp103_nqs type=p
        \\.model c3 psp103_t type=n
        \\.model c4 psp104 type=n
        \\.model c5 psp104_nqs type=n
        \\.model c6 psp104_t type=p
        \\.model c7 hisimsoi type=n
        \\.model c8 hisimsotb type=p
        \\.model c9 mosvar type=1 typep=1
        \\.model d1 vdmos type=n
        \\.model d2 vdmos type=p
        \\.model d3 asmhemt
        \\.model d4 mvsg type=p
        \\.model e1 gummel_poon type=pnp
        \\.model e2 vbic type=npn
        \\.model e3 hicuml2 type=npn
        \\.model e4 mextram type=pnp
        \\.model e5 mextram_t type=pnp
        \\.model e6 hicuml0 type=npn
        \\.model e7 asmesd type=pnp
        \\.model f1 diode
        \\.model f2 juncap200 type=p
        \\.model f3 diode_cmc
        \\.model f4 asmesd_dio
        \\.model f5 r2_cmc
        \\.model f6 r3_cmc type=1
        \\.model g1 jfet type=p
        \\.model g2 jfet2 type=n
        \\.model g3 mesfet type=n
        \\.model g4 mesa type=n
        \\.model g5 hfet1 type=p
        \\.model g6 hfet2 type=n
        \\.model h1 vswitch
        \\.model h2 cswitch
        \\.model h3 ltra
        \\.model h4 txl
        \\.model h5 cpl
        \\.model h6 urc
        \\.model h7 resistor
        \\.model h8 capacitor
        \\.model h9 inductor
        \\.model i1 opt
        \\.model i2 mosra tit0=1e-4
    ,
        \\.model a1 nmos level=1
        \\.model a2 pmos level=2
        \\.model a3 nmos level=3
        \\.model a4 nmos level=6
        \\.model a5 nmos level=9
        \\.model a6 nmos level=4
        \\.model a7 nmos level=5
        \\.model a8 nmos level=8
        \\.model a9 pmos level=14
        \\.model b1 nmos level=10
        \\.model b2 nmos level=55
        \\.model b3 nmos level=56
        \\.model b4 nmos level=68
        \\.model b5 nmos level=73
        \\.model b6 nmos level=72
        \\.model b7 nmos level=77
        \\.model b8 nmos level=78
        \\.model b9 nmos level=76
        \\.model c1 pmos level=1040
        \\.model c2 pspnqs103va type=-1
        \\.model c3 psp103tva type=1
        \\.model c4 psp104va type=1
        \\.model c5 pspnqs104va type=1
        \\.model c6 psp104tva type=-1
        \\.model c7 hisimsoi_va type=1
        \\.model c8 hisimsotb_va type=-1
        \\.model c9 mosvar type=1 typep=1
        \\.model d1 vdmos
        \\.model d2 vdmosp
        \\.model d3 asmhemt
        \\.model d4 mvsg_cmc type=-1
        \\.model e1 pnp level=1
        \\.model e2 npn level=4
        \\.model e3 npn level=8
        \\.model e4 pnp level=6
        \\.model e5 bjt505t type=-1
        \\.model e6 hicuml0va type=1
        \\.model e7 asmesd type=-1
        \\.model f1 d level=1
        \\.model f2 d level=6 type=-1
        \\.model f3 diode_cmc
        \\.model f4 asmesd_dio
        \\.model f5 r2_cmc
        \\.model f6 r3_cmc type=1
        \\.model g1 pjf level=1
        \\.model g2 njf level=2
        \\.model g3 nmf level=1
        \\.model g4 nmf level=2
        \\.model g5 pmf level=5
        \\.model g6 nmf level=6
        \\.model h1 sw
        \\.model h2 csw
        \\.model h3 ltra
        \\.model h4 txl
        \\.model h5 cpl
        \\.model h6 urc
        \\.model h7 r
        \\.model h8 c
        \\.model h9 l
        \\.model i1 opt
        \\.model i2 mosra level=1 tit0=1e-4
        \\
    );
}

test "a family's polarity is required, and only its own words" {
    try expectRefused(".model x psp104 w=1um", .missing_key);
    try expectRefused(".model x hicuml0 type=n", .unknown_family);
    try expectRefused(".model x juncap200 type=npn", .unknown_family);
    try expectRefused(".model x mvsg type=-1", .unknown_family);
}

test "waves: each keyed argument at its legacy position" {
    try expectLowered(
        \\V1 (a 0) vsource pulse(0, 1, td=1ns, tr=1ps, tf=1ps, pw=1ns, per=2ns, phase=90deg)
        \\V2 (a 0) vsource pulse(0, 1, phase=45)
        \\V3 (a 0) vsource am(1V, 0.5, fm=1kHz, fc=1MHz, td=1ns, phasec=10deg, phasem=20deg, off=0.1V)
        \\V4 (a 0) vsource am(1, 0.5, off=0.1)
        \\V5 (a 0) vsource sin(0, 1V, freq=1kHz, td=1ns, theta=1e3, phase=90deg)
        \\V6 (a 0) vsource exp(0, 1, td1=1ns, tau1=2ns, td2=3ns, tau2=4ns)
        \\V7 (a 0) vsource sffm(0, 1, fm=1kHz, mdi=5, fc=1MHz, td=1ns, phasem=10deg, phasec=20deg)
        \\V8 (a 0) vsource pwl((0, 0), (1ns, 1), r=0.5ns, td=2ns)
        \\I1 (a 0) isource am(1mA, 0.5, fm=1kHz, fc=1MHz, off=1mA)
    ,
        \\V1 a 0 PULSE(0 1 1n 1p 1p 1n 2n 90)
        \\V2 a 0 PULSE(0 1 0 0 0 0 0 45)
        \\V3 a 0 AM(1 0.5 1k 1meg 1n 10 20 0.1)
        \\V4 a 0 AM(1 0.5 0 0 0 0 0 0.1)
        \\V5 a 0 SIN(0 1 1k 1n 1e3 90)
        \\V6 a 0 EXP(0 1 1n 2n 3n 4n)
        \\V7 a 0 SFFM(0 1 1k 5 1meg 1n 10 20)
        \\V8 a 0 PWL(0 0 1n 1) r=0.5n td=2n
        \\I1 a 0 AM(1m 0.5 1k 1meg 0 0 0 1m)
        \\
    );
}

test "waves: a keyed argument of the wrong quantity or name is refused" {
    try expectRefused("V1 (a 0) vsource sin(0, 1, freq=1ns)", .wrong_unit);
    try expectRefused("V1 (a 0) vsource pulse(0, 1, phase=1ns)", .wrong_unit);
    try expectRefused("V1 (a 0) vsource pulse(0, 1, np=3)", .unknown_key);
    try expectRefused("V1 (a 0) vsource am(1, 0.5, vma=1)", .unknown_key);
    try expectRefused("V1 (a 0) vsource am(1, 0.5, fm=1ns)", .wrong_unit);
    try expectRefused("V1 (a 0) vsource pwl((0, 0), r=1V)", .wrong_unit);
    try expectRefused("V1 (a 0) vsource pat(1, 0, td=0, tr=1ps, tf=1ps, tsample=1ns, data=b01)", .wrong_kind);
    try expectRefused("V1 (a 0) vsource pat(1, 0, td=0, tr=1ps, tf=1ps, data=\"b01\")", .missing_key);
}
