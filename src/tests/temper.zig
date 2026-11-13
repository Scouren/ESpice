//! Card values that read `temper` follow the circuit temperature at every
//! move: `.temp`, `.dc temp`, `.step temp`, and each
//! analysis's start, as ngspice re-evaluates them (inp.c
//! inp_evaluate_temper; cktdojob.c:133, dctrcurv.c:217). Oracles:
//! ngspice's own regression checks (tests/regression/temper: temper-2's
//! i(v_test)/i(v_fix) is the temperature, temper-3's resistance is
//! 1000 + T), a literal twin (each `temper` written as the number it takes
//! at that temperature, which must solve bit for bit alike), and the
//! metamorphic relations `.dc temp` = one `.op` per `.temp` and
//! `.step temp` = `.temp`. The corpus decks temp/temper_*.sp carry ngspice
//! 44.2's goldens; the corpus runs them on the GPU too. Where ngspice reads
//! no temper (a V, I, linear E or G card, and a `.param` over hertz or
//! time), its own `-b` run on each deck is the oracle: it stops there.
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;

/// ngspice's temper-2.cir without its control block: d_test's is is
/// 1e-12 temper, d_fix's 1e-12, both junctions at v(2).
const temper2 =
    \\temper-2
    \\.model dtest D is='1e-12 * temper'
    \\.model dfix  D is='1e-12'
    \\v1  1 0  dc 5v
    \\r1  1 2  5k
    \\d_test  2 3  dtest
    \\v_test  3 0  dc=0
    \\d_fix   2 4  dfix
    \\v_fix   4 0  dc=0
    \\
;

/// A model value and an instance value over temper (todo-temper-3.cir's
/// forms); `$IS` and `$AREA` are the two values, written per test.
const pair =
    \\pair
    \\.model dtest D is=$IS
    \\.model dref d is=1e-10
    \\v1 1 0 dc 5
    \\r1 1 2 5k
    \\d1 2 0 dtest
    \\d2 2 3 dref area=$AREA
    \\v2 3 0 0
    \\
;
const is_temper = "'1e-12 * temper'";
const area_temper = "{temper >= 25 ? (temper+100)/100 : 2}";

// ---- private ----

/// `pair` with `is` and `area` written in, then `tail`.
fn pairDeck(a: std.mem.Allocator, is: []const u8, area: []const u8, tail: []const u8) ![]const u8 {
    const with_is = try std.mem.replaceOwned(u8, a, pair, "$IS", is);
    return std.mem.concat(a, u8, &.{ try std.mem.replaceOwned(u8, a, with_is, "$AREA", area), tail });
}

/// The error `source` stops with, at parse or at run; null if it runs.
fn refusal(source: []const u8) ?anyerror {
    const p = deck.solve(source) catch |err| return err;
    p.deinit();
    return null;
}

/// The requested results of `p` in deck order, then those of the runs with
/// a circuit of their own (`run_results`): the planner rebuilds an `.alter`
/// or a `.step` point whose values read `temper` (variant_planner.zig
/// `addAlter`, `load`). The slice lives in `a`.
fn results(a: std.mem.Allocator, p: *const api.Problem) ![]const api.Result {
    var out: std.ArrayList(api.Result) = .empty;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if ((try p.query_info(id)).requested) try out.append(a, try p.result(id));
    }
    try out.appendSlice(a, try p.run_results(a));
    return out.items;
}

/// The one requested result whose plot name holds `label`.
fn named(rs: []const api.Result, label: []const u8) !api.Result {
    for (rs) |r| if (std.mem.indexOf(u8, r.plotname, label) != null) return r;
    std.debug.print("no plot holding {s}\n", .{label});
    return error.MissingPlot;
}

/// Real column `name` of `r` at `point`; data is point-major.
fn value(r: api.Result, name: []const u8, point: usize) !f64 {
    if (point >= r.npoints) return error.MissingPoint;
    return r.data[point * r.varnames.len + try deck.column(r, name)];
}

/// Every column of the single-point `want` within `rtol` of `got`'s.
fn expectSame(want: api.Result, got: api.Result, rtol: f64) !void {
    try t.expectEqual(want.varnames.len, got.varnames.len);
    for (want.varnames, 0..) |name, i| {
        const x = want.data[i];
        const y = try value(got, name, 0);
        if (!(@abs(x - y) <= rtol * @abs(x))) {
            std.debug.print("{s}: {s} is {e}, want {e}\n", .{ got.plotname, name, y, x });
            return error.TestExpectedApproxEqRel;
        }
    }
}

test "temper-2: i(v_test)/i(v_fix) is the temperature at every .dc temp point" {
    const p = try deck.solve(temper2 ++ ".dc temp 10 100 10\n.end\n");
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = (try results(arena.allocator(), p))[0];
    try t.expectEqual(@as(usize, 10), r.npoints);
    // ngspice's default gmin, which each diode stamps across its junction.
    const gmin = 1e-12;
    for (0..r.npoints) |k| {
        const temp: f64 = @floatFromInt(10 + 10 * k);
        // Both junctions sit at v(2), so less each one's gmin current the
        // two currents are T is (e - 1) and is (e - 1): the ratio is T to
        // rounding, at the solved v(2) and at every Newton iterate alike.
        // The raw ratio misses T by that gmin term, -5.6e-9 at 10 degC to
        // -2.4e-8 at 90, in ngspice 44.2's run of this deck as in ESPice's.
        const g = gmin * try value(r, "v(2)", k);
        try t.expectApproxEqRel(temp, (try value(r, "i(v_test)", k) - g) / (try value(r, "i(v_fix)", k) - g), 1e-12);
    }
}

test "temper-3: a resistor model's r='1000 + temper' is 1000 + T at every .dc temp point" {
    const p = try deck.solve(
        \\temper-3
        \\.model rtest r r='1000 + temper'
        \\.model rfix  r r='1000'
        \\v1  1 0  dc 5v
        \\r_test  1 0  rtest
        \\.dc temp 10 100 10.0
        \\.end
        \\
    );
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = (try results(arena.allocator(), p))[0];
    try t.expectEqual(@as(usize, 10), r.npoints);
    for (0..r.npoints) |k| {
        const temp: f64 = @floatFromInt(10 + 10 * k);
        const ohms = -(try value(r, "v(1)", k)) / try value(r, "i(v1)", k);
        try t.expectApproxEqAbs(temp, ohms - 1000, 1e-9);
    }
}

test "a model and an instance value over temper at .temp 50 solve bit for bit as their literal twins" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The twin folds each value in the order the temper expression runs.
    const twin = try deck.solve(try pairDeck(a, "{1e-12 * 50}", "{50 >= 25 ? (50+100)/100 : 2}", ".temp 50\n.op\n.end\n"));
    defer twin.deinit();
    const moved = try deck.solve(try pairDeck(a, is_temper, area_temper, ".temp 50\n.op\n.end\n"));
    defer moved.deinit();
    try expectSame((try results(a, twin))[0], (try results(a, moved))[0], 0);
}

test ".dc temp equals one .op per .temp at each of its points" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two Newton paths (the sweep warm, the .op cold) to one point, each
    // stopping within its own update tolerance: at the default reltol
    // 1e-3 they part by 6e-6 in v(2) at 70 degC (ngspice 44.2's own .dc
    // temp misses its .op there by 1e-3). Tightened, they agree to 2e-10.
    const tight = ".options reltol=1e-9 vntol=1e-12 abstol=1e-18\n";
    const sweep = try deck.solve(temper2 ++ tight ++ ".dc temp 10 100 30\n.end\n");
    defer sweep.deinit();
    const r = (try results(a, sweep))[0];
    try t.expectEqual(@as(usize, 4), r.npoints);
    for (0..r.npoints) |k| {
        const temp = 10 + 30 * k;
        const op = try deck.solve(try a.print("{s}{s}.temp {d}\n.op\n.end\n", .{ temper2, tight, temp }));
        defer op.deinit();
        const want = (try results(a, op))[0];
        for ([_][]const u8{ "v(2)", "i(v_test)", "i(v_fix)" }) |name|
            try t.expectApproxEqRel(try value(want, name, 0), try value(r, name, k), 1e-8);
    }
}

test ".step temp equals .temp at every temperature" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stepped = try deck.solve(try pairDeck(a, is_temper, area_temper, ".step temp list 10 50\n.op\n.end\n"));
    defer stepped.deinit();
    const step_rs = try results(a, stepped);
    for ([_][]const u8{ "10", "50" }) |temp| {
        const single = try deck.solve(try pairDeck(a, is_temper, area_temper, try a.print(".temp {s}\n.op\n.end\n", .{temp})));
        defer single.deinit();
        const want = (try results(a, single))[0];
        // Each a cold operating point of one circuit at one temperature.
        try expectSame(want, try named(step_rs, try a.print("(temp={s})", .{temp})), 1e-12);
    }
}

test "a value over temper and a swept .param follows both, as its literal twin at each point" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = ".param p=1\n.model dtest D is={p*1e-12*temper}\nv1 1 0 dc 5\nr1 1 2 5k\nd1 2 0 dtest\n.temp 50\n";
    const stepped = try deck.solve(try a.print("step\n{s}.step param p list 1 3\n.op\n.end\n", .{body}));
    defer stepped.deinit();
    const rs = try results(a, stepped);
    for ([_][]const u8{ "1", "3" }) |pv| {
        const twin = try deck.solve(try a.print("twin\n.param p={s}\n.model dtest D is={{p*1e-12*50}}\nv1 1 0 dc 5\nr1 1 2 5k\nd1 2 0 dtest\n.temp 50\n.op\n.end\n", .{pv}));
        defer twin.deinit();
        try expectSame((try results(a, twin))[0], try named(rs, try a.print("(p={s})", .{pv})), 0);
    }
}

test "an .alter that rewrites a value over temper solves as its literal twin at .temp 50, and so does the main run" {
    // Each run's values over temper follow its own expressions: the .alter
    // run builds its own circuit and table (variant_planner.zig addAlter),
    // so a temperature move never rewrites the altered is from the main
    // run's expression. Red as a row: the alter run solved with is = 5e-11
    // (the main run's), 3x under its twin's.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = ".options reltol=1e-9 vntol=1e-12 abstol=1e-18\n.temp 50\nv1 1 0 dc 5\nr1 1 2 5k\nd1 2 0 dtest\n.op\n";
    const altered = try deck.solve(try a.print("alter\n{s}.model dtest D is='1e-12 * temper'\n.alter\n.model dtest D is='3e-12 * temper'\n.end\n", .{body}));
    defer altered.deinit();
    const rs = try results(a, altered);
    try t.expectEqual(@as(usize, 2), rs.len);
    for ([_][]const u8{ "1e-12", "3e-12" }, [_]api.Result{ rs[0], try named(rs, "alter=1") }) |is, got| {
        const twin = try deck.solve(try a.print("twin\n{s}.model dtest D is={{{s} * 50}}\n.end\n", .{ body, is }));
        defer twin.deinit();
        // Two cold operating points of one circuit, Newton tightened.
        try expectSame((try results(a, twin))[0], got, 1e-9);
    }
}

test "a .param over temper, hertz or time stops where ngspice-44.2 stops, read or not; an unread temper runs" {
    // ngspice-44.2 -b (SpiceRack R9): numparam evaluates each .param where
    // it stands and has no hertz or time ("Undefined parameter [hertz]"),
    // read or not. A .param over temper becomes a .func (inpcom.c
    // inp_fix_temper_in_param): unread it runs; read by a V card, which
    // numparam reads, it stops ("Undefined parameter [temper]"). Red
    // before: ESPice 0.3.0 read p as 0 (SpiceRack), the 2026-11-10 binary
    // ran all six (v(p) = 0 read), and temper_slots read the V card at 27.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var got: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "temper", "hertz", "time" }) |name| for ([_][]const u8{ "read", "unread" }, [_][]const u8{ "{p}", "1" }) |site, v| {
        const err = refusal(try a.print("{s} {s}\n.param p={{{s}}}\nvp p 0 {s}\nrp p 0 1k\n.op\n.end\n", .{ site, name, name, v }));
        try got.print(a, "{s} {s}: {s}\n", .{ name, site, if (err) |e| @errorName(e) else "ran" });
    };
    try t.expectEqualStrings(
        \\temper read: UnresolvedParameter
        \\temper unread: ran
        \\hertz read: UnsupportedCard
        \\hertz unread: UnsupportedCard
        \\time read: UnsupportedCard
        \\time unread: UnsupportedCard
        \\
    , got.items);
}

test "temper, read directly or through a .param, runs on R, B, E VALUE, F and H cards and stops on V, I, E and G" {
    // ngspice-44.2 -b on each deck. inp_temper_compat hands R and model
    // braces to the B parser, which reads temper; B and E VALUE cards are B
    // sources; F and H run too (its listing shows them rewritten, f1_int1
    // and vbf1). V, I, linear E and G cards are numparam's: "Undefined
    // parameter [temper]". The values are ngspice's on these decks: i(vp) =
    // -1.97371e-03 (-1/1027 - 1/1000), v(o) = 27, 27, -27 and -2.7e-2,
    // each exact in closed form at 27 degC. Red before: temper_slots
    // read every refused card at 27, and an E or G gain that folded to no
    // number ran as 0 (net_devices.zig `addSingleDevice`).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "temper sites\n.param p={temper}\nvp a 0 1\nr1 a 0 1k\nro o 0 1k\n";
    for ([_]struct { []const u8, []const u8, f64 }{
        .{ "rp a 0 {1k+p}\n", "i(vp)", -1.0 / 1027.0 - 1e-3 },
        .{ "rp a 0 {1k+temper}\n", "i(vp)", -1.0 / 1027.0 - 1e-3 },
        .{ "b1 o 0 v=p\n", "v(o)", 27 },
        .{ "e1 o 0 value={p}\n", "v(o)", 27 },
        .{ "f1 0 o vp {p}\n", "v(o)", -27 },
        .{ "h1 o 0 vp {p}\n", "v(o)", -0.027 },
    }) |c| {
        const p = try deck.solve(try a.print("{s}{s}.op\n.end\n", .{ head, c[0] }));
        defer p.deinit();
        try t.expectApproxEqRel(c[2], try deck.at(try deck.resultOf(p, .op), 0, c[1]), 1e-12);
    }
    var ran: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        "vq q 0 {temper}\nrq q 0 1k\n",
        "iq 0 q {temper}\nrq q 0 1k\n",
        "iq 0 q {p}\nrq q 0 1k\n",
        "e1 o 0 a 0 {temper}\n",
        "e1 o 0 a 0 {p}\n",
        "g1 0 o a 0 {temper*1m}\n",
        "g1 0 o a 0 {p*1m}\n",
        ".param q={p+1}\nvq q 0 {q}\nrq q 0 1k\n",
    }) |card| {
        const err = refusal(try a.print("{s}{s}.op\n.end\n", .{ head, card }));
        const refused = if (err) |e| e == error.UnresolvedParameter else false;
        if (!refused) try ran.print(a, "{s}: {s}\n", .{ card, if (err) |e| @errorName(e) else "ran" });
    }
    try t.expectEqualStrings("", ran.items);
}

test "temper through a factor the card applies is refused by code, not frozen" {
    // A semiconductor resistor's R is l/w times the model's rsh: no
    // parameter takes rsh's value, so a temperature move cannot write it.
    try t.expectEqual(@as(?anyerror, error.UnsupportedCard), refusal(
        \\factor
        \\.model rr r rsh='10*temper'
        \\v1 1 0 1
        \\r1 1 0 rr l=20u w=2u
        \\.dc temp 10 100 10
        \\.end
        \\
    ));
}
