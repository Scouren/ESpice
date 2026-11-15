//! Free instance names (docs/using/language.md, Instances): the ESPice
//! language's lowering writes `<letter>@<name>` and `?@<name>` heads, so a
//! device's name need not start with its kind letter. Oracle: a
//! metamorphic relation against the legacy reader. Each free-named deck
//! has a conventionally named twin; renaming the twin's devices (and X
//! paths) gives the free deck, so every query must give the same points,
//! the same columns once the names are mapped back, and the same `.meas`
//! text. The names are chosen so that no first letter matches its kind:
//! a pass that infers a kind from a name's first letter fails here.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

/// A legacy deck, its free-named twin, and each free name's legacy name.
const Twin = struct { legacy: []const u8, free: []const u8, names: []const [2][]const u8 };

const top_names = [_][2][]const u8{
    .{ "supply", "vsup" }, .{ "pull", "rpull" }, .{ "load", "cload" }, .{ "sink", "iload" },
    .{ "copy", "fcopy" },  .{ "out2", "rout2" },
};

/// `.dc` of a source, `.tf`, `.noise` with a source,
/// `.sens`, an F naming the source, `i()` columns and `.meas` on one.
const dc_family: Twin = .{
    .legacy =
    \\free names: dc family
    \\vsup in 0 dc 2 ac 1
    \\rpull in out 1k
    \\cload out 0 1n
    \\rgnd out 0 3k
    \\iload out 0 1m
    \\fcopy o2 0 vsup 2
    \\rout2 o2 0 1k
    \\.op
    \\.dc vsup 0 2 1
    \\.tf v(out) vsup
    \\.noise v(out) vsup dec 2 1 100
    \\.sens v(out)
    \\.meas dc isup find i(vsup) at=1
    \\.end
    \\
    ,
    .free =
    \\free names: dc family
    \\v@supply in 0 dc 2 ac 1
    \\r@pull in out 1k
    \\c@load out 0 1n
    \\r@rgnd out 0 3k
    \\i@sink out 0 1m
    \\f@copy o2 0 supply 2
    \\r@out2 o2 0 1k
    \\.op
    \\.dc supply 0 2 1
    \\.tf v(out) supply
    \\.noise v(out) supply dec 2 1 100
    \\.sens v(out)
    \\.meas dc isup find i(supply) at=1
    \\.end
    \\
    ,
    .names = &top_names,
};

/// `.dc` of a resistor.
const dc_resistor: Twin = .{
    .legacy = "dc resistor\nvsup in 0 1\nrpull in out 1k\nrgnd out 0 1k\n.dc rpull 1k 3k 1k\n.end\n",
    .free = "dc resistor\nv@supply in 0 1\nr@pull in out 1k\nr@rgnd out 0 1k\n.dc pull 1k 3k 1k\n.end\n",
    .names = &top_names,
};

/// `.step` of a source.
const step_source: Twin = .{
    .legacy = "step source\nvsup in 0 1\nrpull in out 1k\nrgnd out 0 1k\n.step vsup list 1 2\n.op\n.end\n",
    .free = "step source\nv@supply in 0 1\nr@pull in out 1k\nr@rgnd out 0 1k\n.step supply list 1 2\n.op\n.end\n",
    .names = &top_names,
};

/// `.step` of a resistor.
const step_resistor: Twin = .{
    .legacy = "step resistor\nvsup in 0 1\nrpull in out 1k\nrgnd out 0 1k\n.step rpull list 1k 3k\n.op\n.end\n",
    .free = "step resistor\nv@supply in 0 1\nr@pull in out 1k\nr@rgnd out 0 1k\n.step pull list 1k 3k\n.op\n.end\n",
    .names = &top_names,
};

/// An R's and a C's `m=` in their `@dev[...]` values (prepared_opvars
/// `cardFactor`).
const opvars: Twin = .{
    .legacy = "opvars\nvsup in 0 1\nrpull in out 1k m=2\ncload out 0 1n m=3\n.save v(out) @rpull[r] @cload[capacitance]\n.op\n.end\n",
    .free = "opvars\nv@supply in 0 1\nr@pull in out 1k m=2\nc@load out 0 1n m=3\n.save v(out) @pull[r] @load[capacitance]\n.op\n.end\n",
    .names = &top_names,
};

/// Inside a subcircuit instantiated by a `?@` card: F, H and W naming a
/// sensing source that does not start with v, K naming inductors that do
/// not start with l, a B source reading `i()` of that source, and a `.meas`
/// on the flattened source's current.
const in_subckt: Twin = .{
    .legacy =
    \\free names: subcircuit references
    \\vdd top 0 dc 1 pulse(0 1 1n 1n 1n 4n 10n)
    \\xamp top out cell
    \\rl out 0 1k
    \\.subckt cell a y
    \\vsense a m 0
    \\rm m 0 1k
    \\fmirror y 0 vsense 2
    \\hhop h 0 vsense 100
    \\rh h 0 1k
    \\wgate y w vsense swmod
    \\rw w 0 1k
    \\lcoil1 a c1 1u
    \\rc1 c1 0 1
    \\lcoil2 c2 0 1u
    \\rc2 c2 0 1
    \\ktie lcoil1 lcoil2 0.5
    \\bdrive d 0 v={i(vsense)*1k}
    \\rd d 0 1k
    \\.model swmod csw it=0.1m ih=0
    \\.ends
    \\.op
    \\.tran 1n 10n
    \\.meas tran isense find i(v.xamp.vsense) at=5n
    \\.end
    \\
    ,
    .free =
    \\free names: subcircuit references
    \\vdd top 0 dc 1 pulse(0 1 1n 1n 1n 4n 10n)
    \\?@amp (top out) cell
    \\rl out 0 1k
    \\.subckt cell a y
    \\v@sense a m 0
    \\rm m 0 1k
    \\f@mirror y 0 sense 2
    \\h@hop h 0 sense 100
    \\rh h 0 1k
    \\?@gate (n=w p=y) swmod probe=sense
    \\rw w 0 1k
    \\l@coil1 a c1 1u
    \\rc1 c1 0 1
    \\l@coil2 c2 0 1u
    \\rc2 c2 0 1
    \\k@tie coil1 coil2 0.5
    \\b@drive d 0 v={i(sense)*1k}
    \\rd d 0 1k
    \\.model swmod csw it=0.1m ih=0
    \\.ends
    \\.op
    \\.tran 1n 10n
    \\.meas tran isense find i(v.amp.sense) at=5n
    \\.end
    \\
    ,
    .names = &.{
        .{ "amp", "xamp" },     .{ "sense", "vsense" }, .{ "mirror", "fmirror" }, .{ "hop", "hhop" },
        .{ "gate", "wgate" },   .{ "coil1", "lcoil1" }, .{ "coil2", "lcoil2" },   .{ "tie", "ktie" },
        .{ "drive", "bdrive" },
    },
};

// ---- private ----

/// Runs both decks of `twin` and expects every query to agree.
fn expectTwins(twin: Twin) !void {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try decks.solve(twin.legacy);
    defer want.deinit();
    const got = try decks.solve(twin.free);
    defer got.deinit();
    try t.expectEqual(want.query_count(), got.query_count());
    for (0..want.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        try t.expectEqual((try want.query_info(id)).kind, (try got.query_info(id)).kind);
        const w = try want.result(id);
        const g = try got.result(id);
        try t.expectEqual(w.npoints, g.npoints);
        try t.expectEqual(w.varnames.len, g.varnames.len);
        for (w.varnames, g.varnames) |wn, gn| try t.expectEqualStrings(wn, try renamed(a, gn, twin.names));
        try t.expectEqual(w.data.len, g.data.len);
        for (w.data, g.data) |x, y| try t.expect(@abs(x - y) <= 1e-12 * @max(@abs(x), @abs(y)));
    }
    try t.expectEqualStrings(try measures(a, want), try measures(a, got));
}

/// `name` with every word (a run of letters and digits: `.sens` writes
/// `<device>_<parameter>`) that is a free name of `names` replaced by its
/// legacy name.
fn renamed(a: std.mem.Allocator, name: []const u8, names: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) {
        var j = i;
        while (j < name.len and std.ascii.isAlphanumeric(name[j])) j += 1;
        if (j == i) {
            try out.append(a, name[i]);
            i += 1;
            continue;
        }
        const word = name[i..j];
        const legacy = for (names) |n| {
            if (std.ascii.eqlIgnoreCase(n[0], word)) break n[1];
        } else word;
        try out.appendSlice(a, legacy);
        i = j;
    }
    return out.items;
}

/// The `.meas` text `p` prints; it names measures, never devices.
fn measures(a: std.mem.Allocator, p: *api.Problem) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    var errors: std.Io.Writer.Allocating = .init(a);
    try p.print_measures(&text.writer, &errors.writer);
    if (errors.written().len > 0) std.debug.print("{s}", .{errors.written()});
    try t.expectEqual(@as(usize, 0), errors.written().len);
    return text.written();
}

test "a free-named (<letter>@<name>, ?@) deck gives its conventionally named twin's results, the names mapped back" {
    // Every twin runs, so one failure does not hide another's.
    var failed: usize = 0;
    for ([_]Twin{ dc_family, dc_resistor, step_source, step_resistor, opvars, in_subckt }) |twin| expectTwins(twin) catch |err| {
        std.debug.print("twin '{s}': {t}\n", .{ twin.legacy[0 .. std.mem.indexOfScalar(u8, twin.legacy, '\n') orelse 0], err });
        failed += 1;
    };
    try t.expectEqual(0, failed);
}
