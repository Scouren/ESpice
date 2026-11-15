//! An X card's actual parameter is read in the caller's scope, as ngspice
//! reads it, also when it cannot fold at the card (a Monte Carlo draw).
//! Found by the ESPice language's opening example: `X1 ... inv wn={wn}`
//! under `sweep monte=` was refused at expression depth 64, the instance's
//! own `wn` resolving to itself (reader_expand.zig, reader_subst.zig).
//! Oracles: (1) the minimal deck runs; (2) a metamorphic relation that
//! catches the class, capture of a caller's name by the callee's formal:
//! renaming a subcircuit's formals (`p` to `q`) changes no trial's value,
//! with the actual `p={p}`, `p={p*2}`, a two-level nest, and an actual
//! naming another of the callee's formals (`p={r}`); (3) the
//! nominal run (trial 0) equals the deck run without the sweep, and the
//! analytic divider at the nominal value: v(out) = 1k / (1k + R1).

const std = @import("std");
const api = @import("espice");
const t = std.testing;

/// `{0s}` the formal's name, `{1s}` the actual's text, `{2s}` the analysis.
const flat =
    \\x actual
    \\.param p=agauss(1k, 100, 1)
    \\.subckt cell a b {0s}=5
    \\R1 a b {{{0s}}}
    \\.ends
    \\V1 in 0 1
    \\X1 in out cell {0s}={{{1s}}}
    \\R2 out 0 1k
    \\{2s}
    \\.end
    \\
;

/// The same through two levels: `{0s}` the outer formal, `{1s}` the
/// inner one.
const nested =
    \\x actual nested
    \\.param p=agauss(1k, 100, 1)
    \\.subckt cell a b {1s}=5
    \\R1 a b {{{1s}}}
    \\.ends
    \\.subckt outer a b {0s}=7
    \\X2 a b cell {1s}={{{0s}}}
    \\.ends
    \\V1 in 0 1
    \\X1 in out outer {0s}={{p}}
    \\R2 out 0 1k
    \\{2s}
    \\.end
    \\
;

/// An actual naming a global the callee also declares as a formal: `{0s}`
/// the formal set, `{1s}` the other formal, named `r` as the global or not.
const capture =
    \\x actual capture
    \\.param r=agauss(1k, 100, 1)
    \\.subckt cell a b {0s}=5 {1s}=3
    \\R1 a b {{{0s}}}
    \\.ends
    \\V1 in 0 1
    \\X1 in out cell {0s}={{r}}
    \\R2 out 0 1k
    \\{2s}
    \\.end
    \\
;

// ---- private ----

/// v(out) of every result of `deck`: the nominal run, then each trial.
fn vout(a: std.mem.Allocator, deck: []const u8) ![]const f64 {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "memory.cir" } } });
    defer p.deinit();
    try p.run_all();
    var out: std.ArrayList(f64) = .empty;
    for (0..p.query_count()) |i| try out.append(a, try at(try p.result(@fromBackingInt(@intCast(i)))));
    const runs = try p.run_results(t.allocator);
    defer t.allocator.free(runs);
    for (runs) |r| try out.append(a, try at(r));
    return out.items;
}

fn at(r: api.Result) !f64 {
    for (r.varnames, 0..) |v, i| if (std.mem.eql(u8, v, "v(out)")) return r.data[i];
    return error.MissingColumn;
}

test "an X card's actual reads the caller's name under Monte Carlo: the minimal deck runs" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try vout(a, try a.print(flat, .{ "p", "p", ".op sweep monte=5" }));
    try t.expectEqual(6, got.len);
}

test "renaming a subcircuit's formals changes no Monte Carlo trial, and the nominal run is the sweepless one" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sweep = ".op sweep monte=5";
    // Each case: the deck, its formals as written and renamed, the
    // analytic nominal v(out).
    inline for (.{
        .{ flat, .{ "p", "p" }, .{ "q", "p" }, 0.5 }, // R1 = p = 1k
        .{ flat, .{ "p", "p*2" }, .{ "q", "p*2" }, 1.0 / 3.0 }, // R1 = 2k
        .{ nested, .{ "p", "p" }, .{ "po", "q" }, 0.5 },
        // No recursion here: read in its own instance, `r` was the
        // callee's 3 ohm, a wrong number with no error.
        .{ capture, .{ "p", "r" }, .{ "p", "s" }, 0.5 },
    }) |c| {
        const deck = c[0];
        const same = try a.print(deck, c[1] ++ .{sweep});
        const want = try vout(a, try a.print(deck, c[2] ++ .{sweep}));
        const got = try vout(a, same);
        try t.expectEqual(6, want.len);
        try t.expectEqualSlices(f64, want, got);
        // The trials draw: not every one is the nominal.
        var drawn: usize = 0;
        for (got[1..]) |v| drawn += @intFromBool(v != got[0]);
        try t.expect(drawn > 0);
        try t.expectApproxEqRel(@as(f64, c[3]), got[0], 1e-9);
        try t.expectEqualSlices(f64, got[0..1], try vout(a, try a.print(deck, c[1] ++ .{".op"})));
    }
}
