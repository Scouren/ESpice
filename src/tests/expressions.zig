//! Expression features ngspice reads in B sources and in E/F/G/H VALUE,
//! POLY and TABLE forms, run end to end through the Problem API. Oracles:
//! closed forms (a sine's derivative, jω, the RC pole), hand values from
//! each function's definition in ngspice's source (ptfuncs.c, inpcompat.c,
//! XSPICE spice2poly), metamorphic twins (a B charge against the C card, a
//! POLY against its B expression), and the coded refusal of what no tape
//! expresses or plain ngspice refuses. ngspice-44.2 in its default mode
//! printed every hand value here, except ddt's, where it differs by design
//! (models/bsource.va header). Other dialects' forms reach the reader as
//! SpiceRack's ngspice translation of them. Expressions past one tape's
//! capacity are the corpus deck dc/bsource_split.sp, run
//! on CPU and GPU.
const std = @import("std");
const api = @import("espice");
const t = std.testing;
const Result = api.Result;

/// A column's hand values, one per sweep point.
const Column = struct { name: []const u8, want: []const f64 };

// ---- private ----

/// Parses `source` and runs every query; the caller deinits the problem.
fn solve(source: []const u8) !*api.Problem {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "expressions.cir" } } });
    errdefer p.deinit();
    try p.run_all();
    return p;
}

/// The error `source` stops with, at parse or at run; null if it runs.
fn refusal(source: []const u8) ?anyerror {
    const p = api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "expressions.cir" } } }) catch |err| return err;
    defer p.deinit();
    p.run_all() catch |err| return err;
    return null;
}

/// The `ordinal`-th query the deck itself requested, in deck order.
fn requested(p: *const api.Problem, ordinal: usize) !Result {
    var found: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if (!(try p.query_info(id)).requested) continue;
        if (found == ordinal) return p.result(id);
        found += 1;
    }
    return error.MissingRequestedResult;
}

/// Column `name` at `point` as (real, imaginary), imaginary 0 in a real
/// result. Data is point-major; a complex column takes two adjacent f64s.
fn at(r: Result, name: []const u8, point: usize) ![2]f64 {
    const col = for (r.varnames, 0..) |v, i| {
        if (std.mem.eql(u8, v, name)) break i;
    } else {
        std.debug.print("no column {s} in {s}\n", .{ name, r.plotname });
        return error.MissingColumn;
    };
    if (point >= r.npoints) return error.MissingPoint;
    const w: usize = if (r.is_complex) 2 else 1;
    const k = (point * r.varnames.len + col) * w;
    return .{ r.data[k], if (r.is_complex) r.data[k + 1] else 0 };
}

/// Each column matches its hand values at every point of the real sweep
/// `r`, within `tol`; a mismatch names its column and point.
fn expectColumns(r: Result, cols: []const Column, tol: f64) !void {
    for (cols) |c| {
        try t.expectEqual(c.want.len, r.npoints);
        for (c.want, 0..) |want, k| {
            const got = (try at(r, c.name, k))[0];
            if (!(@abs(got - want) <= tol)) {
                std.debug.print("{s} at point {d} is {d}, want {d}\n", .{ c.name, k, got, want });
                return error.TestExpectedApproxEqAbs;
            }
        }
    }
}

/// Each of `cards`, between `preamble` and a 1k load on `o` with an `.op`,
/// stops with `want`; a mismatch names the cards.
fn expectRefused(preamble: []const u8, want: anyerror, cards: []const []const u8) !void {
    for (cards) |card| {
        const deck = try std.mem.concat(t.allocator, u8, &.{ preamble, card, "ro o 0 1k\n.op\n.end\n" });
        defer t.allocator.free(deck);
        const got = refusal(deck);
        if (got == null or got.? != want) {
            std.debug.print("{s}, want {s}: {s}", .{ if (got) |err| @errorName(err) else "ran", @errorName(want), card });
            return error.TestUnexpectedResult;
        }
    }
}

/// The `.op` of `source` reads `want[i]` at node `o<i+1>`, within 1e-12
/// relative (absolute below 1).
fn expectOp(source: []const u8, want: []const f64) !void {
    const p = try solve(source);
    defer p.deinit();
    const op = try requested(p, 0);
    for (want, 1..) |w, i| {
        var buf: [16]u8 = undefined;
        const got = (try at(op, try std.fmt.bufPrint(&buf, "v(o{d})", .{i}), 0))[0];
        if (!(@abs(got - w) <= 1e-12 * @max(1, @abs(w)))) {
            std.debug.print("v(o{d}) is {d}, want {d}\n", .{ i, got, w });
            return error.TestExpectedApproxEqAbs;
        }
    }
}

test "ddt: a B source's ddt of a sine is its derivative in a transient and jω in AC" {
    // v(a) = sin(ωt), ω = 2π·1 kHz: v(d) = ω cos(ωt), and the I-mode b2
    // (bsource_di) drives 1u·ω cos(ωt) into 1k. TMAX = 1 µs keeps ωh ≤
    // 6.3e-3: trap's derivative is off by (ωh)²/12 ≈ 3.3e-6 relative, and
    // the first, backward-Euler step's (ωh)²/3 ≈ 1.3e-5 rings undamped under
    // trap; 1e-4·ω covers both four times over. Newton adds nothing: the
    // tape is linear in its unknowns. t = 0 is the operating point, where ddt
    // is 0 (ptfuncs.c PTddt), so the check starts at the first step.
    // Red before ddt: the deck was refused (UnsupportedBsourceExpression).
    const p = try solve(
        \\ddt of a sine
        \\v1 a 0 dc 0 sin(0 1 1k) ac 1
        \\b1 d 0 v=ddt(v(a))
        \\rd d 0 1k
        \\b2 0 e i=1u*ddt(v(a))
        \\re e 0 1k
        \\.tran 1u 2m 0 1u
        \\.ac lin 1 1k 1k
        \\.end
    );
    defer p.deinit();
    const w: f64 = 2 * std.math.pi * 1e3;
    const tran = try requested(p, 0);
    try t.expect(tran.npoints > 1000);
    for (1..tran.npoints) |k| {
        const slope = w * @cos(w * (try at(tran, "time", k))[0]);
        try t.expectApproxEqAbs(slope, (try at(tran, "v(d)", k))[0], 1e-4 * w);
        try t.expectApproxEqAbs(1e-3 * slope, (try at(tran, "v(e)", k))[0], 1e-7 * w);
    }
    // 1 kHz: jω on d, 1k·1u·jω on e, and i(b1) = -v(d)/1k, the current into
    // b1's + terminal (as i(bm) in analyses.zig), read from bsource_d's own
    // branch row, which its d0..d3 rows move. ngspice-44.2 prints 0 for v(d)
    // here: its PTddt has no Jacobian (inpptree.c:573).
    const ac = try requested(p, 1);
    const cases = [_]struct { []const u8, f64 }{ .{ "v(d)", w }, .{ "v(e)", 1e-3 * w }, .{ "i(b1)", -1e-3 * w } };
    for (cases) |c| {
        const v = try at(ac, c[0], 0);
        try t.expectApproxEqAbs(@as(f64, 0), v[0], 1e-9 * w);
        try t.expectApproxEqRel(c[1], v[1], 1e-9);
    }
}

test "ddt: B i=1u*ddt(v(a)) solves as a 1 µF C card, and both meet the RC closed form" {
    // Metamorphic: the two decks are one set of equations, the charge
    // q = 1u·v(a) integrated by the same method under the same truncation
    // check, so at reltol=1e-6 (as the behavioural-resistor twins in
    // analyses.zig) they agree to 1e-6 V at tstop. Closed forms, ωRC = 2π:
    // AC v(a) = 1/(1 + j2π); from rest, v(t) = A[sin(ωt - φ) + sin φ e^(-t/RC)]
    // with A sin φ = 2π/(1 + 4π²), so v(2 ms) = 2π/(1 + 4π²)·(e^-2 - 1).
    // TMAX = 1 µs bounds trap's global error near (ωh)²/12·|v| ≈ 5e-7 V;
    // 1e-5 V covers it and the first step's backward-Euler error.
    // Red before ddt: the B deck was refused (UnsupportedBsourceExpression).
    var runs: [2]*api.Problem = undefined;
    var made: usize = 0;
    defer for (runs[0..made]) |run| run.deinit();
    for ([_][]const u8{ "b1 a 0 i=1u*ddt(v(a))\n", "c1 a 0 1u\n" }) |card| {
        const deck = try std.mem.concat(t.allocator, u8, &.{ "rc\nv1 in 0 dc 0 sin(0 1 1k) ac 1\nr1 in a 1k\n", card, ".options reltol=1e-6\n.tran 1u 2m 0 1u\n.ac lin 1 1k 1k\n.end\n" });
        defer t.allocator.free(deck);
        runs[made] = try solve(deck);
        made += 1;
    }
    const k: f64 = 2 * std.math.pi;
    const d = 1 + k * k;
    var ends: [2]f64 = undefined;
    for (runs, &ends) |run, *end| {
        const v = try at(try requested(run, 1), "v(a)", 0);
        try t.expectApproxEqRel(1 / d, v[0], 1e-9);
        try t.expectApproxEqRel(-k / d, v[1], 1e-9);
        const tran = try requested(run, 0);
        end.* = (try at(tran, "v(a)", tran.npoints - 1))[0];
        try t.expectApproxEqAbs(k / d * (@exp(@as(f64, -2)) - 1), end.*, 1e-5);
    }
    try t.expectApproxEqAbs(ends[1], ends[0], 1e-6);
}

test "ddt: a fifth ddt() call goes to a bsource of its own; a B source's q= refuses, as plain ngspice-44.2 stops on it" {
    // bsource_d holds four ddt slots (rows d0..d3 in models/bsource.va), so
    // the expression splits (SpiceRack #7): one piece takes four, the card
    // the fifth. Each slot is jω times its operand's derivative in AC, so
    // v(d) = (1 + 2 + 3 + 4 + 5)·jω; a slot dropped or shared shows as a
    // missing term. Red before: the five were refused
    // (UnsupportedBsourceExpression). ngspice's B card has v= and i= alone
    // ("unknown parameter (q)"; a charge is a C card's q=); the prebuilt
    // espice of 2026-11-10 ran b1 o 0 q=1n*v(a) (v(o) = 0).
    const p = try solve(
        \\five ddt
        \\v1 a 0 dc 0 ac 1
        \\b1 d 0 v=ddt(v(a))+ddt(2*v(a))+ddt(3*v(a))+ddt(4*v(a))+ddt(5*v(a))
        \\rd d 0 1k
        \\.ac lin 1 1k 1k
        \\.end
    );
    defer p.deinit();
    const w: f64 = 2 * std.math.pi * 1e3;
    const v = try at(try requested(p, 0), "v(d)", 0);
    try t.expectApproxEqAbs(@as(f64, 0), v[0], 1e-9 * w);
    try t.expectApproxEqRel(15 * w, v[1], 1e-9);
    try expectRefused("b q=\nva a 0 dc 0.5\nra a 0 1k\n", error.UnsupportedCard, &.{ "b1 o 0 q=1n*v(a)\n", "b1 o 0 q=ddt(v(a))\n" });
}

test "PSPICE's if, |, &, ~, TEMP, VT and GMIN refuse, as plain ngspice-44.2 stops on each; ||, &&, ! and ?: run" {
    // ngspice-44.2 in its default mode (no ngbehavior), on each deck below
    // (scratchpad psmode/refuse.sh): numparam stops on `|`, `&` and `~`
    // ("Syntax error: letter [|]") and on if, temp, vt and gmin ("Undefined
    // parameter [if]"); a B or E `|` or `&` stops the card ("Error on line
    // 4"), and `~` and if() there are "no such function". Only its PSPICE
    // mode defines them (inpcompat.c:684-705, 1013-1059), a dialect that
    // reaches ESPice through SpiceRack. Red before: the tree read each one
    // (builtin_funcs' if, pspice_params, expr_compile's `|`, `&` and `~`).
    for ([_][]const u8{
        ".param p={1|0}\nvo o 0 {p}\n",
        ".param p={1&0}\nvo o 0 {p}\n",
        ".param p={~0}\nvo o 0 {p}\n",
        "b1 o 0 v=(v(a)>0)|0\n",
        "b1 o 0 v=(v(a)>0)&0\n",
        "b1 o 0 v=~(v(a)>1)\n",
        "e1 o 0 value={(v(a)>0)|0}\n",
        ".param p={if(1,2,3)}\nvo o 0 {p}\n",
        "vo o 0 {if(0,2,3)}\n",
        "b1 o 0 v=if(v(a)>0,2,3)\n",
        "e1 o 0 value={if(v(a)>0,2,3)}\n",
        ".param p={temp}\nvo o 0 {p}\n",
        ".param p={vt}\nvo o 0 {p}\n",
        "vo o 0 {gmin*1e12}\n",
        "e1 o 0 value={temp}\n",
        "b1 o 0 v=vt*1000\n",
    }) |cards| {
        const deck = try std.mem.concat(t.allocator, u8, &.{ "pspice forms\nva a 0 dc 0.5\nra a 0 1k\n", cards, "ro o 0 1k\n.op\n.end\n" });
        defer t.allocator.free(deck);
        if (refusal(deck) == null) {
            std.debug.print("ran, where ngspice-44.2 stops: {s}", .{cards});
            return error.TestUnexpectedResult;
        }
    }
    // Their ngspice spellings run, so the refusals are the PSPICE forms'
    // and the lexer still reads `||`, `&&` and `!`; ngspice-44.2 printed
    // these values for this deck.
    const p = try solve(
        \\ngspice logic
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\.param p1={1||0}
        \\.param p2={!0}
        \\.param p3={1&&0}
        \\.param p4={1 ? 2 : 3}
        \\v1 o1 0 {p1}
        \\v2 o2 0 {p2}
        \\v3 o3 0 {p3}
        \\v4 o4 0 {p4}
        \\b5 o5 0 v=(v(a)>0)||0
        \\b6 o6 0 v=!(v(a)>1)
        \\b7 o7 0 v=(v(a)>0)&&(v(a)<1)
        \\b8 o8 0 v=v(a)>0 ? 2 : 3
        \\e9 o9 0 value={(v(a)>0)||0}
        \\.op
        \\.end
    );
    defer p.deinit();
    const op = try requested(p, 0);
    for ([_][]const u8{ "v(o1)", "v(o2)", "v(o3)", "v(o4)", "v(o5)", "v(o6)", "v(o7)", "v(o8)", "v(o9)" }, [_]f64{ 1, 1, 0, 2, 1, 1, 1, 2, 1 }) |name, want|
        try t.expectEqual(want, (try at(op, name, 0))[0]);
}

test "nint in a B source rounds a half to the even integer, with a zero slope" {
    // PTnint is nearbyint (ptfuncs.c:417): ties to even under IEEE 754's
    // default rounding; its derivative is 0 (inpptree.c:547). floor(v) + 0.5
    // puts the exact halves -2.5 .. 2.5 inside the tape whatever the solved
    // v(a)'s last bit, since every sweep point sits 0.25 off an integer.
    // Red before: nint was UnsupportedFunction in a tape.
    const p = try solve(
        \\nint
        \\v1 a 0 dc 0.25 ac 1
        \\b1 o1 0 v=nint(v(a))
        \\b2 o2 0 v=nint(floor(v(a)) + 0.5)
        \\.dc v1 -2.75 2.25 1
        \\.ac lin 1 1k 1k
        \\.end
    );
    defer p.deinit();
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o1)", .want = &.{ -3, -2, -1, 0, 1, 2 } },
        .{ .name = "v(o2)", .want = &.{ -2, -2, 0, 0, 2, 2 } },
    }, 1e-12);
    const ac = try requested(p, 1);
    for ([_][]const u8{ "v(o1)", "v(o2)" }) |name| {
        const v = try at(ac, name, 0);
        try t.expectApproxEqAbs(@as(f64, 0), @abs(v[0]) + @abs(v[1]), 1e-12);
    }
}

test "sgn in a B source is -1, 0 or 1, with a zero slope" {
    // PTsgn (ptfuncs.c:31-34), whose derivative is 0 (inpptree.c:404-406);
    // ngspice-44.2 printed every value here. sgn(v(a) - v(a)) is an exact
    // 0, and sgn(v(a))*v(a) is |v(a)| with slope sgn = 1 at 0.25 V.
    // Red before: sgn was UnsupportedFunction in a tape (the OptiMOS
    // library's G_chan VALUE reads sgn(V(d5a,s))).
    const p = try solve(
        \\sgn
        \\v1 a 0 dc 0.25 ac 1
        \\b1 o1 0 v=sgn(v(a))
        \\b2 o2 0 v=sgn(v(a)-v(a))
        \\b3 o3 0 v=sgn(v(a))*v(a)
        \\.dc v1 -1.5 1.5 1
        \\.ac lin 1 1k 1k
        \\.end
    );
    defer p.deinit();
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o1)", .want = &.{ -1, -1, 1, 1 } },
        .{ .name = "v(o2)", .want = &.{ 0, 0, 0, 0 } },
        .{ .name = "v(o3)", .want = &.{ 1.5, 0.5, 0.5, 1.5 } },
    }, 1e-12);
    const ac = try requested(p, 1);
    const o1 = try at(ac, "v(o1)", 0);
    try t.expectApproxEqAbs(@as(f64, 0), @abs(o1[0]) + @abs(o1[1]), 1e-12);
    const o3 = try at(ac, "v(o3)", 0);
    try t.expectApproxEqAbs(@as(f64, 1), o3[0], 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0), o3[1], 1e-12);
}

test "cosh and pwr in a B source: cosh with slope sinh, pwr as sign(x)|x|^y with slope y|x|^(y-1)" {
    // PTcosh (ptfuncs.c:261-264) and PTpwr (ptfuncs.c:125-135), the B
    // parser's pwr, not numparam's |x|^y; sky130's 20 V FETs read pwr of a
    // probe in a behavioural R and its varactors cosh in a C charge.
    // Hand values from the definitions; ngspice-44.2 printed each one.
    // Red before: both were UnsupportedFunction in a tape.
    const p = try solve(
        \\cosh pwr
        \\v1 a 0 dc 0.5 ac 1
        \\b1 o1 0 v=cosh(v(a))
        \\b2 o2 0 v=pwr(v(a), 3)
        \\b3 o3 0 v=pwr(v(a) - 1, 1.5)
        \\.dc v1 -1 1 0.5
        \\.ac lin 1 1k 1k
        \\.end
    );
    defer p.deinit();
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o1)", .want = &.{ 1.5430806348152437, 1.1276259652063807, 1, 1.1276259652063807, 1.5430806348152437 } },
        .{ .name = "v(o2)", .want = &.{ -1, -0.125, 0, 0.125, 1 } },
        .{ .name = "v(o3)", .want = &.{ -2.8284271247461903, -1.8371173070873836, -1, -0.3535533905932738, 0 } },
    }, 1e-12);
    const ac = try requested(p, 1);
    for ([_][]const u8{ "v(o1)", "v(o2)", "v(o3)" }, [_]f64{ 0.5210953054937474, 0.75, 1.0606601717798214 }) |name, slope| {
        const v = try at(ac, name, 0);
        try t.expectApproxEqAbs(slope, v[0], 1e-12);
        try t.expectApproxEqAbs(@as(f64, 0), v[1], 1e-12);
    }
}

test "sinh, asin, acos, asinh, acosh and atanh in a B source: each slope is its central difference and ngspice-44.2's" {
    // Their values over -0.75..0.75 are the corpus deck
    // dc/bsource_functions_ngspice.sp's, run on CPU and GPU. Here, at
    // x = 0.5 (acosh at x + 1.75), the AC gain reads the tape's dual slope,
    // and twins at x ± h, h = 1e-4, give its central difference: truncation
    // h²|f'''|/(6|f'|) is at most 1.1e-8 (atanh, f''' = 8.3), rounding
    // ε|f|/(2h) about 1e-12. ngspice-44.2 printed each slope, its derivative
    // trees' (inpptree.c:408-502): cosh x, ±1/√(1-x²), 1/√(x²+1),
    // 1/√(x²-1) and 1/(1-x²). Red before: each was UnsupportedFunction in a
    // tape.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calls = [_][]const u8{ "sinh(X)", "asin(X)", "acos(X)", "asinh(X)", "acosh(X + 1.75)", "atanh(X)" };
    const slopes = [_]f64{ 1.1276259652063807, 1.1547005383792517, -1.1547005383792517, 0.8944271909999159, 0.49613893835683387, 1.3333333333333333 };
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "inverse functions\nv1 a 0 dc 0.5 ac 1\n");
    for (calls, 0..) |call, k| {
        for ([_][]const u8{ "o", "p", "m" }, [_][]const u8{ "v(a)", "(v(a) + 1e-4)", "(v(a) - 1e-4)" }) |node, x| {
            try text.appendSlice(a, try a.print("b{s}{d} {s}{d} 0 v={s}\n", .{ node, k, node, k, try std.mem.replaceOwned(u8, a, call, "X", x) }));
        }
    }
    try text.appendSlice(a, ".op\n.ac lin 1 1k 1k\n.end\n");
    const p = try solve(text.items);
    defer p.deinit();
    const op = try requested(p, 0);
    const ac = try requested(p, 1);
    for (slopes, 0..) |slope, k| {
        const gain = try at(ac, try a.print("v(o{d})", .{k}), 0);
        try t.expectApproxEqRel(slope, gain[0], 1e-12);
        try t.expectApproxEqAbs(@as(f64, 0), gain[1], 1e-15);
        const hi = (try at(op, try a.print("v(p{d})", .{k}), 0))[0];
        const lo = (try at(op, try a.print("v(m{d})", .{k}), 0))[0];
        try t.expectApproxEqRel(gain[0], (hi - lo) / 2e-4, 1e-7);
    }
}

test "asin, acos and acosh of a clamped probe hold the edge with a zero slope; past the edge the point fails" {
    // ngspice-44.2 printed every value and slope here. On the edge the
    // clamp's slope is 0, so ngspice's (PTdivide's 1/1e-32) and the
    // tape's (the infinite one dropped, models/bsource.va header) both
    // give 0. Unclamped past it, ngspice-44.2's op fails ("out of range for
    // sqrt", the slope's PTsqrt; "for atanh", HUGE; or Newton on atanh's
    // NaN), and the tape's NaN or inf fails the point; atanh(-1) alone,
    // where ngspice prints -inf, fails here and is not checked. Red
    // before: each was UnsupportedFunction in a tape.
    const p = try solve(
        \\clamped edges
        \\v1 a 0 dc 1.5 ac 1
        \\b1 o1 0 v=asin(max(min(v(a), 1), -1))
        \\b2 o2 0 v=acos(max(min(v(a), 1), -1))
        \\b3 o3 0 v=acosh(max(v(a), 1))
        \\.dc v1 -1.5 1.5 0.75
        \\.ac lin 1 1k 1k
        \\.end
    );
    defer p.deinit();
    const half_pi = std.math.pi / 2.0;
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o1)", .want = &.{ -half_pi, -0.848062078981481, 0, 0.848062078981481, half_pi } },
        .{ .name = "v(o2)", .want = &.{ std.math.pi, 2.4188584057763776, half_pi, 0.7227342478134157, 0 } },
        .{ .name = "v(o3)", .want = &.{ 0, 0, 0, 0, 0.9624236501192069 } },
    }, 1e-12);
    const ac = try requested(p, 1);
    for ([_][]const u8{ "v(o1)", "v(o2)", "v(o3)" }, [_]f64{ 0, 0, 0.8944271909999159 }) |name, slope| {
        const v = try at(ac, name, 0);
        try t.expectApproxEqAbs(slope, v[0], 1e-12);
        try t.expectApproxEqAbs(@as(f64, 0), v[1], 1e-12);
    }
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "asin", "asin", "acos", "acosh", "atanh", "atanh" }, [_]f64{ 1.5, -1.5, 1.5, 0.5, 1, -1.5 }) |f, x| {
        const deck = try arena.allocator().print("past the edge\nv1 a 0 dc {d}\nb1 o 0 v={s}(v(a))\nro o 0 1k\n.op\n.end\n", .{ x, f });
        errdefer std.debug.print("{s}({d})\n", .{ f, x });
        try t.expectEqual(@as(?anyerror, error.OpDidNotConverge), refusal(deck));
    }
}

test "E and G TABLE cards smooth their corners and hold their ends; the B-source pwl is sharp and extends them" {
    // ngspice-44.2 printed these for this deck, swept at 0.05 V (scratchpad
    // tbl/sweep.cir): its TABLE card is an XSPICE pwl with input_domain=0.1
    // fraction=TRUE limit=TRUE (inpcom.c), a corner parabola a tenth of the
    // shorter segment wide each side, the ends held; B's pwl is ptfuncs.c
    // PTpwl, sharp, its end segments extended. Points (-1,-2) (0,0) (1,4):
    // the corners show at -1, 0 and 1 as -1.95, 0.05 and 3.9. One pair is
    // its y alone (inpcom.c: "a single pair (x0, y0) will return a constant
    // voltage y0"), 3 V for e4 and 3 mA for g5. Red before: e4 and g5 were
    // ParseErrors (two pairs at least), in the prebuilt espice of 2026-11-10
    // too.
    const p = try solve(
        \\tables
        \\v1 a 0 dc 0
        \\e1 o 0 table {v(a)} = (-1,-2) (0,0) (1,4)
        \\g2 0 g table {v(a)} = (-1,-2m) (0,0) (1,4m)
        \\rg g 0 1k
        \\b3 q 0 v=pwl(v(a), -1, -2, 0, 0, 1, 4)
        \\e4 c 0 table {v(a)} = (5,3)
        \\g5 0 d table {v(a)} = (5,3m)
        \\rd d 0 1k
        \\.dc v1 -2 2 0.5
        \\.end
    );
    defer p.deinit();
    const table = [_]f64{ -2, -2, -1.95, -1, 0.05, 2, 3.9, 4, 4 };
    const three: [9]f64 = @splat(3);
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o)", .want = &table },
        .{ .name = "v(g)", .want = &table },
        .{ .name = "v(q)", .want = &.{ -4, -3, -2, -1, 0, 2, 4, 6, 8 } },
        .{ .name = "v(c)", .want = &three },
        .{ .name = "v(d)", .want = &three },
    }, 1e-12);
}

test "a deck's table() and ternary(), HSPICE's PWL(1), VCR and VCCAP, and the B parser's functions in a value refuse, as plain ngspice-44.2 stops on each" {
    // ngspice-44.2 in its default mode on each deck below (scratchpad
    // tbl/run.sh): table( is "no such function" in a B or E expression and
    // "Undefined parameter [table]" in a value or .param, and so is
    // ternary(; E and G PWL(1), with DELTA or without, and VCR PWL(1) stop
    // on "MIF-ERROR ... Bad real value", and G vcr or vccap with three
    // fields after it reads them as a floating node and stops singular;
    // u, uramp, u2, eq0..le0, pwl and ddt are the B parser's,
    // "Undefined parameter [u]" in a value or .param. Red before (the
    // prebuilt espice of 2026-11-10): PWL(1) ran (v(o) = 1, and 0.9307692
    // with DELTA=0.1), G VCR and VCCAP ran (0), a value's table() and every
    // B parser function in a value read 0, and ternary() ran (2).
    try expectRefused("ngspice refuses\nva a 0 dc 0.5\nra a 0 1k\n", error.UnsupportedCard, &.{
        "e1 o 0 value={table(v(a),0,0,1,2)}\n",
        "b1 o 0 v=table(v(a),0,0,1,2)\n",
        "vo o 0 {table(0.5,0,0,1,2)}\n",
        "vo o 0 {ternary(1,2,3)}\n",
        "b1 o 0 v=ternary(1,2,3)\n",
        "e1 o 0 pwl(1) a 0 (0,0) (1,2)\n",
        "e1 o 0 pwl(1) a 0 (0,0) (0.52,1) (1,1) delta=0.1\n",
        "g1 0 o pwl(1) a 0 (0,0) (1,2m)\n",
        "g1 0 o vcr pwl(1) a 0 0,1k 1,2k\n",
        "g1 0 o vcr a 0 2\n",
        "g1 0 o vccap a 0 2\n",
        "vo o 0 {u(1)}\n",
        ".param p={u(1)}\nvo o 0 {p}\n",
        "vo o 0 {uramp(2)}\n",
        "vo o 0 {u2(0.5)}\n",
        "vo o 0 {eq0(0)}\n",
        "vo o 0 {le0(0)}\n",
        "vo o 0 {pwl(0.5,0,0,1,2)}\n",
        ".param p={pwl(0.5,0,0,1,2)}\nvo o 0 {p}\n",
        "vo o 0 {ddt(1)}\n",
        ".param p={eq0(0)}\nb1 o 0 v=p*v(a)\n",
    });
}

test "a brace or quote that groups inside a B, E or G expression refuses, as a nested brace in a .param or value does; one that does not group runs" {
    // ngspice-44.2 (scratchpad braces/run.sh, tbl/run.sh; k = 3, v(a) =
    // 0.5) strips every brace and quote inside a B line, an E or G VALUE's
    // and a behavioural R's included (inpcom.c inp_change_quotes,
    // inp_bsource_compat), and a .func body's: b v={k+1}*v(a) and
    // v='k+1'*v(a) are 3.5 there where grouping gives 2, v=2*{1+v(a)} 2.5,
    // v=2*{1+1} 3, f(v(a)) of .func f(x)={2*{1+x}} 2.5, r={1k*{1+v(a)}} a
    // 1000.5 ohm; E value={2*{1+1}} is 3, or 4 when the deck has a .param,
    // and G cur={2*{1+1}*1m} 2.001 A or 4 mA. A nested brace in a .param is
    // its "Syntax error", and in a value too unless the deck has a .param.
    // So a group that strips to another expression is refused, coded, and
    // a nested brace elsewhere is a ParseError. Red before: the tree
    // grouped every brace as parentheses (2, 2, 3, 4, 4, 4, 4 mA, 1500 ohm,
    // 9, 4, 4, 4); the prebuilt espice of 2026-11-10 read {k+1}*v(a) and
    // 'k+1'*v(a) as 2 and failed the rest as ParseErrors.
    const preamble = "braces\nva a 0 dc 0.5\nra a 0 1k\n.param k=3\n";
    try expectRefused(preamble, error.UnsupportedCard, &.{
        "b1 o 0 v={k+1}*v(a)\n",
        "b1 o 0 v='k+1'*v(a)\n",
        "b1 o 0 v=2*{1+v(a)}\n",
        "b1 o 0 v=2*{1+1}\n",
        "e1 o 0 value={2*{1+1}}\n",
        "e1 o 0 value={2*{1+v(a)}}\n",
        "g1 0 o cur={2*{1+1}*1m}\n",
        "r1 a o r={1k*{1+v(a)}}\n",
    });
    try expectRefused(preamble, error.ParseError, &.{
        ".param p={{1+2}*3}\nvo o 0 {p}\n",
        ".param p={2*{1+1}}\nvo o 0 {p}\n",
        "vo o 0 {2*{1+1}}\n",
        ".func f(x)={2*{1+x}}\nb1 o 0 v=f(v(a))\n",
    });
    // A group of one operand reads the same stripped; ngspice-44.2 printed
    // these. Red before: b2 failed (ParseError) in the 2026-11-10 binary.
    try expectOp(
        \\braces that do not group
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\.param k=3
        \\b1 o1 0 v={k}*v(a)
        \\b2 o2 0 v=2*{k}
        \\e3 o3 0 value={k}*v(a)+1
        \\.op
        \\.end
    , &.{ 1.5, 6, 2.5 });
}

test "a B line holding =pwl( groups its braces as numparam values, as ngspice-44.2 reads it; a group that reads a probe refuses" {
    // inp_bsource_compat skips a B line holding `=pwl(` (inpcom.c:7199-
    // 7201, after inp_remove_ws drops the blanks around `=`), so numparam
    // evaluates each brace there: ngspice-44.2 printed these (k = 3, v(a) =
    // 0.5; scratchpad r4/twC). On such a line a group reading v(a) is its
    // "Undefined parameter [v]" and a nested one its "Syntax error"; `pwl (`
    // misses the match and strips (5 there), so its grouping brace refuses
    // as any other. Red before: the prebuilt espice of 2026-11-10 failed
    // every card here as a ParseError.
    try expectOp(
        \\pwl braces
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\.param k=3
        \\b1 o1 0 v=pwl(v(a),0,0,1,{k})
        \\b2 o2 0 v=pwl(v(a),0,0,1,4)*{1+k}
        \\b3 o3 0 v = pwl(v(a),0,0,1,4)*'1+k'
        \\b4 0 o4 i=pwl(v(a),0,0,1,4m)*{1+k}
        \\r4 o4 0 1k
        \\b5 o5 0 v=pwl(v(a),0,0,1,4)+{k}*2
        \\.op
        \\.end
    , &.{ 1.5, 8, 8, 8, 8 });
    const preamble = "pwl braces\nva a 0 dc 0.5\nra a 0 1k\n.param k=3\n";
    try expectRefused(preamble, error.UnsupportedCard, &.{
        "b1 o 0 v=pwl({v(a)},0,0,1,4)\n",
        "b1 o 0 v=pwl(v(a),0,0,1,4)*{1+v(a)}\n",
        "b1 o 0 v=pwl (v(a),0,0,1,4)*{1+k}\n",
    });
    try expectRefused(preamble, error.ParseError, &.{"b1 o 0 v=pwl(v(a),0,0,1,4)*{2*{1+1}}\n"});
}

test "E and G VALUE: m=, tc1= and tc2= run as ngspice-44.2 reads them; its other modifiers, a text that starts with a number, and the forms it reads on other letters refuse" {
    // ngspice-44.2 (scratchpad r4/twA, twB, modcases, redcases; k = 3,
    // v(a) = 0.5): m= multiplies, tc1 = 1 and tc2 = 1 at 127 degC scale by
    // 1 + 100 and 1 + 100^2; a text that does not start with a number is
    // read whole. It stops on scale=, max=, min=, abs= and ic= ("Undefined
    // parameter"), on any modifier after POLY ("MIF-ERROR"), on a text that
    // starts with a number and has no brace ("mal formed E source
    // instance"), and on VALUE on F or H, CUR= on E and VOL= on G
    // ("Undefined parameter [i]" or [v]); after TABLE it drops a modifier
    // ("Missing token": 1 for scale=2), and it reads 2*v(a)+{k} from its
    // brace on (3 where the whole is 4). Red before (the prebuilt espice of
    // 2026-11-10): scale=2 2, max=0.5 0.5, min=2 2, abs=1 1, ic=1 1, POLY m=2
    // 2, TABLE scale=2 and m=2 2, value=2*v(a) 1, cur=2m*v(a) 1, H VALUE
    // -0.2, F VALUE -2, G VOL= and E CUR= 1; value=-v(a)+{k} a ParseError.
    try expectOp(
        \\value forms
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\.param k=3
        \\e1 o1 0 value={2*v(a)} m=2
        \\g2 0 o2 cur={2m*v(a)} m=2
        \\r2 o2 0 1k
        \\e3 o3 0 value=v(a)*2
        \\e4 o4 0 value=-v(a)+{k}
        \\e5 o5 0 value=(2*v(a))+{k}
        \\e6 o6 0 value=v(a)*{k}
        \\g7 0 o7 cur=v(a)*2m
        \\r7 o7 0 1k
        \\.op
        \\.end
    , &.{ 2, 2, 1, 2.5, 4, 1.5, 1 });
    try expectOp(
        \\value temperature coefficients
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\e1 o1 0 value={2*v(a)} tc1=1
        \\e2 o2 0 value={2*v(a)} tc2=1
        \\.temp 127
        \\.op
        \\.end
    , &.{ 101, 10001 });
    try expectRefused("value refusals\nva a 0 dc 0.5\nra a 0 1k\n.param k=3\nvs b 0 2\nrs b 0 1k\n", error.UnsupportedCard, &.{
        "e1 o 0 value={2*v(a)} scale=2\n",
        "e1 o 0 value={2*v(a)} max=0.5\n",
        "e1 o 0 value={2*v(a)} min=2\n",
        "e1 o 0 value={2*v(a)} abs=1\n",
        "e1 o 0 value={2*v(a)} ic=1\n",
        "g1 0 o cur={2m*v(a)} scale=2\n",
        "e1 o 0 poly(1) a 0 0 2 m=2\n",
        "e1 o 0 poly(1) a 0 0 2 tc1=1\n",
        "e1 o 0 table {v(a)} = (0,0) (1,2) scale=2\n",
        "e1 o 0 table {v(a)} = (0,0) (1,2) m=2\n",
        "e1 o 0 value=2*v(a)\n",
        "e1 o 0 value=2*v(a)+{k}\n",
        "e1 o 0 value=-2*v(a)+{k}\n",
        "e1 o 0 value=.5*v(a)+{k}\n",
        "g1 0 o cur=2m*v(a)\n",
        "h1 o 0 value={i(vs)*100}\n",
        "f1 0 o value={i(vs)*1}\n",
        "g1 0 o vol={2m*v(a)}\n",
        "e1 o 0 cur={2*v(a)}\n",
    });
}

test "a form word followed by a linear card's tail is a node, as ngspice-44.2 reads it; the HSPICE forms it stops on refuse" {
    // ngspice-44.2 printed these (scratchpad r4/twD, nodecases): each word
    // below, in the first control slot with one node and a gain after it,
    // is a node at 0.25 V, so the output is 0.5 V; m= on G multiplies; a
    // type word goes only from a whole linear card (inpcom.c replace_token),
    // so `vccs vccs 0 2m` keeps the second as a node; h10's `vol` is a
    // source. It stops on VCR PWL(1), VCCAP PWL(1) and a type word on a card
    // that is no linear one. Red before (the prebuilt espice of 2026-11-10):
    // this deck failed ("VCR or VCCAP on a card other than G"), e1 o 0 vcvs
    // 0 2 and g1 0 o vccs vccs 0 2m read 0, e1 o 0 poly 0 2 and laplace 0 2
    // were ParseErrors, G VCCAP PWL(1) ran (0) and vcvs a 0 2 3 ran (1).
    // e12 and e13 read `delay` as a node too (scratchpad u8/twins.sp, sha256
    // 357205f9145c5cb2910e853f3298f01dc25b0080044ef03f26d7eb99f2fb9b0f, less
    // its e14), and ngspice stops on `vcvs vcvs a 0 2` ("unknown parameter
    // (a)"); before, the delay cards were ParseErrors and that one read 1.
    try expectOp(
        \\form words as nodes
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\vw1 vcr 0 0.25
        \\e1 o1 0 vcr 0 2
        \\vw2 vccap 0 0.25
        \\g2 0 o2 vccap 0 2m
        \\r2 o2 0 1k
        \\vw3 pwl 0 0.25
        \\e3 o3 0 pwl 0 2
        \\vw4 poly 0 0.25
        \\e4 o4 0 poly 0 2
        \\vw5 laplace 0 0.25
        \\e5 o5 0 laplace 0 2
        \\vw6 vcvs 0 0.25
        \\e6 o6 0 vcvs 0 2
        \\vw7 vccs 0 0.25
        \\g7 0 o7 vccs vccs 0 2m
        \\r7 o7 0 1k
        \\g8 0 o8 vcr 0 2m m=2
        \\r8 o8 0 1k
        \\e9 o9 0 vcvs a 0 2
        \\vol x 0 0.25
        \\rx x 0 1k
        \\h10 o10 0 vol 2k
        \\vw11 cur 0 0.25
        \\e11 o11 0 cur 0 2
        \\vw12 delay 0 0.25
        \\e12 o12 0 delay a 2
        \\e13 o13 0 delay a 0
        \\.op
        \\.end
    , &.{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1, 1, -0.5, 0.5, -0.5, 0 });
    try expectRefused("form words\nva a 0 dc 0.5\nra a 0 1k\n", error.UnsupportedCard, &.{
        "e1 o 0 vcr pwl(1) a 0 0,1k 1,2k\n",
        "g1 0 o vccap pwl(1) a 0 0,1p 1,2p\n",
        "e1 o 0 vcvs a 0 2 3\n",
        "e1 o 0 vcvs vcvs a 0 2\n",
    });
}

test "SPICE 2G6's implicit POLY(1): numbers after a linear E, F, G or H card's gain are its coefficients, as ngspice-44.2 reads them" {
    // Hand values: p0 + p1·x + p2·x² + ... (XSPICE spice2poly), x = v(a) =
    // 0.5, i(vs) = 0.5 mA, v(a,x) = 0. ngspice-44.2 in its default mode
    // printed each (`ngspice -b`, scratchpad etail/twin/twin1.cir, sha256
    // 5d9e4d45c919bc0f593c0b16d0edaa03f8a63795e2f81e7ed480e8c0ae0ac9d0, and
    // twin2.cir, 53ffcc5632c078f5be53dabbebb928c135c4885a926fe079830f31fc35f6722b):
    // it inserts `poly(1)` when anything but `m=` or `ic=` follows the gain
    // (inpcom.c inp_poly_2g6_compat), unless the first control starts with
    // poly, value, vol, table, laplace, cur, vccs, vcvs, ccvs or cccs (o13).
    // Red before (the prebuilt espice of 2026-11-10): o1-o5, o7, o10-o12
    // read 1, o6 0, o8 and o9 0.5m (o13 and o14 already read 0.5 and 2), and
    // the parenthesized deck was a ParseError.
    try expectOp(
        \\implicit poly
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\vs a x 0
        \\rx x 0 1k
        \\.param k=3
        \\e1 o1 0 a 0 2 3
        \\e2 o2 0 a 0 2 3 4
        \\e3 o3 0 a 0 {2} k
        \\e4 o4 0 a 0 2,3 4
        \\e5 o5 0 a 0 2 0
        \\e6 o6 0 a x 2 3
        \\g7 0 o7 a 0 2m 3m
        \\r7 o7 0 1k
        \\f8 0 o8 vs 1m 2
        \\r8 o8 0 1k
        \\h9 o9 0 vs 1 2k
        \\e10 o10 0 a 0 2 3 4 5 6 7 8 9 10 11 12
        \\.subckt s p c
        \\e1 p 0 c 0 2 3
        \\.ends
        \\x11 o11 a s
        \\x12 o12 a s
        \\vw volx 0 0.25
        \\e13 o13 0 volx 0 2
        \\g14 0 o14 a 0 2m m=2
        \\r14 o14 0 1k
        \\.op
        \\.end
    , &.{ 3.5, 4.5, 3.5, 4.5, 2, 2, 3.5, 2, 2, 5.986328125, 3.5, 3.5, 0.5, 2 });
    try expectOp(
        \\implicit poly in parentheses
        \\va a 0 dc 0.5
        \\ra a 0 1k
        \\e1 o1 0 (a 0) 2 3
        \\g2 0 o2 (a,0) 2m 3m
        \\r2 o2 0 1k
        \\.op
        \\.end
    , &.{ 3.5, 3.5 });
    // ngspice-44.2 stops on each (scratchpad etail/ref, these decks):
    // a number after `m=`, or after the gain of a card whose first control
    // keeps it linear, is an "unknown parameter"; a modifier after the
    // inserted POLY(1) is a "MIF-ERROR"; E and H take no m= ("unknown
    // parameter (m)", net_card.addDevice). AND(n) on an E card is XSPICE's
    // multi_input_pwl there (1 V for the card below), which ESPice refuses
    // by name. Red before (the same espice): volx 0.5, polyx 0.5, m=2 3m 2,
    // f m=2 3 1, e 3 m=2 1, g 3m m=2 2, f 2 m=2 0.5m, h 2k m=2 0.5m, e m=2 1,
    // h m=2 1; tc1= and and(2) were refused.
    try expectRefused("implicit poly refusals\nva a 0 dc 0.5\nra a 0 1k\nvs a x 0\nrx x 0 1k\nvw volx 0 0.25\nvp polyx 0 0.25\n", error.UnsupportedCard, &.{
        "e1 o 0 volx 0 2 3\n",
        "e1 o 0 polyx 0 2 3\n",
        "g1 0 o a 0 2m m=2 3m\n",
        "f1 0 o vs 2 m=2 3\n",
        "e1 o 0 a 0 2 3 m=2\n",
        "g1 0 o a 0 2m 3m m=2\n",
        "f1 0 o vs 1m 2 m=2\n",
        "h1 o 0 vs 1 2k m=2\n",
        "e1 o 0 a 0 2 3 tc1=1\n",
        "e1 o 0 a 0 2 m=2\n",
        "h1 o 0 vs 2k m=2\n",
        "e1 o 0 and(2) a 0 a 0 0,0 1,2\n",
    });
}

test "SpiceRack #6: pwl in an E VALUE is the sharp table, its end segments extended" {
    // es_pwl.cir of SpiceRack's espice-issues/5-7 (P3-070), card for card.
    // Points (-2,1) (-1,1) (1,-1) (2,0) (3,0): flat, slope -1, slope 1,
    // flat. ngspice-44.2 printed these v(2) (ngspice -b, a .print added),
    // as ngspice-45 did for P3-070. Red before: WrongArity.
    const p = try solve(
        \\* t
        \\V1 1 0 0
        \\E1 2 0 value={pwl(V(1), -2, 1, -1, 1, 1, -1, 2, 0, 3, 0)}
        \\R2 2 0 1k
        \\.dc V1 -2 3 0.5
        \\.end
    );
    defer p.deinit();
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(2)", .want = &.{ 1, 1, 1, 0.5, 0, -0.5, -1, -0.5, 0, 0, 0 } },
    }, 1e-12);
}

test "POLY(2) on E, F, G and H: parenthesized, comma-separated fields, hand values and the B twin" {
    // x1 = i(vs1) = v(a)/1k, x2 = i(vs2) = 1 mA (2 V on 2k), or v(a) and
    // v(b) = 2 V for E and G. SPICE 2G6 coefficient order p0 + p1·x1 +
    // p2·x2 + p3·x1² + p4·x1·x2 + p5·x2² (XSPICE spice2poly). XSPICE reads
    // the coefficients past `(`, `,` and `)` (enhtrans.c:407-410,
    // mifutil.c:68-71), so f1's list is p0..p2 as
    // examples/TransImpedanceAmp/output.sp writes it. b1 is h1 written as
    // a B expression (metamorphic).
    // Red before: f1, e1 and g1 failed to parse.
    const p = try solve(
        \\poly2
        \\v1 a 0 dc 0
        \\vs1 a x 0
        \\rx x 0 1k
        \\v2 b 0 dc 2
        \\vs2 b y 0
        \\ry y 0 2k
        \\f1 0 o poly(2) vs1 vs2 (0.5m, 2, 3)
        \\ro o 0 1k
        \\e1 p 0 poly(2) (a,0) (b,0) 0.5, 2, 3
        \\g1 0 q poly(2) a 0 b 0 (0.5m, 2m, 3m)
        \\rq q 0 1k
        \\h1 r 0 poly(2) vs1 vs2 0 1k 1k 1meg 2meg 500k
        \\b1 s 0 v=1k*i(vs1) + 1k*i(vs2) + 1meg*i(vs1)^2 + 2meg*i(vs1)*i(vs2) + 500k*i(vs2)^2
        \\.dc v1 -1 1 1
        \\.end
    );
    defer p.deinit();
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o)", .want = &.{ 1.5, 3.5, 5.5 } },
        .{ .name = "v(p)", .want = &.{ 4.5, 6.5, 8.5 } },
        .{ .name = "v(q)", .want = &.{ 4.5, 6.5, 8.5 } },
        .{ .name = "v(r)", .want = &.{ -0.5, 1.5, 5.5 } },
        .{ .name = "v(s)", .want = &.{ -0.5, 1.5, 5.5 } },
    }, 1e-9);
}

test "ngspice's u, uramp, u2 and compare-to-zero functions in a B source" {
    // ptfuncs.c:186-252: u steps 0 to 1 (0.5 at 0), uramp is max(x, 0),
    // u2 clamps to [0, 1], lt0 and ge0 compare with 0. No sweep point is 0.
    // Red before: each was UnsupportedFunction.
    const p = try solve(
        \\step functions
        \\v1 a 0 dc 0
        \\b1 o1 0 v=u(v(a))
        \\b2 o2 0 v=uramp(v(a))
        \\b3 o3 0 v=u2(v(a))
        \\b4 o4 0 v=lt0(v(a)) + 2*ge0(v(a))
        \\.dc v1 -1.25 1.75 1
        \\.end
    );
    defer p.deinit();
    try expectColumns(try requested(p, 0), &.{
        .{ .name = "v(o1)", .want = &.{ 0, 0, 1, 1 } },
        .{ .name = "v(o2)", .want = &.{ 0, 0, 0.75, 1.75 } },
        .{ .name = "v(o3)", .want = &.{ 0, 0, 0.75, 1 } },
        .{ .name = "v(o4)", .want = &.{ 1, 1, 2, 2 } },
    }, 1e-12);
}

test "ngspice log of a negative argument ends the operating point" {
    // PTlog returns HUGE below 0 (ptfuncs.c:289-296) and PTeval reports it
    // as E_PARMVAL (ifeval.c:124-128); ngspice 44.2 ends the card with "out
    // of range for log", and so does ESPice. HSPICE's sign(x)·ln|x| (SpiceRack
    // #8) is SpiceRack's to translate.
    try t.expectEqual(@as(?anyerror, error.OpDidNotConverge), refusal("ngspice log\nv1 1 0 dc -2\nb1 o 0 v=log(v(1))\nr1 o 0 1\n.op\n.end\n"));
}

test "pow and pwr: numparam's in a .param or a value, the B parser's in a B, E or G expression and the .func bodies it calls" {
    // numparam's pow is C's and its pwr |x|^y (xpressn.c XFU_POW, XFU_PWR);
    // the B parser's pow is |x|^y and its pwr sign(x)·|x|^y (ptfuncs.c
    // PTpower, PTpwr). A parameter's text stays numparam's where a B card
    // reads it (q1, q2, b9), a .func body takes its caller's (b7, b8), and
    // an R reading v() is a B card (r2) where a constant one is not (r0,
    // r1). ngspice-44.2 and 45 printed every value (this deck, `op` with
    // numdgt=17). Red before (old binary, b9 and r2 dropped as refused):
    // n1, m2, n0, o2, o3, o7, o9, o11 and o12 read the other meaning.
    const p = try solve(
        \\pow and pwr by context
        \\.param p1={pow(-2,3)}
        \\.param p2={pwr(-2,3)}
        \\.param p3={pwr(-2,2.5)}
        \\.param p4={(-2)^3}
        \\.param p5={pow(0,0)+pwr(0,0)}
        \\.func fw(x) {pwr(x,3)}
        \\.func fp(x) {pow(x,3)}
        \\.param q1={fw(-2)}
        \\.param q2={fp(-2)}
        \\va a 0 dc -2
        \\vn1 n1 0 {p1}
        \\vn2 n2 0 {p2}
        \\vn3 n3 0 {p3}
        \\vn4 n4 0 {p4}
        \\vn5 n5 0 {p5}
        \\vq1 m1 0 {q1}
        \\vq2 m2 0 {q2}
        \\r0 n0 0 {10+pow(-2,3)}
        \\i0 0 n0 dc 1
        \\b1 o1 0 v=pow(-2,3)
        \\b2 o2 0 v=pwr(-2,3)
        \\b3 o3 0 v=pwr(-2,2.5)
        \\b4 o4 0 v=pow(-2,2.5)
        \\b5 o5 0 v=(-2)^3
        \\b6 o6 0 v=pow(0,0)+pwr(0,0)
        \\b7 o7 0 v=fw(-2)
        \\b8 o8 0 v=fp(-2)
        \\b9 o9 0 v=p1+p2+pwr(v(a),3)
        \\b10 o10 0 v=pow(v(a),3)
        \\e1 o11 0 value={pwr(-2,3)}
        \\g1 0 o12 cur={pwr(-2,3)}
        \\r12 o12 0 1
        \\r1 rm 0 r={10+pwr(-2,3)}
        \\i1 0 rm dc 1
        \\r2 sm 0 r={10+pwr(v(a),3)}
        \\i2 0 sm dc 1
        \\.op
        \\.end
    );
    defer p.deinit();
    const op = try requested(p, 0);
    const root = std.math.pow(f64, 2, 2.5); // ngspice: 5.65685424949238058
    for ([_]struct { []const u8, f64 }{
        .{ "v(n1)", -8 },    .{ "v(n2)", 8 },    .{ "v(n3)", root }, .{ "v(n4)", 8 },   .{ "v(n5)", 2 },
        .{ "v(m1)", 8 },     .{ "v(m2)", -8 },   .{ "v(n0)", 2 },    .{ "v(o1)", 8 },   .{ "v(o2)", -8 },
        .{ "v(o3)", -root }, .{ "v(o4)", root }, .{ "v(o5)", 8 },    .{ "v(o6)", 2 },   .{ "v(o7)", -8 },
        .{ "v(o8)", 8 },     .{ "v(o9)", -8 },   .{ "v(o10)", 8 },   .{ "v(o11)", -8 }, .{ "v(o12)", -8 },
        .{ "v(rm)", 18 },    .{ "v(sm)", 2 },
    }) |c| {
        const got = (try at(op, c[0], 0))[0];
        if (!(@abs(got - c[1]) <= 1e-12 * @abs(c[1]))) {
            std.debug.print("{s} is {d}, ngspice-44.2 {d}\n", .{ c[0], got, c[1] });
            return error.TestExpectedApproxEqRel;
        }
    }
    // C's pow(-2, 2.5) is NaN: ngspice-44.2 stops on the card that reads it
    // ("Error on line 3 or its substitute"); before, it read 5.657. Unread,
    // ngspice-44.2 runs the deck.
    try t.expectEqual(@as(?anyerror, error.NonFiniteParameter), refusal("numparam pow\n.param p={pow(-2,2.5)}\nvp p 0 {p}\nrp p 0 1\n.op\n.end\n"));
    try t.expectEqual(@as(?anyerror, null), refusal("numparam pow\n.param p={pow(-2,2.5)}\nvp a 0 1\nrp a 0 1\n.op\n.end\n"));
}
