//! A passive card at circuit temperature T with `dtemp=D` solves as at
//! `.temp T+D`, and with `temp=X` as at `.temp X`, a `dtemp` beside it
//! ignored; a K card's M follows its two L cards the same way. Oracle:
//! metamorphic, from ngspice's one temperature difference
//! `(temp + dtemp) - tnom` with dtemp zeroed under a given temp
//! (captemp.c:39-52,77; indtemp.c:35-48,63; restemp.c:35-47,83; muttemp.c
//! reads each L after it). Every row must also move between T and T+D, so
//! a card that ignores temperature fails instead of agreeing with itself,
//! as C and L once did.
const std = @import("std");
const api = @import("espice");
const deck = @import("deck.zig");
const t = std.testing;
const Allocator = std.mem.Allocator;

/// Cards whose value `probe` reads at the 1 MHz point: `bench` drives
/// them and holds their models, and each `$` takes the temperature pairs.
const Row = struct { bench: []const u8, card: []const u8, probe: []const u8 };

/// v(n) is the card's impedance.
const by_current = "i1 0 n ac 1\n";
/// i(v1) is minus the card's admittance.
const by_voltage = "v1 n 0 dc 0 ac 1\n";

const rows = [_]Row{
    .{ .bench = by_voltage, .card = "c1 n 0 1n tc1=0.01 tc2=1e-4$", .probe = "i(v1)" },
    .{ .bench = by_voltage ++ ".model cm c(cap=2n tc1=-3e-3 tnom=50)\n", .card = "c1 n 0 cm$", .probe = "i(v1)" },
    .{ .bench = by_current, .card = "l1 n 0 10u tc1=5e-3 tc2=-2e-5$", .probe = "v(n)" },
    .{ .bench = by_current ++ ".model lm l(ind=20u tc2=3e-5 tnom=50)\n", .card = "l1 n 0 lm$", .probe = "v(n)" },
    .{ .bench = by_current, .card = "r1 n 0 1k tc1=3e-3 tc2=1e-5$", .probe = "v(n)" },
    .{
        .bench = "v1 in 0 ac 1\nr1 in a 10\nrb b 0 50\n",
        .card = "l1 a 0 10u tc1=5e-3 tc2=-2e-5$\nl2 b 0 40u tc1=-3e-3 tc2=1e-5$\nk1 l1 l2 0.6",
        .probe = "v(b)",
    },
};

/// The circuit temperature T, the offset D and the instance temperature X,
/// in degC; each move is tens of percent on every row.
const t_circuit = 27;
const d_offset = 33;
const x_instance = -20;

// ---- private ----

/// The first relation `row` breaks, null when it keeps all four.
fn broken(a: Allocator, row: Row) !?[]const u8 {
    const moved = try at(a, row, t_circuit + d_offset, "");
    if (!close(try at(a, row, t_circuit, try a.print(" dtemp={d}", .{d_offset})), moved)) return "dtemp=D at T is not T+D";
    if (close(try at(a, row, t_circuit, ""), moved)) return "the value is the same at T and T+D";
    const fixed = try at(a, row, x_instance, "");
    if (!close(try at(a, row, t_circuit, try a.print(" temp={d}", .{x_instance})), fixed)) return "temp=X is not .temp X";
    if (!close(try at(a, row, t_circuit, try a.print(" temp={d} dtemp={d}", .{ x_instance, d_offset })), fixed)) return "dtemp is not ignored under temp=X";
    return null;
}

/// `row`'s probe at `.temp celsius`, `extra` in place of each `$`.
fn at(a: Allocator, row: Row, celsius: i32, extra: []const u8) !std.math.Complex(f64) {
    const cards = try std.mem.replaceOwned(u8, a, row.card, "$", extra);
    const text = try a.print("tempco\n.temp {d}\n{s}{s}\n.ac lin 1 1meg 1meg\n.end\n", .{ celsius, row.bench, cards });
    const p = try deck.solve(text);
    defer p.deinit();
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if (!(try p.query_info(id)).requested) continue;
        const r = try p.result(id);
        const k = try deck.column(r, row.probe) * 2;
        return .init(r.data[k], r.data[k + 1]);
    }
    return error.MissingQuery;
}

/// Equal to rounding: the two decks reach one temperature difference by
/// two sums, a few ulps apart, through the same linear solve.
fn close(x: std.math.Complex(f64), y: std.math.Complex(f64)) bool {
    return x.sub(y).magnitude() <= 1e-12 * @max(x.magnitude(), y.magnitude());
}

test "dtemp=D at T is .temp T+D, temp=X is .temp X, and both move every passive card" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every broken row, so one run names all of them.
    var failed: std.ArrayList(u8) = .empty;
    for (rows) |row| if (try broken(a, row)) |why| try failed.print(a, "{s}: {s}\n", .{ row.card, why });
    try t.expectEqualStrings("", failed.items);
}
