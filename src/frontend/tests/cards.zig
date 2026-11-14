//! Card-level tests of `netlist.parse`: one directive or element form per
//! test, each expected value worked by hand from the card's manual
//! semantics (cited per test), with the boundary and refusal of each form.
const std = @import("std");
const netlist = @import("../Netlist.zig");
const Netlist = netlist.Netlist;

fn device(nl: Netlist, name: []const u8) !Netlist.View {
    for (0..nl.deviceCount()) |e| {
        const d = nl.device(.from(e));
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return error.MissingDevice;
}

fn kvNum(kv: []const netlist.Kv, key: []const u8) !f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
        .num => |n| n,
        else => error.NotANumber, // else: any other value is no number
    };
    return error.MissingKey;
}

/// Asserts each deck fails with `err`.
fn expectRefused(err: anyerror, decks: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (decks) |src| {
        if (netlist.parse(arena.allocator(), src)) |_| {
            std.debug.print("accepted: {s}\n", .{src});
            return error.TestUnexpectedResult;
        } else |got| if (got != err) {
            std.debug.print("{s} (want {s}): {s}\n", .{ @errorName(got), @errorName(err), src });
            return error.TestUnexpectedResult;
        }
    }
}

test ".four naming several outputs is one card per output, numbers kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a b 1\nr2 b 0 1\n.four 1k v(a) v(b) 3\n.four 2k v(a)\n");
    const as = nl.deck.analyses;
    try std.testing.expectEqual(@as(usize, 3), as.len);
    for (as[0..2], [_][]const u8{ "a", "b" }) |a, net| {
        try std.testing.expect(a.kind == .four and a.split);
        try std.testing.expectEqual(@as(usize, 3), a.args.len);
        try std.testing.expectEqual(@as(f64, 1000), a.args[0].num);
        try std.testing.expectEqualStrings(net, a.args[1].group.args()[0].name);
        try std.testing.expectEqual(@as(f64, 3), a.args[2].num);
    }
    // `pos` is the output net, resolved per card.
    try std.testing.expect(as[0].pos != as[1].pos and as[0].pos != netlist.none);
    try std.testing.expect(!as[2].split);
}

test "MONTE=list expands its a:b ranges; counts are positive integers [CR .DC]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try netlist.parse(a, "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(2 4:6)\n");
    const m = nl.deck.analyses[0].sweep.monte;
    try std.testing.expectEqual(@as(u32, 4), m.n);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 5, 6 }, m.list);
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.tran 1n 10n sweep monte=3 firstrun=2\n");
    try std.testing.expectEqual(netlist.Monte{ .n = 3, .first = 2 }, nl.deck.analyses[0].sweep.monte);
    try expectRefused(error.ParseError, &.{
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(0)\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(5:3)\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(1.5)\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=0\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=2.5\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=3 firstrun\n",
        // Each range is small; together they name more trials than any run.
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(1:600000 1:600000)\n",
    });
    // A million trials in all is the limit.
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(1:524288 1:524288)\n");
    try std.testing.expectEqual(@as(u32, 1 << 20), nl.deck.analyses[0].sweep.monte.n);
}

test ".step grids: dec and oct per decade or octave, lin by increment; poi refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const f64 }{
        .{ ".step dec param p 1 100 1", &.{ 1, 10, 100 } },
        .{ ".step oct param p 1 4 1", &.{ 1, 2, 4 } },
        .{ ".step param p 1 2 0.5", &.{ 1, 1.5, 2 } },
        .{ ".step param p list 3 1", &.{ 3, 1 } },
    };
    for (cases) |c| {
        const src = try a.print("t\n.param p=1\nr1 a 0 {{p}}\n{s}\n", .{c[0]});
        const nl = try netlist.parse(a, src);
        const values = nl.deck.steps[0].values;
        try std.testing.expectEqual(c[1].len, values.len);
        for (c[1], values) |want, got| try std.testing.expectApproxEqRel(want, got, 1e-12);
    }
    try expectRefused(error.ParseError, &.{
        "t\n.param p=1\n.step poi param p 1 2\n",
        "t\n.param p=1\n.step param p 1 2\n",
        "t\n.param p=1\n.step param p 1 2 0\n",
    });
}

test "HSPICE sweep tails: lin by count, poi by list, .dc over a bare .param (#94)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try netlist.parse(a, "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p lin 3 1 2\n");
    try std.testing.expectEqualSlices(f64, &.{ 1, 1.5, 2 }, nl.deck.analyses[0].sweep.step.values);
    nl = try netlist.parse(a, "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p poi 2 1 5\n");
    try std.testing.expectEqualSlices(f64, &.{ 1, 5 }, nl.deck.analyses[0].sweep.step.values);
    nl = try netlist.parse(a, "t\n.param p=1\nr1 a 0 p\n.dc p 1 3 1\n");
    const dc = nl.deck.analyses[0];
    try std.testing.expectEqual(@as(usize, 0), dc.args.len);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, dc.sweep.step.values);
    try std.testing.expectEqualStrings("p", nl.live.names[dc.sweep.step.target.param]);
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.data d\nx\n1\n.enddata\n.tran 1n 10n sweep data=d\n");
    try std.testing.expectEqualStrings("d", nl.deck.analyses[0].sweep.data);
    try expectRefused(error.ParseError, &.{
        "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p poi 3 1 5\n",
        "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p lin 0 1 2\n",
        "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p bogus 3 1 2\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep data=d extra\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep\n",
    });
}

test "HSPICE .dc: a bare MONTE= or DATA= is the whole sweep; after a swept source it needs SWEEP [CR .DC]" {
    // The manual's forms: `.DC MONTE=val`, `.DC DATA=name` and
    // `.DC var start stop incr SWEEP MONTE=val`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try netlist.parse(a, "t\nv1 a 0 1\nr1 a 0 1\n.dc monte=5\n");
    try std.testing.expectEqual(@as(usize, 0), nl.deck.analyses[0].args.len);
    try std.testing.expectEqual(@as(u32, 5), nl.deck.analyses[0].sweep.monte.n);
    nl = try netlist.parse(a, "t\nv1 a 0 1\nr1 a 0 1\n.dc v1 1 1 1 sweep monte=5\n");
    try std.testing.expectEqual(@as(usize, 4), nl.deck.analyses[0].args.len);
    try std.testing.expectEqual(@as(u32, 5), nl.deck.analyses[0].sweep.monte.n);
    try expectRefused(error.UnsupportedCard, &.{
        "t\nv1 a 0 1\nr1 a 0 1\n.dc v1 1 1 1 monte=5\n",
        "t\nv1 a 0 1\nr1 a 0 1\n.data d\nx\n1\n.enddata\n.dc v1 0 1 0.1 data=d\n",
    });
}

test ".mosra reads its keys; SimMode 1 and unknown keys are refused [SA Ch.29]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a 0 1\n.mosra reltotaltime=10 relstep=1 simmode=0 relmode=2 degf=0.1\n");
    const m = nl.deck.mosra.?;
    try std.testing.expectEqual(@as(f64, 10), m.rel_total_time);
    try std.testing.expectEqual(@as(f64, 1), m.rel_step);
    try std.testing.expect(!m.aged_runs);
    try std.testing.expectEqual(@as(u2, 2), m.rel_mode);
    try std.testing.expectEqual(@as(?f64, 0.1), m.deg_f);
    try expectRefused(error.UnsupportedCard, &.{
        "t\nr1 a 0 1\n.mosra reltotaltime=10 simmode=1\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=10 dec=1\n",
    });
    try expectRefused(error.ParseError, &.{
        "t\nr1 a 0 1\n.mosra reltotaltime=10 relmode=3\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=0\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=10 agingstart=2 agingstop=1\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=10 relstep\n",
    });
}

test ".sample: FS positive, MAXFLD at least 1, BETA in [0, 1] [CR .SAMPLE]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a 0 1\n.sample fs=1g maxfld=4 beta=0.5 tol=1m\n");
    try std.testing.expectEqual(@import("core").query.NoiseSample{ .fs = 1e9, .max_fold = 4, .beta = 0.5 }, nl.deck.sample.?);
    try expectRefused(error.ParseError, &.{
        "t\nr1 a 0 1\n.sample fs=0\n",
        "t\nr1 a 0 1\n.sample fs=1g beta=2\n",
        "t\nr1 a 0 1\n.sample fs=1g maxfld=0.5\n",
        "t\nr1 a 0 1\n.sample fs=1g tol\n",
        "t\nr1 a 0 1\n.sample fs=1g bogus=1\n",
    });
}

// Both sides of the `.save` keyword rule: a `type=`, `file=`, `level=` or
// `time=` key makes the card ESPice's operating-point save (HSPICE's
// [CR .SAVE] spelling); without one it is ngspice's vector list (manual
// 11.6.1), which never carries a `key=value` field.
test ".save with type=, file=, level= or time= is the operating-point save; without, ngspice's output list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try netlist.parse(a, "t\nr1 a 0 1\n.save type=ic level=top time=1n file='Op.ic'\n");
    const s = nl.deck.save_op.?;
    try std.testing.expect(s.ic and s.top_only);
    try std.testing.expectEqual(@as(f64, 1e-9), s.time);
    try std.testing.expectEqualStrings("Op.ic", s.file.?); // the path keeps its case
    try std.testing.expectEqual(@as(usize, 0), nl.deck.saves.len);
    for ([_][]const u8{ "type=nodeset", "file=op.ic", "level=all", "time=0" }) |key| {
        const deck = try std.fmt.allocPrint(a, "t\nr1 a 0 1\n.save {s}\n", .{key});
        nl = try netlist.parse(a, deck);
        try std.testing.expect(nl.deck.save_op != null);
        try std.testing.expectEqual(@as(usize, 0), nl.deck.saves.len);
    }
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.save type=ic\n.save level=none\n");
    try std.testing.expectEqual(@as(?@import("core").SaveOp, null), nl.deck.save_op);
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.save v(A) i(R1) x\n");
    try std.testing.expectEqual(@as(?@import("core").SaveOp, null), nl.deck.save_op);
    try std.testing.expectEqual(@as(usize, 3), nl.deck.saves.len);
    try std.testing.expectEqualStrings("v(a)", nl.deck.saves[0]);
    try std.testing.expectEqualStrings("i(r1)", nl.deck.saves[1]);
    try std.testing.expectEqualStrings("v(x)", nl.deck.saves[2]);
    // A node named like a key, with no `=`, is a vector.
    nl = try netlist.parse(a, "t\nr1 type 0 1\n.save type\n");
    try std.testing.expectEqual(@as(?@import("core").SaveOp, null), nl.deck.save_op);
    try std.testing.expectEqualStrings("v(type)", nl.deck.saves[0]);
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.save v(a)\n.save all\n");
    try std.testing.expectEqual(@as(usize, 0), nl.deck.saves.len);
    try expectRefused(error.ParseError, &.{
        "t\nr1 a 0 1\n.save time=-1\n",
        "t\nr1 a 0 1\n.save type=foo\n",
        "t\nr1 a 0 1\n.save level=some\n",
        "t\nr1 a 0 1\n.save type=ic bogus=1\n",
    });
}

test "ngspice .save and .probe save what ngspice saves; an item they cannot read refuses the card" {
    // Oracle: ngspice 44.2 `-n -b -r` on each form, the raw file's vectors
    // (manual 11.6.1): `.save in vcc#branch` saves v(in) and i(vcc),
    // `v(a,b)` both nodes, `vdb(c)` v(c), `allv` everything, and
    // `v(b)/10` v(b). `.probe v(n)` adds `.save v(n)` beside a deck's
    // `.save`, and an item led by no v, i or p is skipped (inpc_probe.c:
    // 66-95, 118-128, 375-378). Before, `.save` dropped bare names,
    // x#branch, two-node and vdb groups, and `.probe` was dropped whole.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try netlist.parse(a, "t\nvcc in 0 1\nr1 in b 1\nr2 b c 1\n.save in vcc#branch v(a,b) vdb(c) 10 v(b)/10\n.op\n");
    const want = [_][]const u8{ "v(in)", "i(vcc)", "v(a)", "v(b)", "v(c)", "v(10)", "v(b)" };
    try std.testing.expectEqual(want.len, nl.deck.saves.len);
    for (want, nl.deck.saves) |w, got| try std.testing.expectEqualStrings(w, got);
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.save v(a)\n.save allv\n");
    try std.testing.expectEqual(@as(usize, 0), nl.deck.saves.len);
    nl = try netlist.parse(a, "t\nr1 a b 1\nr2 b 0 1\n.save v(b)\n.probe v(a) foo(x)\n.op\n");
    try std.testing.expectEqual(@as(usize, 2), nl.deck.saves.len);
    try std.testing.expectEqualStrings("v(b)", nl.deck.saves[0]);
    try std.testing.expectEqualStrings("v(a)", nl.deck.saves[1]);
    // With no `.save`, every output is written already.
    nl = try netlist.parse(a, "t\nr1 a 0 1\n.probe v(a)\n.op\n");
    try std.testing.expectEqual(@as(usize, 0), nl.deck.saves.len);
    try expectRefused(error.UnsupportedCard, &.{
        "t\nr1 a 0 1\n.save alli\n.op\n",
        "t\nr1 a 0 1\n.save vi(a)\n.op\n",
        "t\nr1 a 0 1\n.save 1.5\n.op\n",
        "t\nr1 a 0 1\n.probe i(r1)\n.op\n",
        "t\nr1 a 0 1\n.probe v(a) vd(r1)\n.op\n",
        "t\nr1 a 0 1\n.probe p(r1)\n.op\n",
        "t\nr1 a 0 1\n.probe alli\n.op\n",
        "t\nr1 a 0 1\n.probe\n.op\n",
    });
}

test ".meas PARAM= folds each part that reads no result; an unreadable card refuses the deck, one ngspice skips is skipped" {
    // ngspice evaluates PARAM= with numparam over .param, .func and the
    // results so far (measure.c:407-498), and a par() as a B source with
    // `time` (manual 11.6); it skips an incomplete card and one of an
    // analysis it does not measure (measure.c:286-311). Oracle: each
    // folded value by hand, 2*sqrt(2*3*4) = 9.797958971132712 and
    // icap(1,1,1,1) = 2, and the postfix of each kept part.
    const MeasureOp = @import("core").MeasureOp;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(),
        \\t
        \\.func icap(a,b,c,d) '2*a*sqrt(b*c*d)'
        \\i1 0 p dc 10u
        \\c1 p 0 1n
        \\.tran 1u 1m
        \\.meas tran t1 when v(p)=0.5
        \\.meas tran cap param='max(icap(1,2,3,4))'
        \\.meas tran fast param='(t1 < 0.25) ? 1 : 0'
        \\.meas tran cv find par('(time/v(p))*4') at=0.5m
        \\.meas tran mix param='icap(1,1,1,1)*t1'
        \\.meas tra skipped find v(p) at=1u
        \\.meas tran
        \\.end
        \\
    );
    const m = nl.deck.measures;
    try std.testing.expectEqual(5, m.len);
    try std.testing.expectEqual(1, m[1].expr.len);
    try std.testing.expectApproxEqRel(9.797958971132712, m[1].expr[0].num, 1e-15);
    try std.testing.expectEqualDeep(@as([]const MeasureOp, &.{ .{ .measure = 0 }, .{ .num = 0.25 }, .lt, .{ .num = 1 }, .{ .num = 0 }, .ternary }), m[2].expr);
    try std.testing.expectEqualDeep(@as([]const MeasureOp, &.{ .{ .vector = "time" }, .{ .vector = "v(p)" }, .div, .{ .num = 4 }, .mul }), m[3].first.ops);
    try std.testing.expectEqualDeep(@as([]const MeasureOp, &.{ .{ .num = 2 }, .{ .measure = 0 }, .mul }), m[4].expr);
    const base = "t\n.func twice(x) 'x*2'\nv1 p 0 1\nr1 p 0 1\n.tran 1u 1m\n.meas tran t1 when v(p)=0.5\n";
    try expectRefused(error.UnsupportedCard, &.{
        base ++ ".meas tran a param='abs(t1)'\n.end\n",
        base ++ ".meas tran a param='twice(t1)'\n.end\n",
        base ++ ".meas tran a param='nosuch*2'\n.end\n",
        base ++ ".meas tran a find par('sqrt(v(p))') at=1u\n.end\n",
    });
    try expectRefused(error.ParseError, &.{
        base ++ ".meas tran a frob v(p)\n.end\n",
        base ++ ".meas tran a param='(t1'\n.end\n",
    });
    try expectRefused(error.ParseError, &.{
        "t\nv1 p 0 1\nr1 p 0 1\n.tran 1u 1m\n.meas tran a frob v(p)\n.end\n",
    });
}

// Oracle: the keyword rule (one spelling per capability) and ngspice 44.2,
// which stops on each card ("unimplemented dot command", measured). Each
// only renamed a card ESPice reads: `.pss`, `.pac`, `.pnoise`, `.pxf`,
// `.pss v(osc)`, `.hb v(osc)`, `.noise`, `.meas`, `.stim`, `.meas jitter`.
test "HSPICE spellings of ngspice and ESPice cards are unknown cards" {
    const base = "t\nv1 a 0 sin(0 1 1meg) ac 1\nr1 a 0 1k\n";
    try expectRefused(error.UnsupportedCard, &.{
        base ++ ".sn tres=10n period=1u\n.end\n",
        base ++ ".pss 1meg 100\n.snac dec 2 1k 10k\n.end\n",
        base ++ ".pss 1meg 100\n.snnoise v(a) v1 dec 2 1k 10k\n.end\n",
        base ++ ".pss 1meg 100\n.snxf v(a) dec 2 1k 10k\n.end\n",
        base ++ ".snosc v(a) 1meg 64\n.end\n",
        base ++ ".hbosc v(a) 1meg 7\n.end\n",
        base ++ ".ac dec 2 1k 10k\n.acphasenoise v(a) v1 carrier=1g\n.end\n",
        base ++ ".tran 1n 2u\n.power v1 from=0 to=1u\n.end\n",
        base ++ ".tran 1n 2u\n.stimuli pwl v(a)\n.end\n",
        base ++ ".tran 1n 2u\n.jitter tran trig v(a) val=0 td=50n\n.end\n",
    });
}

test "shunt options add one R or C per net to ground [CR Ch.3]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a b 1\nr2 b 0 1\n.options gshunt=1e-12 cshunt=1p rshunt=1e9\n");
    // Nets a and b, three shunts each, after the two cards.
    try std.testing.expectEqual(@as(u32, 2 + 2 * 3), nl.deviceCount());
    const g = try device(nl, "r.gshunt.a");
    try std.testing.expectEqual(@as(f64, 1e12), g.positional[0].num);
    try std.testing.expectEqual(netlist.ground, g.pins[1]);
    try std.testing.expectEqual(@as(f64, 1e-12), (try device(nl, "c.cshunt.b")).positional[0].num);
    try std.testing.expectEqual(@as(f64, 1e9), (try device(nl, "r.rshunt.b")).positional[0].num);
    // A zero shunt adds nothing.
    const none_added = try netlist.parse(arena.allocator(), "t\nr1 a 0 1\n.options gshunt=0\n");
    try std.testing.expectEqual(@as(u32, 1), none_added.deviceCount());
}

test ".ic keeps nets some card names, never ground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a b 1\n.ic v(a)=1 v(0)=2 v(nosuch)=3 v(b)=x\n.ic v(b)=2\n.nodeset v(a)=0.5 all=0.7\n");
    try std.testing.expectEqual(@as(usize, 2), nl.deck.ic.len);
    try std.testing.expectEqualStrings("a", nl.netName(nl.deck.ic[0].net));
    try std.testing.expectEqual(@as(f64, 1), nl.deck.ic[0].value);
    try std.testing.expectEqualStrings("b", nl.netName(nl.deck.ic[1].net));
    try std.testing.expectEqual(@as(f64, 2), nl.deck.ic[1].value);
    try std.testing.expectEqual(@as(usize, 1), nl.deck.nodeset.len);
    try std.testing.expectEqual(@as(f64, 0.5), nl.deck.nodeset[0].value);
    // Oracle: ngspice 44.2 stops on `.ic b 2` and `.nodeset b 2` with
    // "syntax error" and has no `.dcvolt` (measured); SpiceRack writes
    // HSPICE's forms as `v(b)=2`.
    try expectRefused(error.ParseError, &.{
        "t\nr1 a b 1\n.ic b 2\n",
        "t\nr1 a b 1\n.nodeset b 2\n",
    });
    try expectRefused(error.UnsupportedCard, &.{"t\nr1 a b 1\n.dcvolt b 2\n"});
}

test "ngspice reads `10%3` as the number 10 and refuses an operator-led field (#200)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a 0 r=10%3\nr2 a 0 r=2k\\3\n");
    try std.testing.expectEqual(@as(f64, 10), try kvNum((try device(nl, "r1")).kv, "r"));
    try std.testing.expectEqual(@as(f64, 2000), try kvNum((try device(nl, "r2")).kv, "r"));
    try expectRefused(error.UnsupportedCard, &.{
        "t\nr1 a 0 10 %3\n",
        "t\nr1 a 0 10 *3\n",
        "t\nd1 a 0 ^dm\n",
    });
}

test "an X card's m= multiplies the m of each card inside that takes one (inpcom.c:4227-4300)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(),
        \\t
        \\.subckt cell p
        \\r1 p 0 2k m=3
        \\c1 p 0 1p
        \\v1 p q 0
        \\e1 q 0 p 0 1
        \\b1 q 0 v={v(p)}
        \\b2 0 q i={v(p)}
        \\.ends
        \\.subckt outer p
        \\x2 p cell m=5
        \\.ends
        \\.subckt own p m=1
        \\r1 p 0 {2000/m}
        \\.ends
        \\x1 a cell m=2
        \\x3 b outer m=2
        \\x4 c cell
        \\x5 d own m=4
        \\
    );
    // The card's own m times the X card's: m parallel copies of the
    // subcircuit (HSPICE; ngspice overwrites the card's m outside its
    // HSPICE mode, inpcom.c:4272-4300). Nested X cards multiply too.
    try std.testing.expectEqual(@as(f64, 6), try kvNum((try device(nl, "r.x1.r1")).kv, "m"));
    try std.testing.expectEqual(@as(f64, 2), try kvNum((try device(nl, "c.x1.c1")).kv, "m"));
    try std.testing.expectEqual(@as(f64, 2), try kvNum((try device(nl, "b.x1.b2")).kv, "m"));
    try std.testing.expectEqual(@as(f64, 30), try kvNum((try device(nl, "r.x3.x2.r1")).kv, "m"));
    // V, E and a v= B take no m (inpcom.c:4253-4271).
    try std.testing.expectError(error.MissingKey, kvNum((try device(nl, "v.x1.v1")).kv, "m"));
    try std.testing.expectError(error.MissingKey, kvNum((try device(nl, "e.x1.e1")).kv, "m"));
    try std.testing.expectError(error.MissingKey, kvNum((try device(nl, "b.x1.b1")).kv, "m"));
    // No m on the X card: the cards keep their own.
    try std.testing.expectEqual(@as(f64, 3), try kvNum((try device(nl, "r.x4.r1")).kv, "m"));
    try std.testing.expectError(error.MissingKey, kvNum((try device(nl, "c.x4.c1")).kv, "m"));
    // A subcircuit that declares m reads it as its own parameter
    // (inpcom.c:4341-4344): R = 2000/4, no multiplier on the card.
    const own = try device(nl, "r.x5.r1");
    try std.testing.expectEqual(@as(f64, 500), own.positional[0].num);
    try std.testing.expectError(error.MissingKey, kvNum(own.kv, "m"));
}

test "a lone POLY(1) coefficient is p0, as ngspice reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ngspice: the constant term alone, `(2)`, folds to a number.
    const ng = try device(try netlist.parse(a, "t\ne1 o 0 poly(1) a 0 2\nr1 a 0 1\n"), "e1");
    try std.testing.expectEqual('b', ng.kind);
    try std.testing.expectEqual(@as(f64, 2), try kvNum(ng.kv, "v"));
    try expectRefused(error.ParseError, &.{
        "t\ne1 o 0 poly(0) a 0 2\n",
        "t\ne1 o 0 poly(9) a 0 2\n",
        "t\ne1 o 0 poly(1.5) a 0 2\n",
        "t\ne1 o 0 poly(1) a 0\n",
    });
}

test "LAPLACE, POLE and DELAY keep their letter and count their terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lap = try device(try netlist.parse(a, "t\ne1 o 0 laplace a 0 1 / 1 1e-3\n"), "e1");
    try std.testing.expectEqual('e', lap.kind);
    try std.testing.expectEqual(@as(usize, 4), lap.pins.len);
    try std.testing.expectEqual(@as(usize, 3), lap.positional.len);
    try std.testing.expectEqual(@as(f64, 1), try kvNum(lap.kv, "laplace"));
    const pole = try device(try netlist.parse(a, "t\ng1 o 0 pole a 0 1 / 1 2 3\n"), "g1");
    try std.testing.expectEqual(@as(f64, 1), try kvNum(pole.kv, "pole"));
    const delay = try device(try netlist.parse(a, "t\ne1 o 0 delay a 0 td=1n\n"), "e1");
    try std.testing.expectEqual(@as(f64, 1e-9), try kvNum(delay.kv, "td"));
    try expectRefused(error.ParseError, &.{
        "t\ne1 o 0 laplace a 0 1\n", // no denominator
        "t\ne1 o 0 laplace a 0 / 1\n", // no numerator
        "t\ne1 o 0 pole a 0 1 2 / 1\n", // an even numerator count
        "t\ne1 o 0 delay a 0 1 td=1n\n", // a stray coefficient
    });
    // Without `td=` the line is ngspice's linear E with `delay` a node:
    // ngspice-44.2 runs `e1 o 0 delay a 3` as v(o) = 3·v(delay, a).
    const linear = try device(try netlist.parse(a, "t\ne1 o 0 delay a 0\n"), "e1");
    try std.testing.expectEqual(@as(usize, 4), linear.pins.len);
    try std.testing.expectError(error.MissingKey, kvNum(linear.kv, "delay"));
    try std.testing.expect(linear.positional[0] == .num and linear.positional[0].num == 0);
    try expectRefused(error.UnsupportedCard, &.{"t\nf1 o 0 laplace a 0 1 / 1\n"});
}

test ".options vpi= names VPI applications in their own case (#197)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try netlist.parse(arena.allocator(), "t\nr1 a 0 1\n.options reltol=1e-4 vpi=\"Lib/App.so\" vpi='b.so'\n");
    try std.testing.expectEqual(@as(usize, 2), nl.deck.vpi_apps.len);
    try std.testing.expectEqualStrings("Lib/App.so", nl.deck.vpi_apps[0]);
    try std.testing.expectEqualStrings("b.so", nl.deck.vpi_apps[1]);
    // The card's other options read as any `.options`.
    const args = nl.deck.config[0].args;
    try std.testing.expectEqualStrings("reltol", args[0].name);
    try std.testing.expectEqual(@as(f64, 1e-4), args[1].num);
    try expectRefused(error.ParseError, &.{"t\nr1 a 0 1\n.options vpi=\n"});
}

// Oracle: ngspice 44.2 runs no analysis for a `.temp` card of any length
// (measured: `.temp 25 50 75` warns "Could not set temperature" and runs
// `.op` alone at 27). The values stay as written; prepared.zig's test
// folds them into the temperature in every card order.
test "every .temp card is configuration, never an analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const f64{ &.{50}, &.{ 25, 50 }, &.{ -40, 125, 55 } }, [_][]const u8{ ".temp 50\n", ".temp 25 50\n", ".temp -40 125 55\n" }) |want, card| {
        const nl = try netlist.parse(a, try std.mem.concat(a, u8, &.{ "t\nr1 a 0 1\n", card, ".op\n" }));
        try std.testing.expectEqual(@as(usize, 1), nl.deck.config.len);
        try std.testing.expect(nl.deck.config[0].temp);
        try std.testing.expectEqual(want.len, nl.deck.config[0].args.len);
        for (want, nl.deck.config[0].args) |w, got| try std.testing.expectEqual(w, got.num);
        try std.testing.expectEqual(@as(usize, 1), nl.deck.analyses.len);
        try std.testing.expectEqual(.op, nl.deck.analyses[0].kind);
    }
}

test ".connect is top-level only; nested .subckt definitions stop at 16" {
    try expectRefused(error.UnsupportedCard, &.{"t\n.subckt s a\n.connect a b\nr1 a 0 1\n.ends\nx1 n s\n"});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ 16, 17 }) |depth| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "t\n");
        for (0..depth) |k| try src.print(a, ".subckt s{d} p\n", .{k});
        try src.appendSlice(a, "r1 p 0 1\n");
        for (0..depth) |_| try src.appendSlice(a, ".ends\n");
        try src.appendSlice(a, "x1 n s0\n");
        if (depth == 16)
            _ = try netlist.parse(a, src.items)
        else
            try std.testing.expectError(error.ParseError, netlist.parse(a, src.items));
    }
}

test "groups nest 32 deep; the 33rd level is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ 32, 33 }) |depth| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "t\nv1 a 0 ");
        for (0..depth) |_| try src.appendSlice(a, "f(");
        try src.append(a, '1');
        for (0..depth) |_| try src.append(a, ')');
        try src.append(a, '\n');
        if (depth == 32) {
            const nl = try netlist.parse(a, src.items);
            var v = (try device(nl, "v1")).positional[0];
            for (0..depth) |_| v = v.group.args()[0];
            try std.testing.expectEqual(@as(f64, 1), v.num);
        } else try std.testing.expectError(error.ParseError, netlist.parse(a, src.items));
    }
}

test "parseAnalyses takes analysis cards only (#64)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Lookup = struct {
        pub fn node(_: @This(), name: []const u8) u32 {
            return if (std.mem.eql(u8, name, "out")) 7 else netlist.none;
        }
    };
    const got = try netlist.parseAnalyses(a, ".TRAN 1n 10n\n* note\n.ac dec 10 1 1g\n.tf v(OUT) v1\n", Lookup{});
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings(".TRAN 1n 10n", got[0].line); // as written
    try std.testing.expectEqual(@as(u32, 7), got[2].pos);
    for ([_][]const u8{ "r1 a 0 1\n", ".temp 27\n", ".foo 1\n", ".param p=1\n", ".model m d\n" }) |text|
        try std.testing.expectError(error.UnsupportedDirectiveMutation, netlist.parseAnalyses(a, text, Lookup{}));
    try std.testing.expectEqual(@as(usize, 0), (try netlist.parseAnalyses(a, "", Lookup{})).len);
}

test "a card keeps the deck's spelling next to a card joined from + lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Oracle: the deck's own bytes. The joined `.model` moves its text, so
    // the cards around it must still be found where the deck has them,
    // whatever the title line's length.
    const nl = try netlist.parse(arena.allocator(), "A Title Longer Than The Cards Below It\n.OPTION NOACCT\n.TRAN 1N 10N\n.MODEL dm D IS=1e-14\n+ N=1\nd1 a 0 dm\nv1 a 0 1\n");
    try std.testing.expectEqualStrings(".TRAN 1N 10N", nl.deck.analyses[0].line);
    try std.testing.expectEqualStrings(".OPTION NOACCT", nl.deck.config[0].line);
}

fn parseAnalysesAll(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const Lookup = struct {
        pub fn node(_: @This(), _: []const u8) u32 {
            return 1;
        }
    };
    _ = try netlist.parseAnalyses(arena.allocator(), ".tran 1n 10n sweep monte=3\n.four 1k v(a) v(b)\n.ac dec 10 1 1g\n", Lookup{});
}

test "parseAnalyses: every allocation failure surfaces as OutOfMemory" {
    try std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, parseAnalysesAll, .{});
}

fn parseDeck(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try netlist.parse(a,
        \\allocation failures
        \\.param p=1
        \\.subckt cell a b w0=1u
        \\r1 a b 'p*2'
        \\.ends
        \\x1 in out cell w0=2u
        \\v1 in 0 pat (1 0 0 1n 1n 5n b101)
        \\.mosra reltotaltime=10
        \\.tran 1n 10n sweep p lin 3 1 2
        \\.end
    );
}

test "a deck of subcircuits, PAT, .mosra and a sweep tail: every allocation failure surfaces as OutOfMemory" {
    try std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, parseDeck, .{});
}
