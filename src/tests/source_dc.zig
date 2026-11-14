//! A V or I card's DC value, and the words its card takes. Oracle:
//! ngspice-44.2 (`ngspice -b`, .op, the card driving 1k), measured per
//! row: the bare number straight after the nodes beats every keyword,
//! else the last `dc`/`dc=`/I's `c=` wins; a number after `pulse(...)`,
//! `ac` (its phase), `pwl(...) r` or `td`, or a port's `portnum`, is no
//! DC value; a word outside vsrc.c's or isrc.c's table stops the deck.
//! Red before (the prebuilt espice of 2026-11-10): `portnum 2` on a pulse
//! port read 2 V where ngspice reads 0, `pwr 0.001` read 1 mV where
//! ngspice drives the port at sqrt(4·z0·pwr), `v1 a 0 1 dc=3` read 3 V,
//! `i1 0 a c=1m` 0 V, and `zork 3` and `pulse_v1=2` ran.
const std = @import("std");
const decks = @import("deck.zig");
const t = std.testing;

test "a V card's DC value is the bare number after its nodes, never one owed to a keyword" {
    const rows = [_]struct { card: []const u8, v: f64 }{
        .{ .card = "v1 a 0 3", .v = 3 },
        .{ .card = "v1 a 0 3 ac 1", .v = 3 },
        .{ .card = "v1 a 0 3 pulse(0 1 0 1p 1p 1 2)", .v = 3 },
        .{ .card = "v1 a 0 pulse(0 1 0 1p 1p 1 2) 3", .v = 0 },
        .{ .card = "v1 a 0 ac 1 3", .v = 0 },
        .{ .card = "v1 a 0 pwl(0 0 1 1) r 0", .v = 0 },
        .{ .card = "v1 a 0 pwl(0 0 1 1) td 1n", .v = 0 },
        .{ .card = "v1 a 0 1 dc=3", .v = 1 },
        .{ .card = "v1 a 0 dc 2 dc 3", .v = 3 },
        .{ .card = "i1 0 a c=1m", .v = 1 },
        .{ .card = "i1 0 a 1m dc=3m", .v = 1 },
        .{ .card = "i1 0 a dc=3m c=2m", .v = 2 },
        .{ .card = "i1 0 a c=2m dc=3m", .v = 3 },
    };
    var buf: [256]u8 = undefined;
    for (rows) |row| {
        const text = try std.fmt.bufPrint(&buf, "dc value\n{s}\nr1 a 0 1k\n.op\n.end\n", .{row.card});
        const p = try decks.solve(text);
        defer p.deinit();
        const got = try decks.at(try decks.resultOf(p, .op), 0, "v(a)");
        if (got != row.v) std.debug.print("{s}: v(a) = {d}, ngspice-44.2 {d}\n", .{ row.card, got, row.v });
        try t.expectEqual(row.v, got);
    }
}

test "a port's portnum is no DC value: the pulse port holds 0 V at the .op, as in ngspice-44.2" {
    const p = try decks.solve("ports\nv1 a 0 dc 0 portnum 1 z0 50\nr1 a 0 50\n" ++
        "v2 b 0 pulse(0 1 0 1p 1p 1 2) portnum 2 z0 1k\nr2 b 0 1g\n.op\n.end\n");
    defer p.deinit();
    try t.expectEqual(@as(f64, 0), try decks.at(try decks.resultOf(p, .op), 0, "v(b)"));
}

test "a port's pwr drive is refused, not read as its DC level" {
    try decks.expectRefused("pwr\nv1 a 0 pwr 0.001 freq 1g portnum 1\nr1 a 0 1k\n.op\n.end\n");
    try decks.expectRefused("pwr\nv1 a 0 dc 0 pwr=0.001 portnum 1\nr1 a 0 1k\n.op\n.end\n");
}

test "a word outside ngspice's V and I tables is refused, as ngspice-44.2 stops on it" {
    for ([_][]const u8{
        "v1 a 0 dc 1 zork 3",
        "v1 a 0 dc 1 zork=3",
        "v1 a 0 1 pulse_v1=2",
        "v1 a 0 1 c=2",
        "i1 0 a 1m zork",
        "i1 0 a pwl(0 1m 1 2m) r 0",
        "i1 0 a pwl(0 1m 1 2m) td 1n",
    }) |card| {
        var buf: [128]u8 = undefined;
        try decks.expectRefused(try std.fmt.bufPrint(&buf, "keys\n{s}\nr1 a 0 1k\n.op\n.end\n", .{card}));
    }
    // ESPice's own refusal: ngspice takes the last of `dc 2` and `dc=3`,
    // an order the parser does not keep.
    try decks.expectRefused("keys\nv1 a 0 dc 2 dc=3\nr1 a 0 1k\n.op\n.end\n");
}
