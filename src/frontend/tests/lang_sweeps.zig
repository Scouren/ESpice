//! Tests of the sweeps and runs: the `sweep` clause, `.step`, `.data`,
//! `.wcd` and `optimize(...)`.
//! Oracles: the legacy card written by hand from each Legacy entry in
//! docs/using/language.md "Sweeps and runs", checked against
//! src/frontend/Netlist/reader_sweeps.zig and reader_measures.zig
//! `readWcd`; the legacy reader, which must read every lowered deck
//! (`Netlist.parse`, with hand-written legacy cards appended where the
//! card needs a circuit or a `.meas`); the reader as reference
//! implementation for decks without instances. Codes pinned for every
//! refusal.

const std = @import("std");
const testing = std.testing;
const netlist = @import("../Netlist.zig");
const t = @import("lang_analyses.zig");

test "the sweep clause on an analysis is its SWEEP tail, which the reader reads" {
    try t.expectCards(
        \\.tran stop=10us step=10ns sweep data(corners)
        \\.tran stop=10us step=10ns sweep monte(200)
        \\.tran stop=10us step=10ns sweep monte(4, first=5)
        \\.ac freq=dec(1Hz, 1kHz, n=1) sweep monte(runs=[10, (20, 30)])
        \\.dc sweep data(corners)
        \\.dc sweep monte(5)
        \\.noise out=v(o) freq=dec(1Hz, 1kHz, n=1) sweep monte(3)
        \\.op at=[1ns] sweep monte(3)
    ,
        \\.tran 10n 10u sweep data=corners
        \\.tran 10n 10u sweep monte=200
        \\.tran 10n 10u sweep monte=4 firstrun=5
        \\.ac dec 1 1 1k sweep monte=list(10 20:30)
        \\.dc sweep data=corners
        \\.dc sweep monte=5
        \\.noise v(o) dec 1 1 1k sweep monte=3
        \\.op 1n sweep monte=3
        \\
    , ".param n=4 k=3\n.data corners n\n1\n2\n.enddata\n");
}

test "the sweep clause reads as the legacy card's tail: trials, scales and the data table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lowered = try netlist.lang.lower(testing.allocator, a, ".espice 1\n.tran stop=10us step=10ns sweep monte(runs=[2, (4, 6)])\n.dc Vin=[0, 1] sweep monte(10, first=2, sigma_scale=[2, 3], fail=m > 5)\n", "deck.sp", .top);
    // FAIL names a `.meas` of its analysis, which another package lowers.
    const nl = try netlist.parse(a, try std.mem.concat(a, u8, &.{ lowered, ".meas dc m find v(a) at=1\n" }));
    try testing.expectEqualSlices(u32, &.{ 2, 4, 5, 6 }, nl.deck.analyses[0].sweep.monte.list);
    const m = nl.deck.analyses[1].sweep.monte;
    try testing.expectEqual(10, m.n);
    try testing.expectEqual(2, m.first);
    try testing.expectEqualSlices(f64, &.{ 2, 3 }, m.scales);
    try testing.expectEqualStrings("m > 5", m.fail.text);
    try testing.expect(std.mem.endsWith(u8, lowered, ".dc Vin poi 2 0 1 sweep monte=10 firstrun=2 sigma_scale=2,3 fail='m>5'\n"));
}

test ".step, .data and .wcd as their legacy cards, which the reader reads" {
    testing.allocator.free(try t.expectDeck(
        \\.step rval=[1k, 2k, 5k]
        \\.step temp=lin(-40C, 125C, step=55C)
        \\.step vdd=dec(1V, 100V, n=5)
        \\.step Vin=oct(1, 8, n=2)
        \\.data corners (rval, cval) {
        \\    1k, 1pF
        \\    2k, 2pF
        \\}
        \\.data one (x) {
        \\    k*2
        \\}
        \\.wcd (gain >= 60) (pm < 45) maxiter=20 tol=0.01 top=3
    ,
        \\.step rval list 1k 2k 5k
        \\.step temp -40 125 55
        \\.step dec vdd 1 100 5
        \\.step oct Vin 1 8 2
        \\.data corners rval cval
        \\1k 1p
        \\2k 2p
        \\.enddata
        \\.data one x
        \\'k*2'
        \\.enddata
        \\.wcd gain '>=60' pm '<45' maxiter=20 tol=0.01 top=3
        \\
    ,
        \\.param rval=1k cval=1p vdd=1 x=0 k=1
        \\v1 a 0 1
        \\r1 a 0 1k
        \\.dc v1 0 1 1
        \\.meas dc gain find v(a) at=1
        \\.meas dc pm find v(a) at=1
        \\
    ));
}

test "an optimize() parameter is the legacy opt(...) value its SWEEP OPTIMIZE reads" {
    testing.allocator.free(try t.expectDeck(
        \\.param wn = optimize(opt1, 1um, lo=0.5um, hi=5um)
        \\.param wl = optimize(opt1, 1um, lo=0.5um, hi=5um, step=1nm, grid=5nm)
        \\.param wg = optimize(opt1, 1um, lo=0.5um, hi=5um, grid=5nm)
        \\.dc v1=lin(0, 5, step=1) sweep optimize(opt1, results=[vout, v2], model=optmod)
    ,
        \\.param wn=opt1(1u,0.5u,5u)
        \\.param wl=opt1(1u,0.5u,5u,1n,5n)
        \\.param wg=opt1(1u,0.5u,5u,0,5n)
        \\.dc v1 0 5 1 sweep optimize=opt1 results=vout,v2 model=optmod
        \\
    , ""));
    // The reader reads the declaration's numbers through the SWEEP card.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try netlist.lang.lower(testing.allocator, a, ".espice 1\n.param rx = optimize(opt1, 5k, lo=100, hi=10k, grid=10)\n.dc v1=lin(0, 5, step=1) sweep optimize(opt1, results=[vout], model=optmod)\n", "deck.sp", .top);
    const nl = try netlist.parse(a, try std.mem.concat(a, u8, &.{ got, "v1 in 0 5\nr1 in out 1k\nr2 out 0 rx\n.model optmod opt\n.meas dc vout find v(out) at=5 goal=2\n" }));
    const opt = nl.deck.optimize.?;
    try testing.expectEqualSlices(f64, &.{100}, opt.lo);
    try testing.expectEqualSlices(f64, &.{10e3}, opt.hi);
    try testing.expectEqualSlices(f64, &.{0}, opt.dels);
    try testing.expectEqualSlices(f64, &.{10}, opt.grid);
}

test "sweep refusals, each with its code" {
    for ([_]struct { []const u8, @import("../lang.zig").diag.Code }{
        .{ ".tran stop=1us step=1ns sweep data()", .arity },
        .{ ".tran stop=1us step=1ns sweep foo(3)", .wrong_kind },
        .{ ".tran stop=1us step=1ns sweep monte", .wrong_kind },
        .{ ".tran stop=1us step=1ns sweep monte(2.5)", .fraction },
        .{ ".tran stop=1us step=1ns sweep monte(3, seed=2)", .unknown_key },
        .{ ".tran stop=1us step=1ns sweep monte(3, runs=[1])", .no_legacy },
        .{ ".tran stop=1us step=1ns sweep monte(runs=[x])", .wrong_kind },
        .{ ".tran stop=1us step=1ns sweep monte(3, sigma_scale=[2, 3])", .missing_key },
        .{ ".tran stop=1us step=1ns sweep monte(3, fail=m > 1)", .missing_key },
        .{ ".noise out=v(o) freq=[1Hz] sweep monte(3, sigma_scale=[2], fail=m > 1)", .no_legacy },
        .{ ".dc sweep monte(3, sigma_scale=[2], fail=m > 1)", .no_legacy },
        .{ ".dc sweep optimize(o, results=[m], model=x)", .arity },
        .{ ".tran stop=1us step=1ns sweep optimize(o, results=[m])", .missing_key },
        .{ ".step", .arity },
        .{ ".step a=[1] b=[2]", .no_legacy },
        .{ ".step a=lin(1, 2, n=3)", .no_legacy },
        .{ ".step a=dec(1, 2, step=3)", .unknown_key },
        .{ ".step a=1", .wrong_kind },
        .{ ".data d (a, b) {\n    1\n}", .arity },
        .{ ".data d (a) {\n    .param x = 1\n}", .misplaced },
        .{ ".data d a {\n    1\n}", .wrong_kind },
        .{ ".wcd gain >= 60", .wrong_kind },
        .{ ".wcd (gain == 60)", .wrong_kind },
        .{ ".wcd (gain >= 60) maxiter=2.5", .fraction },
        .{ ".param w = optimize(o, 1, lo=0)", .missing_key },
        .{ ".param w = optimize(o, lo=0, hi=1)", .arity },
        .{ ".param w = optimize(o, 1, lo=0, hi=2, bad=1)", .unknown_key },
    }) |c| try t.expectRefused(c[0], c[1]);
}

test "a deck of sweeps without instances reads as its legacy twin" {
    try t.expectTwins(
        \\.espice 1
        \\.param rval = 1k  cval = 1pF
        \\.step rval=[1k, 2k]
        \\.step temp=lin(-40C, 125C, step=55C)
        \\.data corners (rval, cval) {
        \\    1k, 1pF
        \\    2k, 2pF
        \\}
        \\.tran stop=10us step=10ns sweep data(corners)
        \\.ac freq=dec(1Hz, 1kHz, n=1) sweep monte(20, first=3)
    ,
        \\
        \\.param rval=1k cval=1p
        \\.step rval list 1k 2k
        \\.step temp -40 125 55
        \\.data corners rval cval
        \\1k 1p
        \\2k 2p
        \\.enddata
        \\.tran 10n 10u sweep data=corners
        \\.ac dec 1 1 1k sweep monte=20 firstrun=3
        \\
    );
}

test "sweep target=range on an analysis is the legacy per-analysis SWEEP tail, which the reader reads" {
    // Oracle: the legacy twin's cards written by hand (reference.md,
    // `SWEEP param start stop step`, `lin|dec|oct N start stop`, `poi N`).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const new = try netlist.parse(a,
        \\.espice 1
        \\.param rval = 1k
        \\R1 (a 0) resistor rval
        \\V1 (a 0) vsource dc=1 ac=1
        \\.ac freq=dec(1Hz, 1kHz, n=2) sweep rval=lin(1k, 3k, step=1k)
        \\.ac freq=dec(1Hz, 1kHz, n=2) sweep rval=dec(1k, 100k, n=2)
        \\.op sweep rval=[1k, 2k, 5k]
        \\.op sweep temp=lin(0, 100C, n=3)
    );
    const legacy = try netlist.parse(a, "t\n.param rval=1k\nR1 a 0 {rval}\nV1 a 0 DC 1 AC 1\n.ac dec 2 1 1k sweep rval 1k 3k 1k\n.ac dec 2 1 1k sweep rval dec 2 1k 100k\n.op sweep rval poi 3 1k 2k 5k\n.op sweep temp lin 3 0 100\n");
    try testing.expectEqual(4, new.deck.analyses.len);
    for (legacy.deck.analyses, new.deck.analyses) |w, g| {
        try testing.expect(w.sweep == .step);
        try testing.expectEqualDeep(w.sweep, g.sweep);
    }
}
