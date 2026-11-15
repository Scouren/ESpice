//! Tests of the lowering of `.meas`, `.check`, `.dout`, `.biaschk` and
//! `.stim`. Oracles: per form, the legacy card written by hand from the
//! spec's Legacy entry, checked against the reader (Parse/measure.zig,
//! measure_check.zig, reader_measures.zig `readStim`); the legacy reader
//! as reference implementation (a deck and its hand-written legacy twin
//! read through `Netlist.parse` to equal measures and stims); a code
//! pinned for every refusal.

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const netlist = @import("../Netlist.zig");
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

/// The new deck and its legacy twin read to the same measures and stims.
fn expectTwins(new: []const u8, legacy: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try netlist.parse(a, new);
    const want = try netlist.parse(a, legacy);
    try testing.expect(want.deck.measures.len > 0);
    try testing.expectEqualDeep(want.deck.measures, got.deck.measures);
    try testing.expectEqualDeep(want.deck.stims, got.deck.stims);
}

test "the spec's measurements: one call, a cross difference, arithmetic" {
    try expectLowered(
        \\.param vdd = 1.8V
        \\.meas tran tphl  = cross(v(out), vdd/2, fall=1) - cross(v(in), vdd/2, rise=1)
        \\.meas tran vmax  = max(v(out), from=1ns, to=5ns)
        \\.meas tran vmid  = find(v(out), at=2ns)
        \\.meas ac   bw    = cross(vdb(out), -3, fall=1)
        \\.meas tran ratio = vmax/1.8
        \\.meas tran slow  = cross(v(out), 0.9V, rise=last) goal=1ns weight=2
    ,
        \\.param vdd=1.8
        \\.meas tran tphl trig v(in) val='vdd/2' rise=1 targ v(out) val='vdd/2' fall=1
        \\.meas tran vmax max v(out) from=1n to=5n
        \\.meas tran vmid find v(out) at=2n
        \\.meas ac bw when vdb(out)=-3 fall=1
        \\.meas tran ratio param='vmax/1.8'
        \\.meas tran slow when v(out)=0.9 rise=last goal=1n weight=2
        \\
    );
}

test "every measurement function and key reaches its legacy card" {
    try expectLowered(
        \\.meas tran t50 = cross(v(a), 0.5, rise=1, from=1ns)
        \\.meas tran d1  = cross(v(b), 1, rise=2, td=trig) - at(5ns)
        \\.meas tran f1  = find(v(a), when=cross(v(b), v(c), cross=last))
        \\.meas tran s1  = deriv(v(out), at=t50)
        \\.meas tran w   = cross(v(a), sqrt(vdd), rise=1)
        \\.meas tran p   = avg(v(a)*i(Vdd), from=t50)
        \\.meas tran e   = err1(v(a), v(b), ymin=1u, ymax=5) minval=1m
        \\.meas fft  h   = thd(v(out), nbharm=5, minfreq=1kHz, maxfreq=10kHz, binsiz=2)
        \\.meas tran em  = em_avg(i(R1), from=1ns, to=2ns)
        \\.meas tran j   = jitter(v(clk), 0.9V, rise=1, td=10ns)
        \\.meas lstb pm  = phase_margin()
        \\.meas lstb f0  = cross(lstb(db), 0)
        \\.meas dcmatch s = find(total_3sigma)
        \\.meas ptdnoise n = find(ptdnoise_density, at=1kHz)
        \\.meas tran_cont c = cross(v(a), 1, fall=2)
        \\.meas tran soa = soa_count()
        \\.meas tran sq  = t50**2 + (-2)**3
        \\.meas tran g   = find(v(out), at=2ns) goal=1V goal_bound=above minval=0.5
        \\.meas tran m2  = max(a, b)
    ,
        \\.meas tran t50 when v(a)=0.5 rise=1 from=1n
        \\.meas tran d1 trig at=5n targ v(b) val=1 rise=2 td=trig
        \\.meas tran f1 find v(a) when v(b)=v(c) cross=last
        \\.meas tran s1 deriv v(out) at=t50
        \\.meas tran w when v(a)=par('sqrt(vdd)') rise=1
        \\.meas tran p avg par('v(a)*i(Vdd)') from=t50
        \\.meas tran e err1 v(a) v(b) ymin=1u ymax=5 minval=1m
        \\.meas fft h thd v(out) nbharm=5 minfreq=1k maxfreq=10k binsiz=2
        \\.meas tran em em_avg i(R1) from=1n to=2n
        \\.meas tran j jitter trig v(clk) val=0.9 rise=1 td=10n
        \\.meas lstb pm find phase_margin
        \\.meas lstb f0 when lstb(db)=0
        \\.meas dcmatch s find total_3sigma
        \\.meas ptdnoise n find ptdnoise_density at=1k
        \\.meas tran_cont c when v(a)=1 fall=2
        \\.meas tran soa param='soa_count()'
        \\.meas tran sq param='(t50**2)+(pow((-2),3))'
        \\.meas tran g find v(out) at=2n goal=>1 minval=0.5
        \\.meas tran m2 param='max(a,b)'
        \\
    );
}

test "checks: each form's keys as the reader's group, in its order" {
    try expectLowered(
        \\.check global_level hi=1.8V lo=0 hi_th=80% lo_th=20%
        \\.check rise min=10ps max=1ns nodes=[a, b]
        \\.check setup ref=clk ref_edge=rise limit=2ns edge=fall nodes=[d, v(e)]
        \\.check edge ref=clk ref_edge=rise min=1ns max=2ns edge=rise nodes=[q] hi=1.8V lo=0 hi_th=1.5V lo_th=0.3V
        \\.check irdrop level=-0.1V duration=1ns nodes=[vdd]
        \\.dout nodes=[b, c, 5] vth=0.5V states=[(1ns, 1, x, 0), (2ns, 0, 1, 1)]
        \\.dout nodes=[a] vlo=0.3V vhi=1.5V states=[(1ns, 1)]
        \\.biaschk v(a) - v(b) max=1V min=-1V tstart=1ns tstop=3ns
        \\.stim pwl vin=v(a) v(b, c) iout=(i(R1), x, 0) from=0 to=1ns npoints=11
        \\.stim data table=tab file="out.dat" v(a) vx=v(a)*2 times=[0, 1ns, 2ns] indepout
    ,
        \\.check global_level (1.8 0 80% 20%)
        \\.check rise (10p 1n) a b
        \\.check setup (clk rise 2n fall) d v(e)
        \\.check edge (clk rise 1n 2n rise) q (1.8 0 1.5 0.3)
        \\.check irdrop (-0.1 1n) vdd
        \\.dout b c v(5) 0.5 (1n 1 x 0 2n 0 1 1)
        \\.dout a 0.3 1.5 (1n 1)
        \\.biaschk 'v(a)-v(b)' max=1 min=-1 tstart=1n tstop=3n
        \\.stim tran pwl vin=v(a) v(b,c) iout=i(R1) node1=x node2=0 from=0 to=1n npoints=11
        \\.stim tran data filename="out.dat" tab v(a) vx=par('v(a)*2') indepvar=(0 1n 2n) indepout
        \\
    );
}

test "measurements read as their hand-written legacy twins" {
    try expectTwins(
        \\.espice 1
        \\.param vdd = 1.8V
        \\.meas tran tphl = cross(v(out), vdd/2, fall=1) - cross(v(in), vdd/2, rise=1)
        \\.meas tran t50 = cross(v(a), 0.5, rise=1, from=1ns)
        \\.meas tran d1 = cross(v(b), 1, rise=2, td=trig) - at(5ns)
        \\.meas tran f1 = find(v(a), when=cross(v(b), v(c), cross=last))
        \\.meas tran s1 = deriv(v(out), at=t50)
        \\.meas tran w = cross(v(a), vdd/2, rise=1)
        \\.meas tran p = avg(v(a)*i(Vdd), from=t50)
        \\.meas tran e = err1(v(a), v(b), ymin=1u, ymax=5) minval=1m
        \\.meas fft h = thd(v(out), nbharm=5, maxfreq=10kHz)
        \\.meas tran em = em_avg(i(R1), from=1ns, to=2ns)
        \\.meas tran j = jitter(v(clk), 0.9V, rise=1, td=10ns)
        \\.meas lstb pm = phase_margin()
        \\.meas lstb f0 = cross(lstb(db), 0)
        \\.meas dcmatch s = find(total_3sigma)
        \\.meas tran_cont c = cross(v(a), 1, fall=2)
        \\.meas tran r = 2*t50 + vdd
        \\.meas tran g = find(v(out), at=2ns) goal=1V goal_bound=above minval=0.5
    ,
        \\twin
        \\.param vdd=1.8
        \\.meas tran tphl TRIG v(in) VAL='vdd/2' RISE=1 TARG v(out) VAL='vdd/2' FALL=1
        \\.meas tran t50 WHEN v(a)=0.5 RISE=1 FROM=1n
        \\.meas tran d1 TRIG AT=5n TARG v(b) VAL=1 RISE=2 TD=TRIG
        \\.meas tran f1 FIND v(a) WHEN v(b)=v(c) LAST
        \\.meas tran s1 DERIV v(out) AT=t50
        \\.meas tran w WHEN v(a)={vdd/2} RISE=1
        \\.meas tran p AVG par('v(a)*i(Vdd)') FROM=t50
        \\.meas tran e ERR1 v(a) v(b) IGNOR=1u YMAX=5 MINVAL=1m
        \\.meas fft h THD v(out) NBHARM=5 MAXFREQ=10k
        \\.meas tran em EM_AVG i(R1) FROM=1n TO=2n
        \\.meas tran j JITTER TRIG v(clk) VAL=0.9 RISE=1 TD=10n
        \\.meas lstb pm phase_margin
        \\.meas lstb f0 WHEN lstb(db)=0
        \\.meas dcmatch s FIND total_3sigma
        \\.meas tran_cont c WHEN v(a)=1 FALL=2
        \\.meas tran r PARAM='2*t50+vdd'
        \\.meas tran g FIND v(out) AT=2n GOAL > 1 MINVAL=0.5
        \\
    );
}

test "checks, .dout, .biaschk and .stim read as their hand-written legacy twins" {
    try expectTwins(
        \\.espice 1
        \\.check global_level hi=1.8V lo=0 hi_th=80% lo_th=20%
        \\.check rise min=10ps max=1ns nodes=[a, b]
        \\.check setup ref=clk ref_edge=rise limit=2ns edge=fall nodes=[d]
        \\.check edge ref=clk ref_edge=rise min=1ns max=2ns edge=rise nodes=[q] hi=1.8V lo=0 hi_th=1.5V lo_th=0.3V
        \\.check irdrop level=-0.1V duration=1ns nodes=[vdd]
        \\.dout nodes=[b, c] vth=0.5V states=[(1ns, 1, x), (2ns, 0, 1)]
        \\.biaschk v(a) - v(b) max=1V tstart=1ns
        \\.stim pwl vin=v(a) v(b, c) iout=(i(R1), x, 0) from=0 to=1ns npoints=11
        \\.stim data table=tab v(a) vx=v(a)*2 times=[0, 1ns, 2ns] indepout
    ,
        \\twin
        \\.check global_level (1.8 0 80% 20%)
        \\.check rise (10p 1n) a b
        \\.check setup (clk RISE 2n FALL) d
        \\.check edge (clk RISE 1n 2n RISE) q (1.8 0 1.5 0.3)
        \\.check irdrop (-0.1 1n) vdd
        \\.dout b c 0.5 (1n 1 x 2n 0 1)
        \\.biaschk 'v(a)-v(b)' limit=1 tstart=1n
        \\.stim pwl vin=v(a) v(b,c) iout=i(R1) node1=x node2=0 from=0 to=1n npoints=11
        \\.stim tran data tab v(a) vx=par('v(a)*2') indepvar=(0 1n 2n) indepout
        \\
    );
}

test "every measurement and check refusal is a coded row, and the file goes on" {
    const Case = struct { []const u8, Code };
    for ([_]Case{
        .{ ".meas tran a = 1 + max(v(a))", .meas_nested },
        .{ ".meas tran a = cross(v(a), 1, rise=1) - 1ns", .meas_nested },
        .{ ".meas tran a = thd(v(a))", .meas_function },
        .{ ".meas tran a = find(v(a))", .meas_function },
        .{ ".meas tran a = find(v(a), at=v(b))", .meas_signal },
        .{ ".meas tran a = 1 + v(a)", .meas_signal },
        .{ ".meas tran a = cross(v(a), 1) - cross(v(b), 1, rise=1)", .missing_key },
        .{ ".meas tran a = deriv(v(a))", .missing_key },
        .{ ".meas tran a = max(v(a)) goal_bound=above", .missing_key },
        .{ ".meas tran a = cross(v(a), 1, rise=1, fall=1)", .repeated_key },
        .{ ".meas tran a = find(v(a), at=1, when=cross(v(b), 1))", .repeated_key },
        .{ ".meas tran a = cross(v(a), 1, rise=1, td=trig)", .misplaced },
        .{ ".meas tran a = at(1ns)", .misplaced },
        .{ ".meas tran a = avg(v(a), at=1)", .unknown_key },
        .{ ".meas tran a = err(v(a)*2, v(b))", .no_legacy },
        .{ ".meas tran a = avg(v(a) % 2)", .no_legacy },
        .{ ".meas lstb a = phase_margin() goal=1", .no_legacy },
        .{ ".meas tran a = cross(v(a))", .arity },
        .{ ".meas tran", .arity },
        .{ ".meas foo a = 1", .unknown_word },
        .{ ".check rise min=1ns nodes=[a]", .missing_key },
        .{ ".check rise min=1ns max=2ns nodes=[a] hi=1V", .missing_key },
        .{ ".check irdrop level=1V duration=1ns nodes=[a] ref=b", .unknown_key },
        .{ ".check setup ref=clk ref_edge=up limit=1ns edge=rise nodes=[a]", .unknown_word },
        .{ ".dout nodes=[a, b] states=[(1ns, 1)]", .arity },
        .{ ".dout nodes=[a] states=[(1ns, 2)]", .unknown_word },
        .{ ".dout nodes=[a] vth=1 vlo=0 vhi=2 states=[(1ns, 1)]", .repeated_key },
        .{ ".stim data v(a)", .missing_key },
        .{ ".stim pwl v(a)*2", .missing_key },
        .{ ".stim pwl v(a) from=t0", .no_legacy },
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
