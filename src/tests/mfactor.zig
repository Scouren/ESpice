//! `m=` on a card is that many parallel copies of the card. Oracle:
//! metamorphic, the same deck with the card written twice and no `m`,
//! solved to the same OP and 1 kHz AC point; and the refusal ngspice gives
//! the letters that take no `m` (inpcom.c:4253-4257, each device's
//! parameter table). Every card letter has a row, so a letter without a
//! verdict fails the build instead of going untested (the C and L cards
//! dropped `m` with no error before this table).
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;
const Allocator = std.mem.Allocator;
const solve = deck.solve;
const column = deck.column;

/// What `m=2` on a card of one letter must do.
const Verdict = union(enum) {
    /// Solve as two copies of `card`, in which `#` is the copy's name
    /// suffix and `$` its ` m=2` field; `probes` are columns of the
    /// fixture's nets and sources, never of the card itself.
    parallel: struct { fixture: []const u8, card: []const u8, probes: []const []const u8 },
    /// A deck body whose card carries `m=2`: refused with
    /// `error.UnsupportedCard`, never run without it.
    refused: []const u8,
    /// A letter no built-in element owns: refused with
    /// `error.UnsupportedDevice` whatever the card carries.
    no_element: []const u8,
};

const Row = struct { letter: u8, verdict: Verdict };

/// The source and ammeter most rows probe through: `v(d)` and `i(vam)`.
const drive = "vin in 0 dc 1 ac 1\nrs in a 1k\nvam a d 0\n";
/// The nets and sources the refused rows' cards connect to.
const bench = "vin in 0 dc 1\nrx x 0 1k\nry y 0 1k\n";
const through_d = &[_][]const u8{ "v(d)", "i(vam)" };
const at_drain = &[_][]const u8{ "v(dd)", "i(vam)", "i(vin)" };

const rows = [_]Row{
    .{ .letter = 'a', .verdict = .{ .no_element = "A9 x 0 m=2\n" } },
    .{ .letter = 'b', .verdict = .{ .parallel = .{ .fixture = drive ++ "rl d 0 1k\n", .card = "B# 0 d i={v(in)*1m}$\n", .probes = through_d } } },
    // asrcload.c multiplies a v= output by m: a voltage gain, not copies.
    .{ .letter = 'b', .verdict = .{ .refused = bench ++ "B9 x 0 v={v(in)} m=2\n" } },
    .{ .letter = 'c', .verdict = .{ .parallel = .{ .fixture = drive, .card = "C# d 0 1u$\n", .probes = through_d } } },
    // A value given as a pair takes m too; the raw pair once rebound over it.
    .{ .letter = 'c', .verdict = .{ .parallel = .{ .fixture = drive, .card = "C# d 0 c=1u$\n", .probes = through_d } } },
    .{ .letter = 'd', .verdict = .{ .parallel = .{
        .fixture = "vin in 0 dc 0.7 ac 1\nrs in a 100\nvam a d 0\n.model dm d is=1e-14 rs=10 cjo=1p m=0.4\n",
        .card = "D# d 0 dm$\n",
        .probes = through_d,
    } } },
    .{ .letter = 'e', .verdict = .{ .refused = bench ++ "E9 x 0 in 0 2 m=2\n" } },
    .{ .letter = 'f', .verdict = .{ .parallel = .{
        .fixture = "vin in 0 dc 1 ac 1\nrs in a 1k\nvam a 0 0\nrl d 0 1k\n",
        .card = "F# 0 d vam 2$\n",
        .probes = through_d,
    } } },
    .{ .letter = 'g', .verdict = .{ .parallel = .{ .fixture = drive ++ "rl d 0 1k\n", .card = "G# 0 d in 0 1m$\n", .probes = through_d } } },
    .{ .letter = 'h', .verdict = .{ .refused = bench ++ "vs in s 0\nrs s 0 1k\nH9 x 0 vs 1k m=2\n" } },
    .{ .letter = 'i', .verdict = .{ .parallel = .{ .fixture = "rl d 0 1k\n", .card = "I# 0 d dc 1m ac 1m$\n", .probes = &.{"v(d)"} } } },
    .{ .letter = 'j', .verdict = .{ .parallel = .{
        .fixture = "vdd vd 0 2\nvam vd d 0\nrd d dd 1k\nvin g 0 dc -0.5 ac 1\n.model jm njf vto=-1.5 beta=1e-3 cgs=1p cgd=1p\n",
        .card = "J# dd g 0 jm$\n",
        .probes = at_drain,
    } } },
    .{ .letter = 'k', .verdict = .{ .refused = bench ++ "L1 x 0 1m\nL2 y 0 1m\nK9 L1 L2 0.5 m=2\n" } },
    .{ .letter = 'l', .verdict = .{ .parallel = .{ .fixture = "vin in 0 dc 1 ac 1\nrs in a 100\nvam a d 0\n", .card = "L# d 0 1m$\n", .probes = through_d } } },
    .{ .letter = 'l', .verdict = .{ .parallel = .{ .fixture = "vin in 0 dc 1 ac 1\nrs in a 100\nvam a d 0\n", .card = "L# d 0 inductance=1m$\n", .probes = through_d } } },
    // MOS1 reads m as its own parameter, BSIM4 (no `m`) as the $mfactor.
    .{ .letter = 'm', .verdict = .{ .parallel = .{
        .fixture = "vdd vd 0 2\nvam vd d 0\nrd d dd 1k\nvin g 0 dc 1.2 ac 1\n.model n1 nmos level=1 vto=0.7 kp=1e-4 cgso=1n cgdo=1n cbd=1p cbs=1p\n",
        .card = "M# dd g 0 0 n1 w=10u l=1u$\n",
        .probes = at_drain,
    } } },
    .{ .letter = 'm', .verdict = .{ .parallel = .{
        .fixture = "vdd vd 0 1\nvam vd d 0\nrd d dd 1k\nvin g 0 dc 1 ac 1\n.model n4 nmos level=54\n",
        .card = "M# dd g 0 0 n4 w=1u l=100n$\n",
        .probes = at_drain,
    } } },
    .{ .letter = 'n', .verdict = .{ .no_element = "N9 x 0 m=2\n" } },
    .{ .letter = 'o', .verdict = .{ .refused = bench ++ "O9 x 0 y 0 lmod m=2\n.model lmod ltra r=1 l=1u c=1p len=1\n" } },
    .{ .letter = 'p', .verdict = .{ .refused = bench ++ "P9 x x2 0 y y2 0 pmod m=2\nr2 x2 0 50\nr3 y2 0 50\n.model pmod cpl r=1 0 1 l=1u 0.1u 1u c=1p 0 1p length=1\n" } },
    .{ .letter = 'q', .verdict = .{ .parallel = .{
        .fixture = "vcc vc 0 2\nvam vc c 0\nvin in 0 dc 0.75 ac 1\nrb in b 1k\n.model qn npn is=1e-16 bf=100 rb=10 cje=1p cjc=1p tf=1n\n",
        .card = "Q# c b 0 qn$\n",
        .probes = &.{ "v(b)", "i(vam)", "i(vin)" },
    } } },
    .{ .letter = 'r', .verdict = .{ .parallel = .{ .fixture = drive, .card = "R# d 0 1k$\n", .probes = through_d } } },
    .{ .letter = 'r', .verdict = .{ .parallel = .{ .fixture = drive, .card = "R# d 0 r=1k$\n", .probes = through_d } } },
    .{ .letter = 's', .verdict = .{ .refused = bench ++ "vc c 0 1\nS9 x 0 c 0 sw m=2\n.model sw sw vt=0.5 ron=1k roff=1g\n" } },
    .{ .letter = 't', .verdict = .{ .refused = bench ++ "T9 x 0 y 0 z0=50 td=1n m=2\n" } },
    .{ .letter = 'u', .verdict = .{ .refused = bench ++ "U9 x y 0 umod l=50u m=2\n.model umod urc rperl=10 cperl=1p\n" } },
    .{ .letter = 'v', .verdict = .{ .refused = bench ++ "V9 x 0 1 m=2\n" } },
    .{ .letter = 'w', .verdict = .{ .refused = bench ++ "vs in s 0\nrs s 0 1k\nW9 x 0 vs wsw m=2\n.model wsw csw it=1m ron=1 roff=1meg\n" } },
    .{ .letter = 'x', .verdict = .{ .parallel = .{
        .fixture = drive ++ ".subckt cell p\nr1 p 0 2k\nc1 p 0 1u\n.ends\n",
        .card = "X# d cell$\n",
        .probes = through_d,
    } } },
    .{ .letter = 'y', .verdict = .{ .refused = bench ++ "Y9 x 0 y 0 ymod m=2\n.model ymod txl r=1 l=1u g=0 c=1p length=1\n" } },
    .{ .letter = 'z', .verdict = .{ .parallel = .{
        .fixture = "vdd vd 0 2\nvam vd d 0\nrd d dd 1k\nvin g 0 dc -0.5 ac 1\n.model zm nmf level=1 vto=-2 beta=1e-3 cgs=1p cgd=1p\n",
        .card = "Z# dd g 0 zm$\n",
        .probes = at_drain,
    } } },
};

/// Every deck's Newton tolerances, tightened so the two decks agree far
/// below a wrong multiplier; `close` reads the same three numbers.
const options = ".options reltol=1e-6 vntol=1e-9 abstol=1e-15\n";
const reltol = 1e-6;
const vntol = 1e-9;
const abstol = 1e-15;

// ---- private ----

/// True when `card` with ` m=2` solves as two copies of it without, on
/// every column of `probes`, at the OP and at the AC point.
fn parallel(a: Allocator, fixture: []const u8, card: []const u8, probes: []const []const u8) !bool {
    const once = try std.mem.concat(a, u8, &.{ "m=2\n", options, fixture, try copy(a, card, "1", " m=2"), ".op\n.ac lin 1 1k 1k\n.end\n" });
    const twice = try std.mem.concat(a, u8, &.{ "two copies\n", options, fixture, try copy(a, card, "1", ""), try copy(a, card, "2", ""), ".op\n.ac lin 1 1k 1k\n.end\n" });
    const p = try solve(once);
    defer p.deinit();
    const q = try solve(twice);
    defer q.deinit();
    var compared: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if (!(try p.query_info(id)).requested) continue;
        const rp = try p.result(id);
        const rq = try q.result(id);
        std.debug.assert(rp.npoints == 1 and rq.npoints == 1);
        const w: usize = if (rp.is_complex) 2 else 1;
        for (probes) |name| {
            const x = rp.data[try column(rp, name) * w ..][0..w];
            const y = rq.data[try column(rq, name) * w ..][0..w];
            if (!close(name, x, y)) {
                std.debug.print("{s}: {s} {s} is {any} with m=2, {any} as two copies\n", .{ card, rp.plotname, name, x, y });
                return false;
            }
        }
        compared += 1;
    }
    // The OP and the AC point, both requested.
    try t.expectEqual(@as(usize, 2), compared);
    return true;
}

/// True when the deck `body` is refused with `err` before it runs.
fn refusedWith(a: Allocator, err: anyerror, body: []const u8) !bool {
    const text = try std.mem.concat(a, u8, &.{ "refusal\n", body, ".op\n.end\n" });
    const p = api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = text, .origin = "mfactor.cir" } } }) catch |got| {
        if (got == err) return true;
        std.debug.print("{s} instead of {s}: {s}", .{ @errorName(got), @errorName(err), text });
        return false;
    };
    p.deinit();
    std.debug.print("accepted, not {s}: {s}", .{ @errorName(err), text });
    return false;
}

/// `card` with `#` as the copy's name suffix and `$` as its `m` field.
fn copy(a: Allocator, card: []const u8, suffix: []const u8, m: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, card, "#", suffix), "$", m);
}

/// The two decks' solutions agree within ten times Newton's own acceptance
/// test, `reltol·max|x| + vntol` on a voltage and `+ abstol` on a current,
/// on the modulus of a complex value.
fn close(name: []const u8, x: []const f64, y: []const f64) bool {
    var diff: f64 = 0;
    var mx: f64 = 0;
    var my: f64 = 0;
    for (x, y) |u, v| {
        diff += (u - v) * (u - v);
        mx += u * u;
        my += v * v;
    }
    const floor: f64 = if (name[0] == 'v') vntol else abstol;
    return @sqrt(diff) <= 10 * (reltol * @sqrt(@max(mx, my)) + floor);
}

test "m=2 on every card letter is two parallel copies, or a refusal" {
    comptime {
        @setEvalBranchQuota(20_000);
        for ("abcdefghijklmnopqrstuvwxyz") |c| {
            for (rows) |row| {
                if (row.letter == c) break;
            } else @compileError("no m= verdict for card letter '" ++ [_]u8{c} ++ "'");
        }
        for (rows) |row| if (row.verdict == .parallel and std.ascii.toLower(row.verdict.parallel.card[0]) != row.letter)
            @compileError("a parallel row's card is not its letter's");
    }
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The letters whose row failed, so one run names every one of them.
    var failed: std.ArrayList(u8) = .empty;
    for (rows) |row| {
        const ok = switch (row.verdict) {
            .parallel => |p| try parallel(a, p.fixture, p.card, p.probes),
            .refused => |body| try refusedWith(a, error.UnsupportedCard, body),
            .no_element => |body| try refusedWith(a, error.UnsupportedDevice, body),
        };
        if (!ok) try failed.append(a, row.letter);
    }
    try t.expectEqualStrings("", failed.items);
}

test "a K card couples an L card's value without its m, as ngspice does" {
    // At 1 kHz behind R1 = 1 ohm: L1 = 1m/2 (indload.c:111-113), M = k
    // sqrt(L1 L2) on the values without m (muttemp.c:50-56 reads
    // INDinduct, which indtemp.c:79 scales by `scale` only) = 0.5 mH, L2 =
    // 1 mH into 1k. The two loop equations (1 + jwL1) I1 + jwM I2 = 1 and
    // jwM I1 + (1k + jwL2) I2 = 0 give |v(b)| = |1k I2| = 0.95202048194245;
    // ngspice-45 prints 0.9520205. M from L1/m would give 0.6735, m
    // dropped 0.4937.
    const p = try solve("k\nv1 in 0 ac 1\nr1 in a 1\nl1 a 0 1m m=2\nl2 b 0 1m\nrb b 0 1k\nk1 l1 l2 0.5\n.ac lin 1 1k 1k\n.end\n");
    defer p.deinit();
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if (!(try p.query_info(id)).requested) continue;
        const r = try p.result(id);
        const k = try column(r, "v(b)") * 2;
        try t.expectApproxEqRel(@as(f64, 0.95202048194245), std.math.hypot(r.data[k], r.data[k + 1]), 1e-9);
        return;
    }
    return error.MissingQuery;
}
