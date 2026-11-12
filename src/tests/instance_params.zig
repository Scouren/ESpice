//! Instance parameters ngspice 44.2 takes on a device card. Oracles:
//! metamorphic relations, each pair solved at the OP and one AC point.
//! `dtemp=30` at `.temp 27` is the circuit at `.temp 57`. A given
//! `temp=80` (MESA: `ts=80 td=80`) runs the device at 80 degC, or at 110
//! where ngspice adds dtemp to it (HiSIM2, hsm2temp.c:539-544); each kind's
//! rule was measured on ngspice 44.2 and 45 and agrees with its *temp.c,
//! except VBIC, whose 44.2 and 45 solve the OP at 110 and the AC at 140, so
//! its row takes vbictemp.c:39-41's later rule, temp wins. The
//! reference temperatures must solve apart from each other, so a device
//! that ignores temperature fails instead of passing vacuously. VBIC
//! `area=2` is two parallel copies (vbicload.c:170 scales every current
//! and charge by area*m). BSIM1 `ad`/`pd` at zero junction bias are a
//! cj*ad + cjsw*pd capacitor (b1ld.c:439-442). Every kind ngspice gives
//! `dtemp` has a row here or, for the R, C and L cards, in tempco.zig; a
//! known gap is a named marker that must fail.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;
const Allocator = std.mem.Allocator;

/// How a given `temp` combines with `dtemp`.
const Rule = enum {
    /// temp replaces the circuit temperature and dtemp is ignored.
    wins,
    /// temp replaces the circuit temperature and dtemp still adds.
    adds,
};

const Row = struct {
    /// The kind, as failures name it.
    kind: []const u8,
    /// A deck body whose device card carries `$` where its fields go.
    body: []const u8,
    /// The kind's own temperature at 80 degC; null when ngspice has none.
    over: ?[]const u8 = "temp=80",
    rule: Rule = .wins,
    /// Why the row fails today. A row with a gap must fail.
    gap: ?[]const u8 = null,
};

/// A gate or base driven through 1k with an AC source, the probes the
/// three-terminal rows share.
const gate = "vg a 0 dc -0.5 ac 1\nrg a g 1k\n";
const mos_gate = "vd d 0 dc 3\nvg a 0 dc 1.5 ac 1\nrg a g 1k\n";

const rows = [_]Row{
    // ngspice 44.2: `temp=80 dtemp=30` at .temp 27 gives i(v1) = -1.53 mA,
    // as .temp 80 does (asrcpar.c:49-52 degC, asrctemp.c:23-33 temp wins).
    .{ .kind = "b", .body = "v1 a 0 dc 1 ac 1\nb1 a 0 i={v(a)*1m} tc1=0.01$\n" },
    .{ .kind = "d", .body = "v1 a 0 dc 0.7 ac 1\nr1 a k 100\nd1 k 0 dm$\n.model dm d is=1e-14 cjo=1p rs=1\n" },
    .{
        .kind = "q gummel-poon",
        .body = "vc c 0 dc 2\nvb a 0 dc 0.8 ac 1\nrb a b 10k\nq1 c b 0 qn$\n.model qn npn is=1e-16 bf=100 vaf=50 cje=1p cjc=0.5p rb=10 xtb=1.5\n",
    },
    .{
        .kind = "q vbic",
        .body = "vc c 0 dc 2\nvb a 0 dc 0.8 ac 1\nrb a b 10k\nq1 c b 0 0 qv$\n.model qv npn level=4 is=1e-16 cje=1p cjc=0.5p rbx=10 rcx=10 re=1\n",
    },
    .{ .kind = "j", .body = "vd d 0 dc 5\n" ++ gate ++ "j1 d g 0 jm$\n.model jm njf vto=-2 beta=1e-3 lambda=0.01 is=1e-14 cgs=1p cgd=1p vtotc=-2m betatce=-0.5\n" },
    .{ .kind = "j level 2", .body = "vd d 0 dc 5\n" ++ gate ++ "j1 d g 0 jm$\n.model jm njf level=2 vto=-2 beta=1e-3 lambda=0.01 is=1e-14 cgs=1p cgd=1p\n" },
    .{ .kind = "m level 1", .body = mos_gate ++ "m1 d g 0 0 nm w=10u l=1u ad=10p as=10p$\n.model nm nmos level=1 vto=0.7 kp=50u gamma=0.5 phi=0.6 lambda=0.01 cbd=1f cbs=1f cgso=1n cgdo=1n is=1e-14\n" },
    .{ .kind = "m level 2", .body = mos_gate ++ "m1 d g 0 0 nm w=10u l=1u$\n.model nm nmos level=2 vto=0.7 kp=50u gamma=0.5 phi=0.6 lambda=0.01 tox=20n cgso=1n cgdo=1n\n" },
    .{ .kind = "m level 3", .body = mos_gate ++ "m1 d g 0 0 nm w=10u l=1u$\n.model nm nmos level=3 vto=0.7 kp=50u gamma=0.5 phi=0.6 tox=20n cgso=1n cgdo=1n\n" },
    .{ .kind = "m level 6", .body = mos_gate ++ "m1 d g 0 0 nm w=10u l=1u$\n.model nm nmos level=6 vto=0.7 kv=2 nv=1.2 kc=5e-5 nc=1.2 gamma=0.5 phi=0.6 tox=20n cgso=1n cgdo=1n\n" },
    .{ .kind = "m level 9", .body = mos_gate ++ "m1 d g 0 0 nm w=10u l=1u$\n.model nm nmos level=9 vto=0.7 kp=50u gamma=0.5 phi=0.6 tox=20n cgso=1n cgdo=1n\n" },
    .{ .kind = "m vdmos", .body = "vd d 0 dc 3\nvg a 0 dc 3 ac 1\nrg a g 1k\nm1 d g 0 vd$\n.model vd vdmos vto=2 kp=1 rd=0.1 cgs=1n cgdmin=0.1n cgdmax=1n\n" },
    .{
        .kind = "m hisim2",
        .body = "vd d 0 dc 1\nvg a 0 dc 0.8 ac 1\nrg a g 1k\nm1 d g 0 0 nm w=1u l=0.1u$\n.model nm nmos level=68\n",
        .rule = .adds,
    },
    .{
        .kind = "m hisimhv",
        .body = "vd d 0 dc 5\nvg a 0 dc 3 ac 1\nrg a g 1k\nm1 d g 0 0 nm w=10u l=10u$\n.model nm nmos level=73 version=2.20 tnom=27 tox=10e-9\n",
        .over = null,
    },
    .{
        .kind = "z mesa",
        .body = "vd d 0 dc 1\n" ++ gate ++ "z1 d g 0 mm l=1u w=20u$\n.model mm nmf level=2 rd=31 rs=31\n",
        .over = "ts=80 td=80",
    },
    .{ .kind = "z hfet1", .body = "vd d 0 dc 1\nvg a 0 dc 0.3 ac 1\nrg a g 1k\nz1 d g 0 hm l=1u w=20u$\n.model hm nhfet level=5\n" },
    .{ .kind = "z hfet2", .body = "vd d 0 dc 1\nvg a 0 dc 0.3 ac 1\nrg a g 1k\nz1 d g 0 hm l=1u w=20u$\n.model hm nhfet level=6\n" },
};

/// The circuit temperatures the relations land on, degC.
const temps = [_][]const u8{ "27", "57", "80", "110" };
const at_57 = 1;

/// Every deck's Newton tolerances, tightened so a relation holds far below
/// a one-degree error; `spread` reads the same three numbers.
const options = ".options reltol=1e-6 vntol=1e-9 abstol=1e-15\n";
const reltol = 1e-6;
const vntol = 1e-9;
const abstol = 1e-15;
/// Two solutions agree within ten times Newton's acceptance test and are
/// apart beyond a hundred times it.
const agree = 10;
const apart = 100;

// ---- private ----

/// True when `row`'s device takes dtemp, and its temperature override if it
/// has one, by the kind's rule.
fn holds(a: Allocator, row: Row) !bool {
    var refs: [temps.len]*api.Problem = undefined;
    var made: usize = 0;
    defer for (refs[0..made]) |p| p.deinit();
    for (temps, &refs) |temp, *r| {
        r.* = try decks.solve(try text(a, row.body, "", temp));
        made += 1;
    }
    if (!try lands(a, row, "dtemp=30", at_57, &refs)) return false;
    const over = row.over orelse return true;
    const want: usize = switch (row.rule) {
        .wins => 2,
        .adds => 3,
    };
    return lands(a, row, try std.mem.concat(a, u8, &.{ over, " dtemp=30" }), want, &refs);
}

/// True when the device with `fields` at `.temp 27` solves as the circuit
/// at `temps[want]` and apart from it at every other reference.
fn lands(a: Allocator, row: Row, fields: []const u8, want: usize, refs: []const *api.Problem) !bool {
    const p = try decks.solve(try text(a, row.body, fields, temps[0]));
    defer p.deinit();
    for (refs, temps, 0..) |r, temp, i| {
        const s = try spread(p, r);
        if (if (i == want) s <= agree else s > apart) continue;
        std.debug.print("{s}: `{s}` at .temp 27 is {d:.1} Newton tolerances from .temp {s}\n", .{ row.kind, fields, s, temp });
        return false;
    }
    return true;
}

/// `body` with `fields` in place of `$`, run at `.temp temp`.
fn text(a: Allocator, body: []const u8, fields: []const u8, temp: []const u8) ![]const u8 {
    const placed = try std.mem.replaceOwned(u8, a, body, "$", if (fields.len == 0) "" else try std.mem.concat(a, u8, &.{ " ", fields }));
    return std.mem.concat(a, u8, &.{ "instance temperature\n", options, placed, ".temp ", temp, "\n.op\n.ac lin 1 1meg 1meg\n.end\n" });
}

/// The largest gap between two solves of one topology, over every column
/// of the OP and the AC point, in units of Newton's acceptance test:
/// `reltol·max|x| + vntol` on a voltage, `+ abstol` on a current, on the
/// modulus of a complex value.
fn spread(p: *api.Problem, q: *api.Problem) !f64 {
    var worst: f64 = 0;
    var compared: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if (!(try p.query_info(id)).requested) continue;
        const rp = try p.result(id);
        const rq = try q.result(id);
        std.debug.assert(rp.npoints == 1 and rq.npoints == 1);
        std.debug.assert(rp.varnames.len == rq.varnames.len);
        const w: usize = if (rp.is_complex) 2 else 1;
        for (rp.varnames, rq.varnames, 0..) |name, other, c| {
            std.debug.assert(std.mem.eql(u8, name, other));
            worst = @max(worst, gap(name, rp.data[c * w ..][0..w], rq.data[c * w ..][0..w]));
        }
        compared += 1;
    }
    // The OP and the AC point, both requested.
    try t.expectEqual(@as(usize, 2), compared);
    return worst;
}

/// |x - y| over Newton's acceptance test at max(|x|, |y|).
fn gap(name: []const u8, x: []const f64, y: []const f64) f64 {
    var diff: f64 = 0;
    var mx: f64 = 0;
    var my: f64 = 0;
    for (x, y) |u, v| {
        diff += (u - v) * (u - v);
        mx += u * u;
        my += v * v;
    }
    const floor: f64 = if (name[0] == 'v') vntol else abstol;
    return @sqrt(diff) / (reltol * @sqrt(@max(mx, my)) + floor);
}

/// The worst `gap` of the named `probes` between two solves.
fn probeSpread(p: *api.Problem, q: *api.Problem, probes: []const []const u8) !f64 {
    var worst: f64 = 0;
    var compared: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if (!(try p.query_info(id)).requested) continue;
        const rp = try p.result(id);
        const rq = try q.result(id);
        std.debug.assert(rp.npoints == 1 and rq.npoints == 1);
        const w: usize = if (rp.is_complex) 2 else 1;
        for (probes) |name| {
            const x = rp.data[try decks.column(rp, name) * w ..][0..w];
            const y = rq.data[try decks.column(rq, name) * w ..][0..w];
            worst = @max(worst, gap(name, x, y));
        }
        compared += 1;
    }
    try t.expectEqual(@as(usize, 2), compared);
    return worst;
}

test "dtemp and temp set the device temperature of every kind ngspice gives them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The kinds whose verdict was wrong, so one run names every one.
    var wrong: std.ArrayList(u8) = .empty;
    for (rows) |row| {
        const ok = holds(a, row) catch |err| blk: {
            std.debug.print("{s}: {s}\n", .{ row.kind, @errorName(err) });
            break :blk false;
        };
        if (row.gap) |cause| {
            if (!ok) continue;
            std.debug.print("{s} passes: delete its gap marker ({s})\n", .{ row.kind, cause });
        } else if (ok) continue;
        try wrong.appendSlice(a, row.kind);
        try wrong.appendSlice(a, "; ");
    }
    try t.expectEqualStrings("", wrong.items);
}

test "BSIM4 refuses dtemp, as ngspice 44.2 and 45 do" {
    // Both releases print "unknown parameter (dtemp)" for this card; later
    // ngspice stores it (b4par.c:169-170) and no BSIM4 code reads it.
    const deck_text = "bsim4 dtemp\nvd d 0 1\nvg g 0 1\nm1 d g 0 0 nm w=1u l=0.1u dtemp=30\n.model nm nmos level=54\n.op\n.end\n";
    try t.expectError(error.UnknownParameter, api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck_text, .origin = "instance_params.cir" } } }));
}

test "VBIC area=2, by pair or by position, is two parallel copies" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = options ++ "vcc vc 0 dc 2\nvam vc c 0\nvb a 0 dc 0.8 ac 1\nrb a b 10k\n" ++
        ".model qv npn level=4 is=1e-16 ibei=1e-18 cje=1p cjc=0.5p cjep=0.2p rbx=10 rbi=5 rcx=10 rci=20 re=1 tf=10p\n";
    const tail = ".op\n.ac lin 1 1meg 1meg\n.end\n";
    const twice = try decks.solve(try std.mem.concat(a, u8, &.{ "two copies\n", fixture, "q1 c b 0 0 qv\nq2 c b 0 0 qv\n", tail }));
    defer twice.deinit();
    for ([_][]const u8{ "q1 c b 0 0 qv area=2\n", "q1 c b 0 0 qv 2\n" }) |card| {
        const once = try decks.solve(try std.mem.concat(a, u8, &.{ "area 2\n", fixture, card, tail }));
        defer once.deinit();
        const s = try probeSpread(once, twice, &.{ "v(b)", "i(vam)", "i(vb)" });
        if (s > agree) std.debug.print("{s}is {d:.1} Newton tolerances from two copies\n", .{ card, s });
        try t.expect(s <= agree);
    }
}

test "BSIM1 ad and pd at zero junction bias are a cj*ad + cjsw*pd capacitor" {
    // The drain junction at vbd = 0 charges at czbd + czbdsw = cj*ad +
    // cjsw*pd (b1ld.c:439-442): 1e-3 F/m^2 * 4e-12 m^2 + 1e-9 F/m * 8e-6 m
    // = 12 fF. Without ad/pd ngspice's junction has no area (b1set.c:
    // 284-290), so the explicit 12 fF stands in for it.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = options ++ "vd d 0 dc 0 ac 1\nvg g 0 dc 0\n" ++
        ".model nm nmos level=4 vfb=-0.3 phi=0.65 k1=0.5 k2=-0.1 eta=0.02 muz=600 u0=0.05 u1=0.01 tox=40n cj=1e-3 cjsw=1e-9 mj=0.5 mjsw=0.33 pb=0.8 pbsw=0.8\n";
    const tail = ".op\n.ac lin 1 1meg 1meg\n.end\n";
    const given = try decks.solve(try std.mem.concat(a, u8, &.{ "ad pd\n", fixture, "m1 d g 0 0 nm w=10u l=1u ad=4p pd=8u\n", tail }));
    defer given.deinit();
    const explicit = try decks.solve(try std.mem.concat(a, u8, &.{ "12 fF\n", fixture, "m1 d g 0 0 nm w=10u l=1u\ncx d 0 12f\n", tail }));
    defer explicit.deinit();
    const s = try probeSpread(given, explicit, &.{"i(vd)"});
    if (s > agree) std.debug.print("ad/pd are {d:.1} Newton tolerances from a 12 fF capacitor\n", .{s});
    try t.expect(s <= agree);
}
