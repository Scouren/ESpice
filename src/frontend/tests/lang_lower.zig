//! Tests of the ESPice language's lowering, one construct at a time.
//! Oracle: the legacy card written by hand from the construct's Legacy
//! entry in docs/using/language.md (and, for expressions, the legacy
//! function semantics in docs/using/reference.md "Expressions"); codes
//! pinned for every refusal.

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const Code = lang.diag.Code;

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

test "parameters and functions" {
    try expectLowered(".param vdd = 1.8V  tr = 20ps\n.param half = vdd/2\n.func  par(a, b) = a*b/(a + b)\n",
        \\.param vdd=1.8 tr=20p
        \\.param half='vdd/2'
        \\.func par(a, b) {a*b/(a+b)}
        \\
    );
}

test "expressions in a parameter: numparam's functions give the language's values" {
    try expectLowered(
        \\.param p1 = a**b  p2 = pow(a, b)  p3 = pwr(a, 3)  p4 = idiv(7, 2)
        \\.param p5 = int(x) + sqr(x) + log(x)  p6 = x % 3  p7 = a == b < c  p8 = -(a - b)
        \\.param p9 = c ? -a**2 : a != b && !d
    ,
        \\.param p1='pow(a,b)' p2='pow(a,b)' p3='(sgn(a)*a**3)' p4='(7\2)'
        \\.param p5='int(x)+sqr(x)+log(x)' p6='x%3' p7='a==(b<c)' p8='-(a-b)'
        \\.param p9='c?-pow(a,2):a!=b&&!d'
        \\
    );
}

test "expressions in a behavioural source: the B parser's functions give the language's values" {
    try expectLowered(
        \\B1 (o 0) bsource v=v(a)**2 + v(a)**3 + v(a)**0.5 + v(a)**p
        \\B2 (o 0) bsource i=int(v(a)) + sqr(v(a)) + idiv(v(a), 2) + v(a) % 2 + pwr(v(a), 2)
    ,
        \\B1 o 0 v={pow(v(a),2)+pwr(v(a),3)+pow(v(a),0.5)+((p)-2*floor((p)/2)==0?pow(v(a),p):pwr(v(a),p))}
        \\B2 o 0 i={(sgn(v(a))*floor(abs(v(a))))+(v(a)*v(a))+floor(abs(v(a)/2))+(v(a)-2*sgn(v(a)/2)*floor(abs(v(a)/2)))+(sgn(v(a))*v(a)**2)}
        \\
    );
}

test "a .func body is written the same for either legacy parser" {
    try expectLowered(".func f(x, y) = x**2 + x**3 + x**y\n",
        \\.func f(x, y) {(x**2)+(sgn(x)*x**3)+((y)-2*floor((y)/2)==0?(x**y):(sgn(x)*x**y))}
        \\
    );
}

test "models: the family table's type and level, tol as LOT and DEV" {
    try expectLowered(
        \\.model dmod diode is=1e-14 n=1.05
        \\.model nch  bsim4 type=n vth0=0.45 tox=4n
        \\.model pch  mos1 type=p {
        \\    vto = -0.7
        \\}
        \\.model q1   gummel_poon type=npn bf=120
        \\.model sw1  vswitch vt=0.5 vh=0.1 ron=1 roff=1G
        \\.model rmod resistor r=tol(1k, lot=gauss(5%), dev=unif(2%))
        \\.model vd vdmos type=p
        \\.model p psp103va type=-1 w=1um
    ,
        \\.model dmod d level=1 is=1e-14 n=1.05
        \\.model nch nmos level=14 vth0=0.45 tox=4n
        \\.model pch pmos level=1 vto=-0.7
        \\.model q1 npn level=1 bf=120
        \\.model sw1 sw vt=0.5 vh=0.1 ron=1 roff=1g
        \\.model rmod r r=1k lot/gauss=5% dev/unif=2%
        \\.model vd vdmosp
        \\.model p psp103va type=-1 w=1u
        \\
    );
}

test "subcircuits and modelled instances" {
    try expectLowered(
        \\.subckt inv (in out vdd vss) wn=420nm wp=1um {
        \\    Mn (out in vss vss) nch w=wn l=150nm
        \\    Mp (d=out g=in s=vdd b=vdd) pch w=wp l=150nm
        \\}
        \\X1 (in=a out=b vdd=vdd vss=0) inv wp=2um
        \\D1 (a k) dmod area=2
        \\W1 (p n) swmod probe=Vsense initial=off off
        \\"x<1>" ("n<3>" 0) "resistor"
        \\X2 (a) one
    ,
        \\.subckt inv in out vdd vss wn=420n wp=1u
        \\?@Mn (out in vss vss) nch w=wn l=150n
        \\?@Mp (d=out g=in s=vdd b=vdd) pch w=wp l=150n
        \\.ends
        \\?@X1 (in=a out=b vdd=vdd vss=0) inv wp=2u
        \\?@D1 (a k) dmod area=2
        \\?@W1 (p n) swmod probe=Vsense initial=off off
        \\?@x<1> (n<3> 0) resistor
        \\?@X2 (a) one
        \\
    );
}

test "primitives, named ports in the primitive's order" {
    try expectLowered(
        \\R1  (a b)        resistor  1k tc1=1e-3
        \\R2  (n=b p=a)    resistor  r=2k
        \\C1  (a 0)        capacitor 1pF ic=0.9V
        \\L1  (a 0)        inductor  1nH
        \\K1  ()           mutual    0.99 inductors=[L1, L2]
        \\E1  (out 0 a b)  vcvs      2
        \\G1  (out 0 a b)  vccs      1mS m=2
        \\F1  (out 0)      cccs      5 probe=Vsense
        \\H1  (out 0)      ccvs      1kOhm probe=Vsense
        \\T1  (a 0 b 0)    tline     z0=50Ohm td=1ns
        \\R3  (a b)        resistor  1k*(1 + v(ctl))
        \\C2  (a b)        capacitor q=1pF*v(a, b)
    ,
        \\R1 a b 1k tc1=1e-3
        \\R2 a b 2k
        \\C1 a 0 1p ic=0.9
        \\L1 a 0 1n
        \\K1 L1 L2 0.99
        \\E1 out 0 a b 2
        \\G1 out 0 a b 1m m=2
        \\F1 out 0 Vsense 5
        \\H1 out 0 Vsense 1k
        \\T1 a 0 b 0 z0=50 td=1n
        \\R3 a b {1k*(1+v(ctl))}
        \\C2 a b q={1p*v(a,b)}
        \\
    );
}

test "sources and waves" {
    try expectLowered(
        \\Vdd (vdd 0) vsource 1.8V
        \\Vin (in 0)  vsource dc=0 ac=1 pulse(0, 1.8V, td=1ns, tr=20ps, tf=20ps, pw=2ns, per=4ns)
        \\Vp  (a 0)   vsource dc=1 port=1 z0=50Ohm
        \\Ib  (0 n1)  isource 10uA ac=1m acphase=90deg m=2
        \\V1 (a 0) vsource sin(0, 1V, freq=1kHz)
        \\V2 (b 0) vsource pwl((0, 0), (1ns, 1.8V), (2ns, 0), r=0)
        \\V3 (c 0) vsource pat(1.8V, 0, td=0, tr=50ps, tf=50ps, tsample=1ns, data="b0101")
        \\V4 (d 0) vsource pulse(0, 1, pw=1ns)
        \\V5 (e 0) vsource sffm(0, 1, fm=1kHz, fc=1MHz)
        \\V6 (f 0) vsource exp(0, 1, tau2=1ns) distof1=(1, 90)
    ,
        \\Vdd vdd 0 DC 1.8
        \\Vin in 0 DC 0 AC 1 PULSE(0 1.8 1n 20p 20p 2n 4n)
        \\Vp a 0 DC 1 portnum 1 z0 50
        \\Ib 0 n1 DC 10u AC 1m 90 m=2
        \\V1 a 0 SIN(0 1 1k)
        \\V2 b 0 PWL(0 0 1n 1.8 2n 0) r=0
        \\V3 c 0 PAT(1.8 0 0 50p 50p 1n b0101)
        \\V4 d 0 PULSE(0 1 0 0 0 1n)
        \\V5 e 0 SFFM(0 1 1k 90 1meg)
        \\V6 f 0 EXP(0 1 0 0 0 1n) DISTOF1 1 90
        \\
    );
}

test "behavioural forms" {
    try expectLowered(
        \\B1 (out 0) bsource v=v(a)*v(b) tc1=1m
        \\B2 (out 0) bsource i=v(ctl) > 0.5 ? 1mA : 0
        \\B3 (out 0) bsource v=laplace(v(in), num=[1], den=[1, 1ms])
        \\B4 (o 0) bsource v=poly([v(a), v(c, d)], coeffs=[0, 1, 1])
        \\B5 (o 0) bsource i=poly([i(V1)], coeffs=[1m, 2])
        \\B6 (o 0) bsource i=table(v(in), (0, 0), (1, 1mA))
        \\B7 (o 0) bsource v=delay(v(in), td=1ns)
        \\B8 (o 0) bsource v=pole(v(a, b), 2, zeros=[(1, 0)], poles=[(10, 0), (20, 1kHz)])
    ,
        \\B1 out 0 v={v(a)*v(b)} tc1=1m
        \\B2 out 0 i={v(ctl)>0.5?1m:0}
        \\e@B3 out 0 laplace in 0 1 / 1 1m
        \\e@B4 o 0 poly(2) a 0 c d 0 1 1
        \\f@B5 o 0 poly(1) V1 1m 2
        \\g@B6 o 0 table {v(in)} = (0,0) (1,1m)
        \\e@B7 o 0 delay in 0 td=1n
        \\e@B8 o 0 pole a b 2 1,0 / 1 10,0 20,1k
        \\
    );
}

test "structure, files, options and state" {
    try expectLowered(
        \\.global n1 n2
        \\.connect a b
        \\.param corner = 1
        \\.if corner == 1 {
        \\    R1 (a b) resistor 1k
        \\}
        \\.elseif corner == 2 {
        \\}
        \\.else {
        \\    R1 (a b) resistor 2k
        \\}
        \\.include "x.sp"
        \\.lib "pdk.lib" tt
        \\.lib ff {
        \\    .param a = 1
        \\}
        \\.hdl "m.va"
        \\.verilog "d.v"
        \\.vec "s.vec"
        \\.load file="x.ic"
        \\.load
        \\.save type=ic file="x.ic" level=top time=1ns
        \\.save
        \\.option reltol=1e-4 method=gear temp=27C soa accurate
        \\.ic v(out)=0.9V v(x1.q)=0
        \\.nodeset v(a)=1
        \\.probe v(out) i(Vdd) v(a, b)
    ,
        \\.global n1 n2
        \\.connect a b
        \\.param corner=1
        \\.if (corner==1)
        \\R1 a b 1k
        \\.elseif (corner==2)
        \\.else
        \\R1 a b 2k
        \\.endif
        \\.include "x.sp"
        \\.lib "pdk.lib" tt
        \\.lib ff
        \\.param a=1
        \\.endl
        \\.hdl "m.va"
        \\.verilog "d.v"
        \\.vec "s.vec"
        \\.load file="x.ic"
        \\.load
        \\.save type=ic file="x.ic" level=top time=1n
        \\.save type=nodeset
        \\.options reltol=1e-4 method=gear temp=27 accurate soa
        \\.ic v(out)=0.9 v(x1.q)=0
        \\.nodeset v(a)=1
        \\.save v(out) i(Vdd) v(a,b)
        \\
    );
}

test "the title is the first line, and .alter runs follow it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const deck = try lang.lowerRows(testing.allocator, arena.allocator(), ".espice 1\n.param a = 1\n.title \"My deck\"\n.alter {\n.param a = 2\n}\n.alter {\n.param a = 3\n}\n", .top);
    try testing.expectEqual(0, deck.diags.len);
    try testing.expectEqualStrings("My deck\n.param a=1\n.alter\n.param a=2\n.alter\n.param a=3\n", deck.text);
    const inc = try lang.lowerRows(testing.allocator, arena.allocator(), ".espice 1\n.param a = 1\n", .include);
    try testing.expectEqualStrings(".param a=1\n", inc.text);
}

test "analyses" {
    try expectLowered(
        \\.op
        \\.op at=[1ns, 5ns]
        \\.dc Vin=lin(0, 1.8V, step=10mV) Vdd=[1.6V, 1.8V, 2.0V]
        \\.dc temp=lin(-40C, 125C, step=5C)
        \\.dc Vin=lin(0, 1, n=11)
        \\.ac freq=dec(1Hz, 1GHz, n=20)
        \\.ac freq=[1kHz, 2kHz]
        \\.tran stop=10us step=1ns
        \\.tran stop=2ns step=2ps maxstep=200ps uic
    ,
        \\.op
        \\.op 1n 5n
        \\.dc Vin 0 1.8 10m Vdd poi 3 1.6 1.8 2.0
        \\.dc temp -40 125 5
        \\.dc Vin lin 11 0 1
        \\.ac dec 20 1 1g
        \\.ac poi 2 1k 2k
        \\.tran 1n 10u
        \\.tran 2p 2n 0 200p uic
        \\
    );
}

test "every refusal is a coded row, and the file goes on after it" {
    const Case = struct { []const u8, Code };
    for ([_]Case{
        .{ ".tran stop=1.8V step=1ns", .wrong_unit },
        .{ ".param vdd = 1.8V\n.tran stop=vdd step=1ps", .wrong_unit },
        .{ "C1 (a 0) capacitor 10pH", .wrong_unit },
        .{ ".option foo=1", .unknown_key },
        .{ ".option method=euler", .unknown_word },
        .{ ".option itl1=2.5", .fraction },
        .{ ".tran step=1ns", .missing_key },
        .{ ".tran stop=1ns stop=2ns step=1ps", .repeated_key },
        .{ ".foo", .unknown_directive },
        .{ ".end", .retired },
        .{ ".option reltol=1e-3 sweep monte(3)", .sweep_not_lowered },
        .{ ".param p = v(a)", .reads_circuit },
        .{ ".param p = ternary_fcn(1, 2, 3)", .retired },
        .{ ".model x resistor r=tol(1k, lot=gauss(p))", .no_legacy },
        .{ ".model x mos1 type=q", .unknown_family },
        .{ ".model x mos1 type=n level=2", .retired },
        .{ ".model x bsim4", .missing_key },
        .{ "X1 (a b=c) sub", .mixed_ports },
        .{ "R1 (a b c) resistor 1k", .arity },
        .{ "R1 (p=a n=b x=c) resistor 1k", .unknown_key },
        .{ "R1 (a b) resistor 1k r=2k", .repeated_key },
        .{ "V1 (a 0) vsource sffm(0, 1, fc=1MHz)", .no_filler },
        .{ "V1 (a 0) vsource pulse(0, 1, np=3)", .unknown_key },
        .{ "V1 (a 0) vsource 1 dc=2", .repeated_key },
        .{ ".include \"m.va\"", .hdl_include },
        .{ ".alter {\n}\n.param a = 1", .misplaced },
        .{ ".else {\n}", .misplaced },
        .{ ".dc a=[1] b=[2] c=[3]", .no_legacy },
        .{ ".ac freq=lin(1, 2, step=1)", .unknown_key },
        .{ "data 1, 2", .misplaced },
        .{ "R1 (a b) resistor 1k\nr1 (b c) resistor 2k", .duplicate_instance },
        .{ ".stim pwl drive=v(a) from=0 to=1ns npoints=2", .stim_name },
        .{ "V1 (a 0) vsource pat(1, 0, td=0, tr=1ps, tf=1ps, tsample=1ns)", .missing_key },
    }) |c| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", c[0], "\n.param ok = 1\n" });
        const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .top);
        errdefer std.debug.print("{s}: {any}\n", .{ c[0], got.diags });
        try testing.expectEqual(1, got.diags.len);
        try testing.expectEqual(c[1], got.diags[0].code);
        try testing.expect(std.mem.endsWith(u8, got.text, ".param ok=1\n"));
    }
}

test "a refusal is reported at its line and column" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = ".espice 1\n.param a = 1\n.tran stop=1.8V step=1ns\n";
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .top);
    try testing.expectEqual(1, got.diags.len);
    try testing.expectEqual(.{ 3, 12 }, lang.diag.lineCol(src, got.diags[0].at));
    try testing.expectError(error.ParseError, lang.lower(testing.allocator, arena.allocator(), src, "deck.sp", .top));
}
