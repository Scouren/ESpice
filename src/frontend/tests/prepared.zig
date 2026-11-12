//! Prepare tests: netlist → `Prepared` circuit and resolved queries, for
//! analyses, variants, saves and refusals, against hand-worked expectations
//! (and, for runtime-registered devices, the same model built in).
const std = @import("std");
const input = @import("../prepare.zig");
const analyses = @import("../analyses.zig");
const netlist = @import("netlist");
const core = @import("core");
const requests = @import("core").query;
const Job = requests.Query;
const NO_NODE = analyses.NO_NODE;
const device = @import("device");

/// Built-ins only: their vtables are static, so the Library may die first.
fn build(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: netlist.Netlist) !input.Prepared {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    return input.build(&lib, sim_arena, parse_arena, nl);
}

fn prepare(io: std.Io, session: std.mem.Allocator, source: input.Source) !netlist.Netlist {
    return input.prepare(io, session, source, &.{}, .{});
}
const resolveQueries = input.resolveQueries;

fn parse(arena: std.mem.Allocator, src: []const u8) !netlist.Netlist {
    return netlist.parse(arena, src);
}

/// The only card of `src`, with output node row 1 and no reference.
fn card(arena: std.mem.Allocator, src: []const u8) !netlist.Analysis {
    const nl = try parse(arena, try std.fmt.allocPrint(arena, "dispatch\n{s}\n.end\n", .{src}));
    var a = nl.deck.analyses[0];
    a.pos = 1;
    a.neg = NO_NODE;
    a.ports = @splat(NO_NODE);
    return a;
}

test "analysis directives dispatch every implemented capability and reject malformed requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources: core.QueryBindings = .{ .v_names = &.{"vin"}, .i_names = &.{}, .v_branches = &.{2}, .v_pos = &.{1}, .v_neg = &.{0}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{.{ 0, 0 }}, .ports = &.{.{ .node = 1, .branch = 2 }} };
    const cards: []const requests.CardRef = &.{.{ .type = device.Library.builtin("vsource"), .index = 0, .name = "vin" }};
    // `.fft` reads the deck's `.tran`, `.acmatch` its `.ac`.
    const ctx: analyses.CardContext = .{ .arena = a, .tran = .{ .t_stop = 10e-6, .dt_init = 1e-6 }, .ac = .{ .f_start = 10, .f_stop = 100 } };
    const directives = [_][]const u8{
        ".ac dec 2 10 100",                           ".dc vin 0 1 0.1",              ".dcmatch v(out)",
        ".disto dec 2 10 100",                        ".envelope 1m 5m",              ".four 1k v(out)",
        ".hb 1k",                                     ".matex 1u 10u",                ".mc 4",
        ".noise v(out) vin dec 2 10 100",             ".op",                          ".pac 1k dec 2 10 100",
        ".pnoise v(out) vin dec 2 10 100 1k 0",       ".pss 1k 128",                  ".pxf 1k dec 2 10 100",
        ".pz",                                        ".qpss 1k 1414 1 1",            ".sens v(out)",
        ".sp dec 2 10 100",                           ".stb vin dec 2 10 100",        ".tf v(out) vin",
        ".tran 1u 10u",                               ".tran_noise 1u 10u",           ".hbac dec 2 10 100 1k",
        ".hbnoise v(out) vin dec 2 10 100 1k 4 2",    ".hbxf v(out) dec 2 10 100 1k", ".phasenoise v(out) dec 2 10 100 1meg",
        ".lstb mode=single vsource=vin dec 2 10 100", ".acxf v(out) dec 2 10 100",    ".dcxf v(out) tf",
        ".dcinc",                                     ".fft v(out)",                  ".acmatch v(out)",
        ".dcsens v(out)",                             ".hblin dec 2 10 100",
    };
    // The temperature sweep query has no card: every `.temp` is
    // configuration, as in ngspice 44.2, and `.dc temp` sweeps.
    const all = @typeInfo(requests.Kind).@"enum".field_names;
    const kinds = comptime blk: {
        var out: [all.len - 1][:0]const u8 = undefined;
        var k: usize = 0;
        for (all) |name| if (!std.mem.eql(u8, name, "temp")) {
            out[k] = name;
            k += 1;
        };
        break :blk out;
    };
    try std.testing.expectEqual(kinds.len, directives.len);
    inline for (directives, kinds) |directive, name| {
        const id = @field(requests.Kind, name);
        const job = try analyses.buildJob(try card(a, directive), sources, cards, ctx);
        try std.testing.expectEqual(id, std.meta.activeTag(job));
        if (job == .pss) try std.testing.expectEqual(@as(f64, 1e-3), job.pss.period);
    }
    const malformed = [_][]const u8{
        ".ac dec 0 1 10",                    ".ac dec -1 1 10",                 ".ac dec 2.5 1 10",                      ".ac dec 2 10 1",
        ".ac lin 2 -1 10",                   ".dc missing 0 1 0.1",             ".dc vin 0 1 0",                         ".dc vin 0 1 -1",
        ".dc vin 0 1 1 missing 0 1 1",       ".tran 0 1u",                      ".tran 1u 2u 2u",                        ".pss 0",
        ".pss 1k 2m out 128 4 50 1m bad",    ".mc 65536",                       ".pnoise v(out) vin dec 2 10 100 1k -1", ".pz in 0 out 0 vol pz",
        ".tf v(out) missing",                ".dc temp -300 125 55",            ".dc vin 0 1 1 temp -300 20 10",         ".lstb mode=diff vsource=vin",
        ".lstb mode=single vsource=vin,vin", ".lstb mode=sideways vsource=vin", ".dcxf v(out) zin",                      ".acxf v(out) dec 2 10 100 tf extra",
    };
    for (malformed) |directive| {
        if (analyses.buildJob(try card(a, directive), sources, cards, ctx)) |_| {
            std.debug.print("accepted: {s}\n", .{directive});
            return error.AcceptedInvalidAnalysis;
        } else |_| {}
    }
    // `.lstb` without its own sweep takes the deck's `.ac` grid, and needs one.
    const bare = try card(a, ".lstb mode=single vsource=vin");
    try std.testing.expectEqual(@as(f64, 100), (try analyses.buildJob(bare, sources, cards, ctx)).lstb.sweep.f_stop);
    try std.testing.expectError(error.MissingAnalysisCard, analyses.buildJob(bare, sources, cards, .{ .arena = a }));
    // HB and QPSS drive from whatever sources the deck stamps, current ones
    // included, so a deck without a V card is valid.
    const no_v: core.QueryBindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} };
    for ([_][]const u8{ ".hb 1k", ".qpss 1k 1414 1 1" }) |directive| _ = try analyses.buildJob(try card(a, directive), no_v, cards, ctx);
}

// Oracle: ngspice 44.2 -b on `v1 a 0 1` / `r1 a 0 1k tc1=0.01` / `.op`,
// each order measured ("Doing analysis at TEMP = ..."): only the last
// `.temp` counts and it beats every `.options temp`, before or after it;
// a `.temp` of other than one value warns and runs at 27 degC; without
// `.temp`, the last `.options temp` wins.
test ".temp and .options temp give ngspice 44.2's temperature in every order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, f64 }{
        .{ ".temp 50\n.options temp=30\n", 50 },
        .{ ".options temp=30\n.temp 50\n", 50 },
        .{ ".temp 25 50\n.options temp=30\n", 27 },
        .{ ".options temp=30\n.temp 25 50\n", 27 },
        .{ ".temp 25 50 75\n.options temp=30\n", 27 },
        .{ ".temp 50\n.temp 25 40\n", 27 },
        .{ ".temp 25 40\n.temp 50\n", 50 },
        .{ ".options temp=30\n.options temp=40\n", 40 },
    };
    for (cases) |case| {
        const nl = try parse(a, try std.mem.concat(a, u8, &.{ "t\nv1 a 0 1\nr1 a 0 1k tc1=0.01\n", case[0], ".op\n.end\n" }));
        try std.testing.expectEqual(@as(?f64, case[1]), (try analyses.deckOptions(nl.deck.config)).temp_c);
        // `.op` is the only analysis: no `.temp` card is one.
        try std.testing.expectEqual(@as(usize, 1), nl.deck.analyses.len);
    }
}

// Oracle: ngspice 44.2 -b, measured. `.options gmindc= absv= relv= absi=`
// runs silently with its defaults, and `method=bdf` prints "unsupported
// integration method" and keeps the method it had.
test "HSPICE's option names change nothing, and an unknown method keeps the last one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const aliases = try analyses.deckOptions((try parse(a, "aliases\n.options gmindc=1e-9 absv=1e-3 relv=1e-2 absi=1e-6\n.end\n")).deck.config);
    try std.testing.expectEqual(core.numerics.Tolerances{}, aliases.tol);
    const bdf = try analyses.deckOptions((try parse(a, "bdf\n.options method=bdf\n.end\n")).deck.config);
    try std.testing.expectEqual(@as(?requests.Method, null), bdf.method);
    const kept = try analyses.deckOptions((try parse(a, "kept\n.options method=gear method=bdf\n.end\n")).deck.config);
    try std.testing.expectEqual(requests.Method.gear_2, kept.method.?);
}

test "ngspice's 7- or 8-argument .pss is ESPice's oscillator card; up to 4 arguments keep ESPice's forms" {
    // inp2dot.c:662-701: `.pss gfreq tstab oscnob psspoints harms sciter
    // steadycoeff [uic]`, colpitt_osc_pss.sp's card. The oracle is the
    // ESPice form written by hand for the same oscillator: guess 3.1 MHz,
    // 500 us = 1550 guess periods of settling, phase node 3, 256 samples.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Pss = struct {
        /// The `.pss` query of `card_text` in a deck whose only net is `3`.
        fn job(arena_: std.mem.Allocator, card_text: []const u8) !requests.Pss {
            const nl = try parse(arena_, try std.mem.concat(arena_, u8, &.{ "pss forms\nr1 3 0 1k\nc1 3 0 1n\n", card_text, "\n.end\n" }));
            const none: core.QueryBindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} };
            return (try analyses.buildJob(nl.deck.analyses[0], none, &.{}, .{ .arena = arena_ })).pss;
        }
    };
    const espice = try Pss.job(a, ".pss v(3) 3.1e6 256 1550");
    try std.testing.expect(espice.osc_node != 0);
    // Plus the ngspice card's own keys: harms 10 spectrum rows, sciter 50
    // as 51 residual tests (ngspice-45 dcpss.c:874, 908: the counter is
    // bumped before `> sc_iter` is tested) and steadycoeff 5e-3. Red
    // before: all three dropped.
    var ngspice = espice;
    ngspice.harms = 10;
    ngspice.max_shooting_iter = 51;
    ngspice.steady_coeff = 5e-3;
    try std.testing.expectEqual(ngspice, try Pss.job(a, ".pss 3.1e6 500e-6 3 256 10 50 5e-3"));
    var uic = ngspice;
    uic.uic = true;
    try std.testing.expectEqual(uic, try Pss.job(a, ".pss 3.1e6 500e-6 3 256 10 50 5e-3 uic"));
    // sciter 0 is one test (red before: refused as no count).
    try std.testing.expectEqual(@as(u16, 1), (try Pss.job(a, ".pss 3.1e6 500e-6 3 256 10 0 5e-3")).max_shooting_iter);
    // ESPice's driven form is untouched.
    try std.testing.expectEqual(@as(u32, 0), (try Pss.job(a, ".pss 3.1e6 256")).osc_node);
    // An oscnob that names no net (ring_osc_pss.sp's `1`) or ground runs,
    // as in ngspice, whose INPtermInsert makes the node: the solve picks
    // its phase node. 624 MHz for 500 ns is 312 guess periods.
    const picked: requests.Pss = .{ .period = 1 / @as(f64, 624e6), .phase_node = .largest_swing, .osc_settle_periods = 312, .n_samples = 1024, .uic = true, .harms = 10, .max_shooting_iter = 6, .steady_coeff = 5e-3 };
    try std.testing.expectEqual(picked, try Pss.job(a, ".pss 624e6 500n 1 1024 10 5 5e-3 uic"));
    var grounded = picked;
    grounded.uic = false;
    try std.testing.expectEqual(grounded, try Pss.job(a, ".pss 624e6 500n 0 1024 10 5 5e-3"));
    // 5 and 6 arguments are neither form; an 8th word other than uic is
    // refused, where ngspice warns and drops it. So are a sciter that is
    // no count and a steadycoeff that bounds nothing.
    for ([_][]const u8{ ".pss 3.1e6 500e-6 3 256 10", ".pss 3.1e6 500e-6 3 256 10 50", ".pss 3.1e6 500e-6 3 256 10 50 5e-3 now", ".pss 3.1e6 -1 3 256 10 50 5e-3", ".pss 3.1e6 500e-6 3 256 10 -1 5e-3", ".pss 3.1e6 500e-6 3 256 10 2.5 5e-3", ".pss 3.1e6 500e-6 3 256 10 50 0" }) |text|
        try std.testing.expectError(error.InvalidAnalysisArguments, Pss.job(a, text));
}

test ".ac lin admits 0 Hz at both ends; dec and oct do not (ac-zero.sp)" {
    // ngspice runs tests/regression/misc/ac-zero.sp's `.ac lin 1 0Hz 0Hz`
    // as one point at DC; a geometric grid has no ratio from 0.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources: core.QueryBindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} };
    const job = try analyses.buildJob(try card(a, ".ac lin 1 0Hz 0Hz"), sources, &.{}, .{ .arena = a });
    try std.testing.expectEqual(@as(f64, 0), job.ac.sweep.f_stop);
    try std.testing.expectEqual(@as(u32, 1), job.ac.sweep.count());
    try core.validate.validate(job, 3);
    for ([_][]const u8{ ".ac dec 1 0 0", ".ac oct 1 0 0", ".ac lin 1 0 -1" }) |text|
        try std.testing.expectError(error.InvalidAnalysisArguments, analyses.buildJob(try card(a, text), sources, &.{}, .{ .arena = a }));
}

test ".sp's fifth word is ngspice's donoise, on only at 1 (sp1.sp, sp2.sp)" {
    // inp2dot.c:1074-1076 reads it as an integer; spsetp.c:80 sets
    // SPdoNoise = (value == 1), so 0 and 2 both leave it off.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources: core.QueryBindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} };
    const cases = [_]struct { []const u8, bool }{
        .{ ".sp lin 100 1e8 1e9  1", true }, .{ ".sp dec 100 1 1e6 0", false },
        .{ ".sp dec 100 1 1e6 2", false },   .{ ".sp dec 100 1 1e6", false },
    };
    for (cases) |case| {
        const job = try analyses.buildJob(try card(a, case[0]), sources, &.{}, .{ .arena = a });
        try std.testing.expectEqual(case[1], job.sp.noise);
    }
    try std.testing.expectEqual(@as(u32, 100), (try analyses.buildJob(try card(a, ".sp lin 100 1e8 1e9 1"), sources, &.{}, .{ .arena = a })).sp.sweep.count());
    for ([_][]const u8{ ".sp lin 100 1e8 1e9 1 1", ".sp lin 100 1e8 1e9 yes" }) |text|
        try std.testing.expectError(error.InvalidAnalysisArguments, analyses.buildJob(try card(a, text), sources, &.{}, .{ .arena = a }));
}

test ".sens <out> ac <sweep> carries the grid and each AC source's drive rows (sens-ac-1.sp, sens-ac-2.sp)" {
    // inp2dot.c:481-570: `.sens <out> [dc | ac dec|oct|lin n f1 f2]`.
    // Oracle: the cards by hand. sens-ac-1's `ac=42mA` is the keyword form
    // of the magnitude (isrc.c:16 `acmag`); an I card 0 -> 1 drives +42 mA
    // into node 1, a V card its branch row, and `ac 2 90` is 2 at 90
    // degrees, so its unit phasor is j. `i3` has no AC spec and still has
    // a row, as ngspice still publishes its `_acmag` and `_acphase`: no
    // drive, a unit of 1 times its m.
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const nl = try parse(parse_arena.allocator(),
        \\sens ac
        \\i1 0 1 dc=1.27 ac=42mA
        \\r1 1 0 1k
        \\c1 1 0 100p
        \\v2 2 0 dc 0 ac 2 90
        \\r2 2 0 1k
        \\i3 2 0 dc 1m m=3
        \\.sens v(1) ac lin 1 1e6 1.1e6
        \\.sens v(1) dc
        \\.end
    );
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    const ac = prepared.deck.queries[0].sens;
    try std.testing.expectEqual(@as(u32, 1), ac.ac.?.count());
    try std.testing.expectEqual(@as(f64, 1e6), ac.ac.?.f_start);
    // Found by name: the rows feed name-keyed columns, and ngspice-44.2's
    // raw file orders them by device type (i1, i3, ..., v2), not by card.
    try std.testing.expectEqual(@as(usize, 3), ac.ac_sources.len);
    const row = struct {
        fn of(rows: anytype, name: []const u8) !@TypeOf(rows[0]) {
            for (rows) |r| if (std.mem.eql(u8, r.name, name)) return r;
            return error.TestExpectedEqual;
        }
    }.of;
    const src3 = try row(ac.ac_sources, "i3");
    try std.testing.expectEqual([2]f64{ 0, 0 }, [2]f64{ src3.re, src3.im });
    try std.testing.expectEqual([2]f64{ 3, 0 }, src3.unit);
    try std.testing.expect(src3.pos != core.GROUND);
    try std.testing.expectEqual(core.GROUND, src3.neg);
    const src1 = try row(ac.ac_sources, "i1");
    try std.testing.expectEqual(core.GROUND, src1.pos);
    try std.testing.expectEqual(ac.output_node, src1.neg);
    try std.testing.expectEqual(@as(f64, 0.042), src1.re);
    try std.testing.expectEqual([2]f64{ 1, 0 }, src1.unit);
    try std.testing.expectEqual(@as(f64, 0.042), prepared.deck.ac_drive[src1.neg]);
    const v2 = try row(ac.ac_sources, "v2");
    try std.testing.expectEqual(core.GROUND, v2.pos);
    try std.testing.expectApproxEqAbs(@as(f64, 2), v2.im, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), v2.unit[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), prepared.deck.ac_drive[prepared.circuit.n + v2.neg], 1e-15);
    // The DC form names `dc` explicitly, and stays the DC sensitivity.
    try std.testing.expectEqual(null, prepared.deck.queries[1].sens.ac);
    // A short grid, a word other than dc/ac, and ngspice's parameter filter
    // words (cktsens.c:58-67, not implemented) are refused.
    const none: core.QueryBindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} };
    const a = session.allocator();
    for ([_][]const u8{ ".sens v(out) ac lin 1 1e6", ".sens v(out) tran", ".sens v(out) r1 ac lin 1 1e6 2e6" }) |text|
        try std.testing.expectError(error.InvalidAnalysisArguments, analyses.buildJob(try card(a, text), none, &.{}, .{ .arena = a }));
}

test "deck temperature and tolerances reach statistical and noise jobs" {
    // `.temp` reaches noise through the devices (Circuit.setCircuitTemp ->
    // Model.temperature__ -> the model's own `noisePsd`), not through an
    // analysis-card copy: ngspice's NevalSrc multiplies by `ckt->CKTtemp`
    // (nevalsrc.c:111) because its devices hand over a bare conductance,
    // and ours hand over a finished density.
    const options: analyses.DeckOptions = .{ .temp_c = 85, .tol = .{ .reltol = 1e-5 } };
    var temp_job: Job = .{ .temp = .{} };
    analyses.applyDeckOptions(&temp_job, options);
    try std.testing.expectEqual(options.tol.reltol, temp_job.temp.dc_options.tol.reltol);
}

test "duration ceiling option is explicit and TMAX then DELMAX take precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try parse(a, "ceiling\n.options tran_ceiling=duration\n.end\n");
    {
        const o = try analyses.deckOptions(nl.deck.config);
        var implicit: Job = .{ .tran = .{ .t_stop = 100e-9, .t_start = 20e-9, .dt_init = 1e-9 } };
        analyses.applyDeckOptions(&implicit, o);
        try std.testing.expectApproxEqRel(@as(f64, 8e-9), implicit.tran.dt_max.?, 1e-15);
        try std.testing.expectEqual((requests.Tran{ .t_stop = 1 }).tol, implicit.tran.tol);
        var delmax = o;
        delmax.delmax = 2e-9;
        var d: Job = .{ .tran = .{ .t_stop = 100e-9 } };
        analyses.applyDeckOptions(&d, delmax);
        try std.testing.expectEqual(@as(f64, 2e-9), d.tran.dt_max.?);
        var explicit: Job = .{ .tran = .{ .t_stop = 100e-9, .dt_max = 3e-9 } };
        analyses.applyDeckOptions(&explicit, delmax);
        try std.testing.expectEqual(@as(f64, 3e-9), explicit.tran.dt_max.?);
    }
    for ([_][]const u8{ "other", "1", "" }) |value| {
        const bad = try parse(a, try std.fmt.allocPrint(a, "bad\n.options tran_ceiling={s}\n.end\n", .{value}));
        try std.testing.expectError(error.InvalidAnalysisArguments, analyses.deckOptions(bad.deck.config));
    }
}

test "deck options reject invalid numeric conversions before construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "itl1=-1", "itl2=65536", "itl4=0.4", "temp=-300", "tnom=nan", "reltol=-1" }) |option| {
        const source = try std.fmt.allocPrint(arena.allocator(), "invalid options\n.options {s}\n.end\n", .{option});
        const nl = try parse(arena.allocator(), source);
        try std.testing.expectError(error.InvalidAnalysisArguments, analyses.deckOptions(nl.deck.config));
    }
    // `.temp` beats a later `.options temp`, as in ngspice 44.2 (the
    // precedence test above measures every order).
    const nl = try parse(arena.allocator(), "temp card wins\n.temp 50\n.options temp=27 method=gear maxord=1\n.end\n");
    const o = try analyses.deckOptions(nl.deck.config);
    try std.testing.expectEqual(@as(f64, 50), o.temp_c.?);
    try std.testing.expectEqual(requests.Method.backward_euler, o.method.?);
    // ngspice never rises above order 2: maxord=1 is BE under trap too, and
    // gear keeps Gear-2 at maxord 3..6 (dctran.c:900).
    const trap1 = try analyses.deckOptions((try parse(arena.allocator(), "trap\n.options maxord=1\n.end\n")).deck.config);
    try std.testing.expectEqual(requests.Method.backward_euler, trap1.method.?);
    const gear6 = try analyses.deckOptions((try parse(arena.allocator(), "gear\n.options method=gear maxord=6\n.end\n")).deck.config);
    try std.testing.expectEqual(requests.Method.gear_2, gear6.method.?);
    // The default tmax is min(tstep, (tstop - tstart) / 50) (traninit.c:29).
    var late: Job = .{ .tran = .{ .t_stop = 100e-6, .dt_init = 1e-6, .t_start = 90e-6 } };
    analyses.applyDeckOptions(&late, o);
    try std.testing.expectApproxEqRel(@as(f64, 0.2e-6), late.tran.dt_max.?, 1e-12);
    // DELMAX caps a .tran that sets no tmax [HSPICE CR .OPTION DELMAX];
    // TNOM defaults to 27 and TEMP stays unset, as in ngspice.
    const h = try analyses.deckOptions((try parse(arena.allocator(), "delmax\n.options delmax=2n\n.end\n")).deck.config);
    var tran: Job = .{ .tran = .{ .t_stop = 1e-6, .dt_init = 1e-8 } };
    analyses.applyDeckOptions(&tran, h);
    try std.testing.expectEqual(@as(f64, 2e-9), tran.tran.dt_max.?);
    try std.testing.expectEqual(@as(?f64, null), h.temp_c);
    try std.testing.expectEqual(@as(f64, 27), h.tnom_c);
    // Integer options round as ngspice's floor(0.5 + x).
    const rounded = try parse(arena.allocator(), "rounded\n.options itl4=1.5 itl1=99.4 itl2=2.5\n.end\n");
    const r = try analyses.deckOptions(rounded.deck.config);
    try std.testing.expectEqual(@as(u16, 2), r.tol.itl4);
    try std.testing.expectEqual(@as(u16, 99), r.tol.itl1);
    try std.testing.expectEqual(@as(u16, 3), r.tol.itl2);
    // RUNLVL picks trtol whatever TRTOL says; ACCURATE lifts it to 5, FAST
    // alone is 1, RUNLVL=0 turns both off.
    for ([_]struct { []const u8, ?f64 }{
        .{ "runlvl=6 trtol=7", 0.875 }, .{ "runlvl", 7 },        .{ "accurate runlvl=2", 1.75 },
        .{ "accurate", 1.75 },          .{ "fast", 28 },         .{ "runlvl=0 accurate", null },
        .{ "fast accurate=1", 1.75 },   .{ "accurate=0", null },
    }) |case| {
        const source = try std.fmt.allocPrint(arena.allocator(), "runlvl\n.options {s}\n.end\n", .{case[0]});
        try std.testing.expectEqual(case[1], (try analyses.deckOptions((try parse(arena.allocator(), source)).deck.config)).trtol);
    }
}

test "nonfinite model parameter cannot become its default" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try parse(pa.allocator(),
        \\invalid model value
        \\.model nm nmos(level=1 tox={1/0})
        \\vin in 0 1
        \\r1 in out 1k
        \\m1 out in 0 0 nm
        \\.op
        \\.end
    );
    try std.testing.expectError(error.NonFiniteParameter, build(sa.allocator(), pa.allocator(), nl));
}

test "an N card on a psp103va model runs the built-in PSP 103, as ngspice with OSDI does" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try parse(pa.allocator(),
        \\osdi module name
        \\.model pch psp103va type=-1
        \\vd d 0 -1
        \\np d d 0 0 pch w=1u l=1u
        \\.op
        \\.end
    );
    var prepared = try build(sa.allocator(), pa.allocator(), nl);
    defer prepared.deinit();
    const psp = device.Library.builtin("psp103");
    try std.testing.expect(std.mem.indexOfScalar(@TypeOf(psp), prepared.circuit.batch_types, psp) != null);
}

test "PSP 103 cards run the QS device unless they set SWNQS" {
    const cases = .{
        .{ "", "psp103" },
        .{ " swnqs=0", "psp103" },
        .{ " swnqs=1", "psp103_nqs" },
    };
    inline for (cases) |case| {
        var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer sa.deinit();
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const nl = try parse(pa.allocator(), "psp nqs pick\n.model nch nmos level=1040" ++ case[0] ++
            "\nvd d 0 1\nm1 d d 0 0 nch w=1u l=1u\n.op\n.end\n");
        var prepared = try build(sa.allocator(), pa.allocator(), nl);
        defer prepared.deinit();
        const want = device.Library.builtin(case[1]);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(@TypeOf(want), prepared.circuit.batch_types, &.{want}));
    }
}

test "a diode card builds diode_t exactly on ngspice's self-heating condition" {
    // diodefs.h:31-33: a third node, the `thermal` flag (the word, or
    // thermal=1 on the model card, measured on ngspice 44.2) and a given,
    // non-zero rth0; off it ngspice runs the card isothermal. Red before
    // diode_t: every card here with a third node or the flag was refused
    // (UnsupportedSelfHeating).
    const cases = .{
        .{ "d1 a 0 tj dm thermal", " rth0=200", "diode_t" },
        .{ "d1 a 0 tj dm", " rth0=200 thermal=1", "diode_t" },
        .{ "d1 a 0 tj dm", " rth0=200", "diode" },
        .{ "d1 a 0 dm thermal", " rth0=200", "diode" },
        .{ "d1 a 0 tj dm thermal", "", "diode" },
        .{ "d1 a 0 tj dm thermal", " rth0=0", "diode" },
        .{ "d1 a 0 dm", " rth0=200", "diode" },
    };
    inline for (cases) |case| {
        var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer sa.deinit();
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const nl = try parse(pa.allocator(), "diode pick\n.model dm d is=1e-14" ++ case[1] ++
            "\nva a 0 0.7\nrtj tj 0 100\n" ++ case[0] ++ "\n.op\n.end\n");
        var prepared = try build(sa.allocator(), pa.allocator(), nl);
        defer prepared.deinit();
        const want = device.Library.builtin(case[2]);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(@TypeOf(want), prepared.circuit.batch_types, &.{want}));
    }
}

test ".save narrows the outputs; .save all keeps them" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const deck =
        \\save
        \\V1 in 0 1
        \\R1 in Mid 1k
        \\R2 mid out 1k
        \\R3 out 0 1k
        \\.save v(OUT) i(v1) v(nowhere)
        \\
    ;
    const nl = try parse(parse_arena.allocator(), deck ++ ".op\n.end\n");
    var saved = try build(session.allocator(), parse_arena.allocator(), nl);
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 2), saved.deck.probe_labels.len);
    try std.testing.expectEqualStrings("i(v1)", saved.deck.probe_labels[0]);
    try std.testing.expectEqualStrings("v(out)", saved.deck.probe_labels[1]);
    const all = try parse(parse_arena.allocator(), deck ++ ".save all\n.op\n.end\n");
    var every = try build(session.allocator(), parse_arena.allocator(), all);
    defer every.deinit();
    try std.testing.expectEqual(@as(usize, 4), every.deck.probe_labels.len);
}

test "prepared metadata and query identities outlive parse storage" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const source = try parse_arena.allocator().dupe(u8,
        \\prepared lifetime
        \\va unused 0 dc 2
        \\vb in 0 dc 10 ac 1
        \\r1 in 2 1k ac=2k
        \\r2 2 0 3k
        \\.options temp=85 reltol=1e-5 method=gear maxord=1
        \\.ic v(2)=0.25
        \\.tf v(2) vb
        \\.noise v(2) vb dec 2 10 100
        \\.sens v(2)
        \\.tran 1u 10u uic
        \\.end
    );
    const nl = try parse(parse_arena.allocator(), source);
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    _ = parse_arena.reset(.free_all);
    try std.testing.expectEqualStrings("prepared lifetime", prepared.deck.title);
    try std.testing.expectEqual(@as(usize, 5), prepared.deck.queries.len);
    try std.testing.expectEqual(@as(f64, 85), prepared.deck.deck_temp.?);
    try std.testing.expectEqual(@as(f64, 1e-5), prepared.deck.deck_tol.reltol);
    try std.testing.expectEqualStrings("i(va)", prepared.deck.probe_labels[0]);
    try std.testing.expectEqualStrings("v(2)", prepared.deck.probe_labels[prepared.deck.probe_labels.len - 1]);
    const node = prepared.deck.probes[prepared.deck.probes.len - 1];
    try std.testing.expectEqual(node, prepared.deck.queries[0].tf.output_node);
    try std.testing.expectEqual(prepared.deck.probes[1], prepared.deck.queries[0].tf.input_branch.?);
    try std.testing.expectEqual(node, prepared.deck.queries[1].noise.out_node);
    try std.testing.expect(!prepared.deck.queries[1].noise.integrated);
    try std.testing.expect(prepared.deck.queries[2].noise.integrated);
    try std.testing.expectEqualStrings("r1", prepared.deck.queries[3].sens.card_names.get(device.Library.builtin("resistor"), 0).?);
    try std.testing.expectEqual(requests.Method.backward_euler, prepared.deck.queries[4].tran.method);
    try std.testing.expect(prepared.deck.queries[4].tran.uic);
    try std.testing.expectEqual(@as(usize, 1), prepared.deck.ic.len);
    try std.testing.expectEqual(node, prepared.deck.ic[0].node);
    try std.testing.expectEqual(@as(f64, 0.25), prepared.deck.ic[0].value);
    try std.testing.expectEqual(@as(usize, 1), prepared.deck.ac_overrides.len);
    try std.testing.expectEqual(device.Library.builtin("resistor"), prepared.deck.ac_overrides[0].type);
    try std.testing.expectEqualStrings("r", prepared.deck.ac_overrides[0].param_name);
    try std.testing.expectEqual(@as(u32, 0), prepared.deck.ac_overrides[0].index);
    try std.testing.expectEqual(@as(f64, 2000), prepared.deck.ac_overrides[0].value);

    const appended = try resolveQueries(session.allocator(), &prepared,
        \\.tf v(2) vb
        \\.dc vb 0 1 0.1
        \\.noise v(2) vb dec 2 10 100
        \\.tran 1u 10u
        \\.sens v(2)
    );
    try std.testing.expectEqual(@as(usize, 6), appended.len);
    try std.testing.expectEqual(node, appended[0].tf.output_node);
    try std.testing.expectEqual(prepared.deck.probes[1], appended[0].tf.input_branch.?);
    try std.testing.expectEqual(device.Library.builtin("vsource"), appended[1].dc.target.device.type);
    try std.testing.expectEqual(@as(u32, 1), appended[1].dc.target.device.index);
    try std.testing.expectEqual(node, appended[2].noise.out_node);
    try std.testing.expect(appended[3].noise.integrated);
    try std.testing.expectEqual(requests.Method.backward_euler, appended[4].tran.method);
    try std.testing.expectEqual(prepared.deck.deck_tol.reltol, appended[4].tran.tol.reltol);
    try std.testing.expectEqualStrings("r1", appended[5].sens.card_names.get(device.Library.builtin("resistor"), 0).?);
    for ([_][]const u8{
        "r3 2 0 1k",            ".model rm r(r=1k)", ".hdl \"part.va\"", ".include \"part.cir\"",
        ".param p=1",           ".options temp=12",  ".temp 12",         ".subckt unused a b\n.ends",
        ".op\n.end\nr3 2 0 1k",
    }) |text| try std.testing.expectError(error.UnsupportedDirectiveMutation, resolveQueries(session.allocator(), &prepared, text));
    try std.testing.expectError(error.InvalidAnalysisArguments, resolveQueries(session.allocator(), &prepared, "* nothing\n"));
    try std.testing.expectError(error.AnalysisNodeNotFound, resolveQueries(session.allocator(), &prepared, ".tf v(missing) vb"));
    try std.testing.expectError(error.UnsupportedAnalysisOutput, resolveQueries(session.allocator(), &prepared, ".tf v(in, 2) vb"));
    try std.testing.expectEqual(@as(usize, 5), prepared.deck.queries.len);
}

test "a card query validation would refuse fails at the card" {
    for ([_][]const u8{ ".ac dec 10 1 1e308", ".tran 1e-310 1u", ".dc v1 0 1 1e-10", ".pss 1e-310 64" }) |text| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        const a = session.allocator();
        const nl = try parse(a, try std.fmt.allocPrint(a, "x2\nv1 in 0 1\nr1 in out 1k\nc1 out 0 1n\n{s}\n.end\n", .{text}));
        try std.testing.expectError(error.InvalidAnalysisArguments, build(a, a, nl));
    }
}

test "v(a,b) outputs and noise inputs are read, or refused, on every card (#57)" {
    const deck = "diff\nv1 a 0 sin(0 1 1k)\nr1 a b 1k\nr2 b 0 1k\n.tran 1u 2m\n{s}\n.end\n";
    for ([_]struct { []const u8, ?anyerror }{
        .{ ".four 1k v(a,b)", null },
        .{ ".pss v(a,b) 1k", error.UnsupportedAnalysisOutput },
        .{ ".hb v(a,b) 1k", error.UnsupportedAnalysisOutput },
        .{ ".pnoise v(a) nosuch dec 10 1 1k 1k", error.AnalysisSourceNotFound },
    }) |case| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        const a = session.allocator();
        const nl = try parse(a, try std.fmt.allocPrint(a, deck, .{case[0]}));
        if (case[1]) |err| {
            try std.testing.expectError(err, build(a, a, nl));
            continue;
        }
        var prepared = try build(a, a, nl);
        defer prepared.deinit();
        for (prepared.deck.queries) |q| if (q == .four) try std.testing.expect(q.four.output_neg != 0);
    }
}

test ".dcxf keeps a V card an F or H senses" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    const nl = try parse(session.allocator(),
        \\sensed
        \\v1 in 0 1
        \\vs in a 0
        \\r1 a 0 1k
        \\f1 0 out vs 2
        \\r2 out 0 1k
        \\i1 0 out 1m
        \\.dcxf v(out)
        \\.end
    );
    var prepared = try build(session.allocator(), session.allocator(), nl);
    defer prepared.deinit();
    const sources = prepared.deck.queries[0].dcxf.sources;
    try std.testing.expectEqual(@as(usize, 3), sources.len);
    try std.testing.expectEqualStrings("v1", sources[0].name);
    try std.testing.expectEqualStrings("vs", sources[1].name);
    try std.testing.expectEqualStrings("i1", sources[2].name);
}

test "a numeric reference node is that node, not ground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try parse(a,
        \\numeric reference
        \\vb in 0 dc 10 ac 1
        \\r1 in 2 1k
        \\r2 2 0 3k
        \\.tf v(in, 2) vb
        \\.noise v(in, 2) vb dec 2 10 100
        \\.end
    );
    var prepared = try build(a, a, nl);
    defer prepared.deinit();
    const node = prepared.deck.probes[prepared.deck.probes.len - 1];
    try std.testing.expectEqualStrings("v(2)", prepared.deck.probe_labels[prepared.deck.probe_labels.len - 1]);
    try std.testing.expectEqual(node, prepared.deck.queries[0].tf.output_neg);
    try std.testing.expectEqual(node, prepared.deck.queries[1].noise.out_neg);
}

test "cards without an output measure the last net the deck introduces, whatever the BBD order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try parse(a,
        \\bbd output
        \\.subckt rc p q
        \\r1 p m 1k
        \\c1 m q 1n
        \\.ends
        \\v1 in 0 dc 0 ac 1 distof1 0.01
        \\x1 in mid rc
        \\x2 mid out rc
        \\r2 out 0 1k
        \\.disto dec 2 10 100
        \\.pac 1k dec 2 10 100
        \\.end
    );
    var prepared = try build(a, a, nl);
    defer prepared.deinit();
    const deck = prepared.deck;
    // x2's internal net comes last in the deck; the permutation puts v(mid) last among the probes.
    try std.testing.expectEqualStrings("x2.m", prepared.circuit.nodeName(deck.output_node));
    try std.testing.expectEqualStrings("v(mid)", deck.probe_labels[deck.probe_labels.len - 1]);
    try std.testing.expectEqual(deck.output_node, deck.queries[0].disto.output_node);
    try std.testing.expectEqual(deck.output_node, deck.queries[3].pac.out_node);
}

test "selected unresolved parameters fail while unused models stay inert" {
    inline for (.{
        ".model nm nmos(level=1 tox={missing})\nm1 out in 0 0 nm\n",
        "r1 out 0 r=0*missing\n",
        // A value naming no parameter and no model, not the 1 mOhm default.
        "r1 out 0 missing\n",
    }) |body| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse_arena.deinit();
        const nl = try parse(parse_arena.allocator(), "unresolved numeric parameter\n.param dummy=1\nvin in 0 dc 1\nrload in out 1k\n" ++ body ++ ".op\n.end\n");
        try std.testing.expectError(error.UnresolvedParameter, build(session.allocator(), parse_arena.allocator(), nl));
    }
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const nl = try parse(parse_arena.allocator(),
        \\unused model
        \\.model unused nmos(level=1 tox={missing})
        \\vin in 0 dc 1
        \\r1 in out 1k
        \\r2 out 0 1k
        \\.op
        \\.end
    );
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), prepared.deck.queries.len);
}

test "prepared bindings retain model fields and exclude runtime state from parameter collection" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const nl = try parse(parse_arena.allocator(),
        \\escaped parameter name
        \\.model nm nmos(level=54 pub=1.25e-18)
        \\vd drain 0 1
        \\vg gate 0 1.2
        \\m1 drain gate 0 0 nm l=1u w=10u
        \\r1 drain gate 1k
        \\r2 gate 0 3k
        \\.op
        \\.end
    );
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    _ = parse_arena.reset(.free_all);
    const refs = try @import("../variants.zig").collect(session.allocator(), &prepared.circuit);
    var saw_pub = false;
    var resistors: u32 = 0;
    for (0..refs.len) |i| {
        const ref = refs.at(i);
        if (std.mem.eql(u8, ref.param_name, "pubZ")) {
            // 125 * 1e-20: ngspice INPevaluate bits for `1.25e-18`.
            try std.testing.expectEqual(@as(f64, 125) * @as(f64, 1e-20), ref.get());
            saw_pub = true;
        }
        if (ref.type != device.Library.builtin("resistor")) continue;
        if (ref.is_instance) {
            try std.testing.expectEqualStrings("mfactor", ref.param_name);
            try std.testing.expect(!ref.primary);
        }
        if (std.mem.eql(u8, ref.param_name, "r")) {
            try std.testing.expect(ref.primary);
            resistors += 1;
        }
    }
    try std.testing.expect(saw_pub);
    try std.testing.expectEqual(@as(u32, 2), resistors);
}

test "selected model integer fields and levels reject out-of-range values" {
    for ([_][]const u8{ "level=-1", "level=65536", "level=54 tnoimod=1e40" }) |parameters| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse_arena.deinit();
        const source = try std.fmt.allocPrint(parse_arena.allocator(), "invalid integer parameter\n.model nm nmos({s})\nvd drain 0 1\nvg gate 0 1\nm1 drain gate 0 0 nm\n.op\n.end\n", .{parameters});
        const nl = try parse(parse_arena.allocator(), source);
        try std.testing.expectError(error.ParameterOutOfRange, build(session.allocator(), parse_arena.allocator(), nl));
    }
}

test "behavioral sources the tape cannot express are rejected, not opened" {
    // An unknown function is refused as the card is read (src/tests/
    // unknown_functions.zig).
    inline for (.{ "v=v(out)+i(r1)", "i=v(out)*x", "i=agauss(v(out),1,1)", "i=min(v(a))" }) |output| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try parse(a, "behavioral source\nb1 out 0 " ++ output ++ "\nr1 out 0 1k\nr2 a 0 1k\nr3 b 0 1k\nr4 c 0 1\nr5 d 0 1\nr6 e 0 1\nr7 f 0 1\nr8 g 0 1\nr9 h 0 1\n.end\n");
        try std.testing.expectError(error.UnsupportedBsourceExpression, build(a, a, nl));
    }
}

test "input preparation retains bytes and origin after caller storage changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = "retained input\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n".*;
    var origin = "Models/Deck.cir".*;
    const prepared = try prepare(std.testing.io, arena.allocator(), .{
        .bytes = .{ .data = &source, .origin = &origin },
    });
    @memset(&source, 'x');
    @memset(&origin, 'x');
    try std.testing.expectEqual(@as(u32, 2), prepared.deviceCount());
    try std.testing.expectEqualStrings("retained input", prepared.deck.title);
}

test "input preparation resolves file includes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "res.inc", .data = "R1 out 0 1k\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "input.cir",
        .data = "included input\n.include res.inc\nV1 out 0 1\n.op\n.end\n",
    });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/input.cir", .{tmp.sub_path});
    const prepared = try prepare(io, a, .{ .file = path });
    try std.testing.expectEqual(@as(u32, 2), prepared.deviceCount());
    const from_bytes = try prepare(io, a, .{
        .bytes = .{ .data = "byte input\n.include res.inc\nV1 out 0 1\n.end\n", .origin = path },
    });
    try std.testing.expectEqual(@as(u32, 2), from_bytes.deviceCount());
}

test "one binder: a runtime-registered device binds a card exactly as the same model built in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    // The built-in resistor's own vtable, registered the way `Library.load`
    // registers a dlopen'd one: its cards then take the runtime-device route
    // (loadedType, bind_model, derive, collapse). Only the dlopen step is
    // left out; a real .so of models/*.va is not a fixture yet because VerA's
    // library emit declares `h` twice for models with hoisted temporaries.
    const loaded = try lib.register("resistor_rt", device.vtable("resistor"), false);
    try std.testing.expect(loaded != device.Library.builtin("resistor"));

    // One card, bound twice: R1 through the built-in resistor, N1 through the
    // loaded one (`.model` kind names the module).
    const pairs = "r=2k tc1=1e-3 tc2=1e-6 dtemp=5";
    const nl = try netlist.parse(a, try std.fmt.allocPrint(a,
        \\one binder
        \\V1 a 0 1
        \\R1 a 0 {s}
        \\N1 a 0 rloaded
        \\.model rloaded resistor_rt {s}
        \\.end
    , .{ pairs, pairs }));
    var prepared = try input.build(&lib, a, a, nl);
    defer prepared.deinit();

    var refs: [2]std.ArrayList(device.abi.ParamRef) = .{ .empty, .empty };
    for (prepared.circuit.batches, prepared.circuit.batch_types) |batch, t| {
        const side: usize = if (t == device.Library.builtin("resistor")) 0 else if (t == loaded) 1 else continue;
        try batch.hooks.collect_params(batch.ctx, a, &refs[side]).unwrap();
    }
    try std.testing.expect(refs[0].items.len > 0);
    try std.testing.expectEqual(refs[0].items.len, refs[1].items.len);
    for (refs[0].items, refs[1].items) |built_in, runtime| {
        try std.testing.expectEqualStrings(built_in.param_name, runtime.param_name);
        try std.testing.expectEqual(built_in.get(), runtime.get());
    }
}

/// A MOSRA deck around one BSIM3 NMOS; `tail` holds the `.mosra`,
/// analysis and any extra cards.
fn mosraDeck(arena: std.mem.Allocator, model: []const u8, tail: []const u8) !netlist.Netlist {
    return netlist.parse(arena, try std.fmt.allocPrint(arena,
        \\mosra plan
        \\vd d 0 1.5
        \\vg g 0 1.2
        \\m1 d g 0 0 n3 w=10u l=0.18u
        \\.model n3 nmos(level=49 version=3.3)
        \\{s}
        \\.appendmodel nra mosra n3 nmos
        \\{s}
        \\.end
    , .{ model, tail }));
}

test "a .mosra plans one aged row per reliability time, the total last" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const model = ".model nra mosra level=1 tit0=1e-4 tn=0.25";
    const nl = try mosraDeck(pa.allocator(), model, ".mosra reltotaltime=10 relstep=3 simmode=2\n.tran 1n 10n\n.op");
    var prepared = try build(sa.allocator(), pa.allocator(), nl);
    defer prepared.deinit();
    const m = prepared.deck.mosra.?;
    try std.testing.expectEqualSlices(f64, &.{ 3, 6, 9, 10 }, m.rel_times);
    try std.testing.expectApproxEqRel(@as(f64, 10e-9), m.tran.t_stop, 1e-12);
    try std.testing.expectEqual(@as(usize, 1), m.names.len);
    try std.testing.expectEqual(@as(u32, 4), prepared.deck.variants.count());
    try std.testing.expectEqualStrings("reltime=3", prepared.deck.variants.labels[0]);
    // Both cards fresh, then once per aged row.
    try std.testing.expectEqual(@as(usize, 10), prepared.deck.queries.len);

    // SimMode 0 reports the degradation only: no aged rows.
    const fresh = try mosraDeck(pa.allocator(), model, ".mosra reltotaltime=10 simmode=0\n.tran 1n 10n");
    var degradation = try build(sa.allocator(), pa.allocator(), fresh);
    defer degradation.deinit();
    try std.testing.expectEqualSlices(f64, &.{10}, degradation.deck.mosra.?.rel_times);
    try std.testing.expectEqual(@as(u32, 0), degradation.deck.variants.count());

    for ([_][2][]const u8{
        .{ model, ".mosra reltotaltime=10\n.op" }, // nothing to stress the devices
        .{ "", ".mosra reltotaltime=10\n.tran 1n 10n" }, // no MOSRA card for the source
        .{ ".model nra nmos level=1", ".mosra reltotaltime=10\n.tran 1n 10n" }, // the source is no MOSRA model
        .{ ".model nra mosra level=2", ".mosra reltotaltime=10\n.tran 1n 10n" },
        .{ model, ".mosra reltotaltime=10\n.tran 1n 10n\n.param p=1\n.step param p list 1 2" },
        .{ model, ".mosra reltotaltime=1e9 relstep=1e3\n.tran 1n 10n" }, // past 10000 times
    }) |case| {
        const bad = try mosraDeck(pa.allocator(), case[0], case[1]);
        try std.testing.expectError(error.UnsupportedCard, build(sa.allocator(), pa.allocator(), bad));
    }
}

/// Reads, builds and frees `src` with every table on arenas over `gpa`.
fn prepareAndBuild(gpa: std.mem.Allocator, lib: *const device.Library, src: []const u8) !void {
    var session = std.heap.ArenaAllocator.init(gpa);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();
    const nl = try input.prepare(std.testing.io, parse_arena.allocator(), .{ .bytes = .{ .data = src, .origin = "sweep.cir" } }, &.{}, .{});
    var prepared = try input.build(lib, session.allocator(), parse_arena.allocator(), nl);
    prepared.deinit();
}

test "every allocation in prepare and build can fail without a leak" {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    // Subcircuits (a BBD permutation), a port, a sensed source, a B tape, a
    // `.step` plan and three analyses: each owns allocations of its own.
    const src =
        \\alloc sweep
        \\.subckt rc p q
        \\r1 p m 1k
        \\c1 m q 1p
        \\.ends
        \\.param rv=1k
        \\V1 in 0 DC 1 AC 1 portnum 1
        \\x1 in mid rc
        \\x2 mid 0 rc
        \\R2 mid 0 {rv}
        \\L1 mid out 1u
        \\F1 out 0 V1 2
        \\B1 b 0 v=v(in)*2
        \\Rb b 0 1k
        \\.step param rv list 1k 2k
        \\.op
        \\.ac dec 2 1 1k
        \\.tran 1n 10n
        \\.end
        \\
    ;
    try prepareAndBuild(std.testing.allocator, &lib, src);
    try std.testing.checkAllAllocationFailures(core.testing.fixed_growth, prepareAndBuild, .{ &lib, src });
}
