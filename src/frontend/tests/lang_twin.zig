//! Whole-deck tests of the ESPice language through the reader's hooks.
//! Oracle: the legacy reader as reference implementation. A deck in the
//! language and its legacy twin, written by hand from the spec's Legacy
//! entries with every parameter folded by hand, elaborate (through
//! `Netlist.parse`, which lowers the first) to the same canonical dump.
//! And include expansion (source.zig) reads an included file in the
//! language as its legacy cards, and refuses one that does not lower.

const std = @import("std");
const testing = std.testing;
const netlist = @import("../Netlist.zig");
const Netlist = netlist.Netlist;
const Value = netlist.Value;

// ---- private ----

fn expectTwins(new: []const u8, legacy: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try netlist.parse(a, new);
    const want = try netlist.parse(a, legacy);
    try testing.expectEqualStrings(try dump(a, &want), try dump(a, &got));
    try testing.expectEqualDeep(want.deck.measures, got.deck.measures);
}

/// Each `.alter` run of `deck` (lowered when in the language) and of
/// `legacy` dumps the same.
fn expectAlterTwins(deck: []const u8, legacy: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try netlist.source.splitAlters(a, try netlist.lang.lower(testing.allocator, a, deck, "deck.sp", .top));
    const want = try netlist.source.splitAlters(a, legacy);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(try dump(a, &try netlist.parse(a, w)), try dump(a, &try netlist.parse(a, g)));
}

/// Everything the reader decided that a card's spelling does not change:
/// devices, models, analyses, options, initial conditions and saves.
fn dump(a: std.mem.Allocator, nl: *const Netlist) ![]const u8 {
    var w: std.ArrayList(u8) = .empty;
    try w.print(a, "title {s}\n", .{nl.deck.title});
    for (0..nl.deviceCount()) |e| {
        const d = nl.device(.from(e));
        try w.print(a, "device {s} {c} {d} {d} pins", .{ d.name, d.kind, d.model_row, d.subckt_instance });
        for (d.pins) |p| try w.print(a, " {s}", .{nl.netName(p)});
        for (d.positional) |v| try value(a, &w, nl, v);
        for (d.kv) |kv| {
            try w.print(a, " {s}=", .{kv.key});
            try value(a, &w, nl, kv.value);
        }
        try w.append(a, '\n');
    }
    for (nl.models) |m| {
        try w.print(a, "model {s} {s}", .{ m.name, m.kind });
        for (m.kv) |kv| {
            try w.print(a, " {s}=", .{kv.key});
            try value(a, &w, nl, kv.value);
        }
        try w.append(a, '\n');
    }
    for (nl.deck.analyses) |an| {
        try w.print(a, "analysis {t} {t} {d} {d}", .{ an.kind, an.sweep, an.pos, an.neg });
        for (an.args) |v| try value(a, &w, nl, v);
        try w.append(a, '\n');
    }
    for (nl.deck.config) |c| {
        try w.print(a, "config {}", .{c.temp});
        for (c.args) |v| try value(a, &w, nl, v);
        try w.append(a, '\n');
    }
    for (nl.deck.ic) |ic| try w.print(a, "ic {s} {e}\n", .{ nl.netName(ic.net), ic.value });
    for (nl.deck.nodeset) |ic| try w.print(a, "nodeset {s} {e}\n", .{ nl.netName(ic.net), ic.value });
    for (nl.deck.saves) |s| try w.print(a, "save {s}\n", .{s});
    try w.print(a, "variations {d}\n", .{nl.deck.variations.len});
    return w.items;
}

fn value(a: std.mem.Allocator, w: *std.ArrayList(u8), nl: *const Netlist, v: Value) !void {
    switch (v) {
        .num => |x| try w.print(a, " {e}", .{x}),
        .name => |s| try w.print(a, " '{s}'", .{s}),
        .expr => |span| {
            try w.appendSlice(a, " expr[");
            for (nl.exprOps(span)) |op| try w.print(a, "{t}:{d}:{d} ", .{ op.code, if (op.code == .num) nl.consts[op.a] else @as(f64, @floatFromInt(op.a)), op.b });
            try w.append(a, ']');
        },
        .group => |g| {
            try w.appendSlice(a, " (");
            for (g.items) |item| try value(a, w, nl, item);
            try w.append(a, ')');
        },
    }
}

test "parameters, functions, models, options, state and analyses read as their legacy twin" {
    try expectTwins(
        \\.espice 1
        \\.title "twin"
        \\.param vdd = 1.8V  tr = 20ps  half = vdd/2  p = 2**3  q = pwr(-2, 3)  r = idiv(7, 2)
        \\.func par(a, b) = a*b/(a + b)
        \\.param s = par(2, 2)  t = int(-2.5) + sqr(3) + log(1)  u = 7 % 4
        \\.model m1 resistor r=p rsh=q w=r l=s tc1=t tc2=u
        \\.model m2 resistor r=half dw=tr
        \\.model nch bsim4 type=n vth0=0.45 tox=4n
        \\.model pch mos1 type=p vto=-0.7
        \\.model dmod diode is=1e-14 n=1.05
        \\.model q1 gummel_poon type=npn bf=120
        \\.model sw1 vswitch vt=0.5 vh=0.1 ron=1 roff=1G
        \\.model rmod resistor r=tol(1k, lot=gauss(5%), dev=unif(2%))
        \\.option reltol=1e-4 method=gear temp=27C abstol=1pA
        \\.probe v(out) v(a)
        \\.op
        \\.dc temp=lin(-40C, 125C, step=5C)
        \\.ac freq=dec(1Hz, 1GHz, n=20)
        \\.tran stop=10us step=1ns maxstep=10ns
    ,
        \\twin
        \\.model m1 r r=8 rsh=-8 w=3 l=1 tc1=7 tc2=3
        \\.model m2 r r=0.9 dw=20p
        \\.model nch nmos level=14 vth0=0.45 tox=4n
        \\.model pch pmos level=1 vto=-0.7
        \\.model dmod d level=1 is=1e-14 n=1.05
        \\.model q1 npn level=1 bf=120
        \\.model sw1 sw vt=0.5 vh=0.1 ron=1 roff=1g
        \\.model rmod r r=1k lot/gauss=5% dev/unif=2%
        \\.options reltol=1e-4 method=gear temp=27 abstol=1p
        \\.save v(out) v(a)
        \\.op
        \\.dc temp -40 125 5
        \\.ac dec 20 1 1g
        \\.tran 1n 10u 0 10n
        \\
    );
}

test "an .if chain keeps the first true branch, as its legacy twin's folded deck" {
    try expectTwins(
        \\.espice 1
        \\.param corner = 2
        \\.if corner == 1 {
        \\    .param rv = 1k
        \\}
        \\.elseif corner == 2 {
        \\    .param rv = 2k
        \\}
        \\.else {
        \\    .param rv = 3k
        \\}
        \\.model m resistor r=rv
    ,
        \\
        \\.model m r r=2k
        \\
    );
}

test ".alter runs split from the lowered deck as from their legacy twin (Jobs.prepare's order)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lowered = try netlist.lang.lower(testing.allocator, a, ".espice 1\n.title \"t\"\n.model m resistor r=1k\n.alter {\n    .model m resistor r=2k\n}\n", "deck.sp", .top);
    const got = try netlist.source.splitAlters(a, lowered);
    const want = try netlist.source.splitAlters(a, "t\n.model m r r=1k\n.alter\n.model m r r=2k\n");
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(try dump(a, &try netlist.parse(a, w)), try dump(a, &try netlist.parse(a, g)));
}

test ".alter replaces an instance by its name, whatever head the lowering gave it" {
    // Oracle: the legacy twin, whose alter card replaces its base card.
    const legacy = "t\n.model nch nmos level=1\nv1 d 0 DC 1\nM1 d d 0 0 nch w=1u l=1u\nRload d 0 1k\n.op\n.alter\nM1 d d 0 0 nch w=2u l=1u\nRload d 0 2k\n";
    try expectAlterTwins(
        \\.espice 1
        \\.title "t"
        \\.model nch mos1 type=n
        \\v1 (d 0) vsource 1
        \\M1 (d d 0 0) nch w=1um l=1um
        \\load (d 0) resistor 1k
        \\.op
        \\.alter {
        \\    M1 (d=d g=d s=0 b=0) nch w=2um l=1um
        \\    load (d 0) resistor 2k
        \\}
    , "t\n.model nch nmos level=1\nv1 d 0 DC 1\nM1 d d 0 0 nch w=1u l=1u\nr@load d 0 1k\n.op\n.alter\nM1 d d 0 0 nch w=2u l=1u\nr@load d 0 2k\n");
    // A legacy card replaces a `?@` one: the lowering's base, a legacy alter.
    try expectAlterTwins("t\n.model nch nmos level=1\nv1 d 0 DC 1\n?@M1 (d d 0 0) nch w=1u l=1u\nRload d 0 1k\n.op\n.alter\nM1 d d 0 0 nch w=2u l=1u\nr@Rload d 0 2k\n", legacy);
}

test ".alter re-stating an instance unchanged runs as the base deck" {
    // Oracle: metamorphic; an alter that changes nothing changes no run.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deck = ".espice 1\n.model nch mos1 type=n\nv1 (d 0) vsource 1\nM1 (d d 0 0) nch w=1um l=1um\nload (d 0) resistor 1k\n.op\n.alter {\n    M1 (d d 0 0) nch w=1um l=1um\n    load (d 0) resistor 1k\n}\n";
    const runs = try netlist.source.splitAlters(a, try netlist.lang.lower(testing.allocator, a, deck, "deck.sp", .top));
    try testing.expectEqual(2, runs.len);
    try testing.expectEqualStrings(try dump(a, &try netlist.parse(a, runs[0])), try dump(a, &try netlist.parse(a, runs[1])));
}

test "include expansion reads an included file in the language, and refuses one that does not lower" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "inc.sp", .data = ".espice 1\n.model m resistor r=1kOhm\n.lib tt {\n    .param x = 1\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.sp", .data = ".espice 1\n.model m resistor r=1M\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.sp", .data = "* a legacy file\n.param y=2\n" });
    const deck = try a.print(".zig-cache/tmp/{s}/deck.sp", .{tmp.sub_path});
    // Oracle: the same expansion of the file's hand-written legacy twin.
    try tmp.dir.writeFile(io, .{ .sub_path = "twin.sp", .data = ".model m r r=1k\n.lib tt\n.param x=1\n.endl\n" });
    const got = try netlist.source.expand(io, testing.allocator, a, deck, "t\n.include 'inc.sp'\n.lib 'inc.sp' tt\n");
    const want = try netlist.source.expand(io, testing.allocator, a, deck, "t\n.include 'twin.sp'\n.lib 'twin.sp' tt\n");
    try testing.expectEqualStrings(want, got);
    // A new file includes a legacy one.
    try tmp.dir.writeFile(io, .{ .sub_path = "top.sp", .data = ".espice 1\n.include \"legacy.sp\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top_twin.sp", .data = ".include \"legacy.sp\"\n" });
    const top = try netlist.source.expand(io, testing.allocator, a, deck, "t\n.include 'top.sp'\n");
    try testing.expectEqualStrings(try netlist.source.expand(io, testing.allocator, a, deck, "t\n.include 'top_twin.sp'\n"), top);
    try testing.expectError(error.InvalidLanguageInclude, netlist.source.expand(io, testing.allocator, a, deck, "t\n.include 'bad.sp'\n"));
}

test "a deck that does not lower fails the parse with ParseError" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseError, netlist.parse(arena.allocator(), ".espice 1\n.tran stop=1V step=1ns\n"));
}

test "every primitive, sources and waves read as their legacy twin" {
    try expectTwins(
        \\.espice 1
        \\.title "primitives"
        \\R1  (a b)        resistor  1k tc1=1e-3
        \\Rb  (n=b p=a)    resistor  r=2kOhm m=2
        \\C1  (a 0)        capacitor 1pF ic=0.9V
        \\L1  (a b)        inductor  1nH ic=1mA
        \\L2  (b 0)        inductor  2nH
        \\K1  ()           mutual    0.99 inductors=[L1, L2]
        \\Vs  (s 0)        vsource   0
        \\E1  (out 0 a b)  vcvs      2
        \\G1  (out 0 a b)  vccs      1mS m=2
        \\F1  (out 0)      cccs      5 probe=Vs
        \\H1  (out 0)      ccvs      1kOhm probe=Vs
        \\T1  (a 0 b 0)    tline     z0=50Ohm td=1ns
        \\Vin (in 0)  vsource dc=0 ac=1 pulse(0, 1.8V, td=1ns, tr=20ps, tf=20ps, pw=2ns, per=4ns)
        \\Vp  (pp 0)  vsource dc=1 port=1 z0=50Ohm
        \\Ib  (0 n1)  isource 10uA ac=1m acphase=90deg m=2
        \\V1 (a1 0) vsource sin(0, 1V, freq=1kHz)
        \\V2 (b1 0) vsource pwl((0, 0), (1ns, 1.8V), (2ns, 0), r=0)
        \\V3 (c1 0) vsource pat(1.8V, 0, td=0, tr=50ps, tf=50ps, tsample=1ns, data="b0101")
        \\V4 (d1 0) vsource pulse(0, 1V, tr=10ps, tf=10ps, pw=1ns, per=2ns, phase=90deg)
        \\V5 (e1 0) vsource am(1V, 0.5, fm=1kHz, fc=1MHz, off=0.1V)
        \\V6 (f1 0) vsource exp(0, 1, td1=1ns, tau1=2ns, td2=3ns, tau2=4ns) distof1=(1, 90)
        \\V7 (g1 0) vsource sffm(0, 1, fm=1kHz, mdi=5, fc=1MHz)
    ,
        \\primitives
        \\R1 a b 1k tc1=1e-3
        \\Rb a b 2k m=2
        \\C1 a 0 1p ic=0.9
        \\L1 a b 1n ic=1m
        \\L2 b 0 2n
        \\K1 L1 L2 0.99
        \\Vs s 0 DC 0
        \\E1 out 0 a b 2
        \\G1 out 0 a b 1m m=2
        \\F1 out 0 Vs 5
        \\H1 out 0 Vs 1k
        \\T1 a 0 b 0 Z0=50 TD=1n
        \\Vin in 0 DC 0 AC 1 PULSE(0 1.8 1n 20p 20p 2n 4n)
        \\Vp pp 0 DC 1 portnum 1 z0 50
        \\Ib 0 n1 DC 10u AC 1m 90 m=2
        \\V1 a1 0 SIN(0 1 1k)
        \\V2 b1 0 PWL(0 0 1n 1.8 2n 0) r=0
        \\V3 c1 0 PAT(1.8 0 0 50p 50p 1n b0101)
        \\V4 d1 0 PULSE(0 1 0 10p 10p 1n 2n 90)
        \\V5 e1 0 AM(1 0.5 1k 1meg 0 0 0 0.1)
        \\V6 f1 0 EXP(0 1 1n 2n 3n 4n) DISTOF1 1 90
        \\V7 g1 0 SFFM(0 1 1k 5 1meg)
        \\
    );
}

test "behavioural sources and passives read as their legacy twin" {
    // A form's legacy card has its own letter, and a legacy name starts
    // with its letter: the new deck names each form as its twin does.
    try expectTwins(
        \\.espice 1
        \\B1 (out 0) bsource v=v(a)*v(b) tc1=1m
        \\B2 (out 0) bsource i=v(ctl) > 0.5 ? 1mA : 0
        \\E3 (o3 0)  bsource v=laplace(v(in), num=[1], den=[1, 1ms])
        \\E4 (o4 0)  bsource v=poly([v(a), v(c, d)], coeffs=[0, 1, 1])
        \\V1 (s 0)   vsource 0
        \\F5 (o5 0)  bsource i=poly([i(V1)], coeffs=[1m, 2])
        \\G6 (o6 0)  bsource i=table(v(in), (0, 0), (1, 1mA))
        \\E7 (o7 0)  bsource v=delay(v(in), td=1ns)
        \\E8 (o8 0)  bsource v=pole(v(a, b), 2, zeros=[(1, 0)], poles=[(10, 0), (20, 1kHz)])
        \\R3 (a b)   resistor 1k*(1 + v(ctl))
        \\C2 (a b)   capacitor q=1pF*v(a, b)
    ,
        \\
        \\B1 out 0 V={v(a)*v(b)} tc1=1m
        \\B2 out 0 I={v(ctl) > 0.5 ? 1m : 0}
        \\E3 o3 0 LAPLACE in 0 1 / 1 1m
        \\E4 o4 0 POLY(2) a 0 c d 0 1 1
        \\V1 s 0 DC 0
        \\F5 o5 0 POLY(1) V1 1m 2
        \\G6 o6 0 TABLE {v(in)} = (0,0) (1,1m)
        \\E7 o7 0 DELAY in 0 TD=1n
        \\E8 o8 0 POLE a b 2 1,0 / 1 10,0 20,1k
        \\R3 a b {1k*(1+v(ctl))}
        \\C2 a b q={1p*v(a,b)}
        \\
    );
}

test "a device of every modelled kind, by position and by port name, reads as its legacy twin" {
    // `area=` stays a key: the builder reads it as the positional area
    // (Circuit/net_devices.zig, INP2Q/D/J/Z).
    try expectTwins(
        \\.espice 1
        \\.model nch  bsim4 type=n vth0=0.45
        \\.model q1   gummel_poon type=npn bf=120
        \\.model dmod diode is=1e-14
        \\.model jm   jfet type=n
        \\.model zm   mesfet type=n
        \\.model sw1  vswitch vt=0.5 vh=0.1 ron=1 roff=1G
        \\.model cs1  cswitch it=1m ih=0.1m ron=1 roff=1G
        \\.model lt   ltra r=0.1 l=1n g=0 c=1p len=1
        \\.model tx   txl r=0.1 l=1n g=0 c=1p length=1
        \\.model cp   cpl length=1
        \\.model rc   urc k=1.2 fmax=1G rperl=1k cperl=1p
        \\.model rm   resistor rsh=10
        \\.model vd   vdmos type=n
        \\Vs (s 0)                  vsource 0
        \\M1 (d=out g=in s=0 b=0)   nch w=1um l=180nm
        \\M2 (out in 0 0)           nch w=2um l=180nm m=2
        \\Q1 (c b e)                q1 area=2
        \\Q2 (e=e b=b c=c s=0)      q1
        \\D1 (a k)                  dmod area=2
        \\D2 (k=0 a=a)              dmod off
        \\J1 (d g s)                jm area=2
        \\Z1 (s=s g=g d=d)          zm
        \\S1 (p n cp cn)            sw1 initial=on
        \\W1 (n=n p=p)              cs1 probe=Vs initial=off
        \\O1 (a1=a b1=0 a2=b b2=0)  lt
        \\Y1 (a 0 b 0)              tx
        \\P1 (i1 i2 0 o1 o2 0)      cp
        \\U1 (n1=a n2=b n3=0)       rc l=1mm
        \\R9 (a b)                  rm l=10um w=1um
        \\M9 (s=0 g=g d=d)          vd
    ,
        \\
        \\.model nch nmos level=14 vth0=0.45
        \\.model q1 npn level=1 bf=120
        \\.model dmod d level=1 is=1e-14
        \\.model jm njf level=1
        \\.model zm nmf level=1
        \\.model sw1 sw vt=0.5 vh=0.1 ron=1 roff=1g
        \\.model cs1 csw it=1m ih=0.1m ron=1 roff=1g
        \\.model lt ltra r=0.1 l=1n g=0 c=1p len=1
        \\.model tx txl r=0.1 l=1n g=0 c=1p length=1
        \\.model cp cpl length=1
        \\.model rc urc k=1.2 fmax=1g rperl=1k cperl=1p
        \\.model rm r rsh=10
        \\.model vd vdmos
        \\Vs s 0 DC 0
        \\M1 out in 0 0 nch w=1u l=180n
        \\M2 out in 0 0 nch w=2u l=180n m=2
        \\Q1 c b e q1 area=2
        \\Q2 c b e 0 q1
        \\D1 a k dmod area=2
        \\D2 a 0 dmod off
        \\J1 d g s jm area=2
        \\Z1 d g s zm
        \\S1 p n cp cn sw1 on
        \\W1 p n Vs cs1 off
        \\O1 a 0 b 0 lt
        \\Y1 a 0 b 0 tx
        \\P1 i1 i2 0 o1 o2 0 cp
        \\U1 a b 0 rc l=1m
        \\R9 a b rm l=10u w=1u
        \\M9 d g 0 vd
        \\
    );
}

test "a subcircuit with named ports, and a Verilog-A module instance, read as their legacy twin" {
    try expectTwins(
        \\.espice 1
        \\.subckt cell (a b c) g=1 {
        \\    R1 (a b) resistor 1k*g
        \\    C1 (b c) capacitor 1pF
        \\    .subckt leaf (x y) {
        \\        R2 (x y) resistor 2k
        \\    }
        \\    X9 (y=c x=b) leaf
        \\}
        \\X1 (c=0 a=in b=out) cell g=2
        \\X2 (in mid 0) cell
        \\N1 (d g s b) psp103va w=1um
    ,
        \\
        \\.subckt cell a b c g=1
        \\R1 a b '1k*g'
        \\C1 b c 1p
        \\.subckt leaf x y
        \\R2 x y 2k
        \\.ends
        \\X9 b c leaf
        \\.ends
        \\X1 in out 0 cell g=2
        \\X2 in mid 0 cell
        \\N1 d g s b psp103va w=1u
        \\
    );
}

test "the spec's opening inverter reads as its legacy twin" {
    // The page's first fence, its `.lib` replaced by the two models it
    // would read.
    const new =
        \\.espice 1
        \\.title "Inverter delay across process"
        \\.model nch bsim4 type=n
        \\.model pch bsim4 type=p
        \\.option reltol=1e-4 temp=27C
        \\
        \\.param vdd = 1.8V
        \\.param wn  = agauss(420nm, 5nm, 3)
        \\
        \\.subckt inv (in out vdd vss) wn=420nm wp=1um {
        \\    Mn (d=out g=in s=vss b=vss) nch w=wn l=150nm
        \\    Mp (d=out g=in s=vdd b=vdd) pch w=wp l=150nm
        \\}
        \\
        \\Vdd (vdd 0)        vsource   dc=vdd
        \\Vin (in 0)         vsource   pulse(0, vdd, td=1ns, tr=20ps, tf=20ps, pw=2ns, per=4ns)
        \\X1  (in out vdd 0) inv       wn=wn
        \\Cl  (out 0)        capacitor 5fF
        \\
        \\.tran stop=8ns step=10ps sweep monte(200)
        \\
        \\.meas tran tphl = cross(v(out), vdd/2, fall=1) - cross(v(in), vdd/2, rise=1)
        \\.meas tran ipk  = max(i(Vdd), from=1ns)
        \\.probe v(out) i(Vdd)
    ;
    const legacy =
        \\Inverter delay across process
        \\.model nch nmos level=14
        \\.model pch pmos level=14
        \\.options reltol=1e-4 temp=27
        \\.param vdd=1.8
        \\.param wn=agauss(420n, 5n, 3)
        \\.subckt inv in out vdd vss wn=420n wp=1u
        \\Mn out in vss vss nch w=wn l=150n
        \\Mp out in vdd vdd pch w=wp l=150n
        \\.ends
        \\Vdd vdd 0 DC {vdd}
        \\Vin in 0 PULSE(0 {vdd} 1n 20p 20p 2n 4n)
        \\X1 in out vdd 0 inv wn={wn}
        \\Cl out 0 5f
        \\.tran 10p 8n sweep monte=200
        \\.meas tran tphl trig v(in) val='vdd/2' rise=1 targ v(out) val='vdd/2' fall=1
        \\.meas tran ipk max i(Vdd) from=1n
        \\.save v(out) i(Vdd)
        \\
    ;
    try expectTwins(new, legacy);
}

test "a FAIL= test and a .wcd bound echo one spelling, whatever the blanks of either dialect" {
    // Oracle: the legacy twin with the blanks the legacy decks write; the
    // reader keeps the text the report echoes (listing.zig, wcd.zig).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const new = try netlist.parse(a,
        \\.espice 1
        \\.param z = agauss(0, 1, 1)
        \\V1 (in 0) vsource 1
        \\R1 (in 0) resistor 1k
        \\.dc V1=lin(1, 2, step=1) sweep monte(10, sigma_scale=[2, 3], fail=m > 5)
        \\.meas dc m = find(v(in), at=1)
        \\.wcd (m <= 0.91)
    );
    const legacy = try netlist.parse(a, "t\n.param z=agauss(0,1,1)\nV1 in 0 DC 1\nR1 in 0 1k\n.dc V1 1 2 1 sweep monte=10 sigma_scale=2,3 fail='m>5'\n.meas dc m find v(in) at=1\n.wcd m '<=0.91'\n");
    for ([_]Netlist{ new, legacy }) |nl| {
        try testing.expectEqualStrings("m > 5", nl.deck.analyses[0].sweep.monte.fail.text);
        try testing.expectEqualStrings("<= 0.91", nl.deck.wcd.?.specs[0].bound);
    }
}
