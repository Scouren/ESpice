//! Tests of the ESPice language's statistics and reliability directives,
//! `.variation .mosra .appendmodel .sample`. Oracles: the legacy cards
//! written by hand from the reader that reads them (reader_sweeps.zig
//! `readVariation`: the part markers, `<type> <model> p=sigma` and
//! `<letter> p=sigma` rows, `5%` relative, `'expr'` a sigma expression;
//! reader_directives.zig `readMosra` (SimMode 0 or 2, RelMode 0 to 2),
//! `readSample` and `.appendmodel src mosra dst type`); a code for each
//! refusal; and the legacy reader as reference implementation: a deck
//! and its legacy twin, spelled as HSPICE's manual spells the cards,
//! parse (`Netlist.parse`) to the same variation rows, MOSRA settings,
//! bindings, sampling and models.

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const netlist = @import("../Netlist.zig");
const Netlist = netlist.Netlist;
const Value = netlist.Value;
const Code = lang.diag.Code;

// ---- private ----

/// Lowers `.espice 1` + `body` as an include (no title line) and compares.
fn expectLowered(body: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", body, "\n" });
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .include);
    if (got.diags.len != 0) {
        for (got.diags) |d| std.debug.print("{any} at {any}: {s}\n", .{ d.code, lang.diag.lineCol(src, d.at), d.subject });
        return error.UnexpectedRows;
    }
    try testing.expectEqualStrings(want, got.text);
}

/// What the reader made of the statistics and reliability cards, and the models.
fn dump(a: std.mem.Allocator, nl: *const Netlist) ![]const u8 {
    var w: std.ArrayList(u8) = .empty;
    for (nl.models) |m| {
        try w.print(a, "model {s} {s}", .{ m.name, m.kind });
        for (m.kv) |kv| {
            try w.print(a, " {s}=", .{kv.key});
            try value(a, &w, nl, kv.value);
        }
        try w.append(a, '\n');
    }
    for (nl.deck.variations) |v| {
        try w.print(a, "variation {} {t} '{s}' {c} {s} {e} {}", .{ v.per_device, v.dist, v.model, if (v.letter == 0) '-' else v.letter, v.param, v.value, v.relative });
        try value(a, &w, nl, .{ .expr = v.sigma });
        try w.append(a, '\n');
    }
    if (nl.deck.mosra) |m| try w.print(a, "mosra {e} {e} {e} {} {d} {e} {e} {e} {e} {?e}\n", .{
        m.rel_total_time, m.rel_start_time, m.rel_step,      m.aged_runs,      m.rel_mode,
        m.aging_start,    m.aging_stop,     m.hci_threshold, m.nbti_threshold, m.deg_f,
    });
    for (nl.deck.appendmodels) |m| try w.print(a, "appendmodel {s} {s}\n", .{ m.src, m.dst });
    if (nl.deck.sample) |s| try w.print(a, "sample {e} {e} {e}\n", .{ s.fs, s.max_fold, s.beta });
    return w.items;
}

fn value(a: std.mem.Allocator, w: *std.ArrayList(u8), nl: *const Netlist, v: Value) !void {
    switch (v) {
        .num => |x| try w.print(a, " {e}", .{x}),
        .name => |s| try w.print(a, " '{s}'", .{s}),
        .expr => |span| {
            try w.appendSlice(a, " expr[");
            for (nl.exprOps(span)) |op| try w.print(a, "{t}:{d}:{d} ", .{ op.code, if (op.code == .num) nl.consts[op.a] else @as(f64, @floatFromInt(op.a)), op.b });
            try w.append(a, ']');
        },
        .group => |g| {
            try w.appendSlice(a, " (");
            for (g.items) |item| try value(a, w, nl, item);
            try w.append(a, ')');
        },
    }
}

test ".variation: each part between its markers, element rows by letter" {
    try expectLowered(
        \\.variation {
        \\    global {
        \\        nmos nch vto=20mV kp=1%
        \\    }
        \\    local {
        \\        nmos nch vto=avt*1um/sqrt(w*l)
        \\    }
        \\    element {
        \\        resistor r=5%
        \\        mosfet w=2.5%
        \\        capacitor c=1fF
        \\    }
        \\}
    ,
        \\.variation
        \\.global_variation
        \\nmos nch vto=20m kp=1%
        \\.end_global_variation
        \\.local_variation
        \\nmos nch vto='avt*1u/sqrt(w*l)'
        \\.end_local_variation
        \\.element_variation
        \\r r=5%
        \\m w=2.5%
        \\c c=1f
        \\.end_element_variation
        \\.end_variation
        \\
    );
}

test ".mosra, .appendmodel and .sample" {
    try expectLowered(
        \\.mosra reltotaltime=10s
        \\.mosra reltotaltime=10s relstarttime=1s relstep=3s simmode=degradation relmode=bti agingstart=1ns agingstop=5ns hcithreshold=0.1V nbtithreshold=0.2V degf=50mV
        \\.mosra reltotaltime=1 simmode=aged relmode=both
        \\.mosra reltotaltime=1 relmode=hci
        \\.appendmodel from=nra to=pch type=pmos
        \\.sample fs=1GHz
        \\.sample fs=1GHz tol=0.01 numf=10 maxfld=5 beta=0.5
    ,
        \\.mosra reltotaltime=10
        \\.mosra reltotaltime=10 relstarttime=1 relstep=3 simmode=0 relmode=2 agingstart=1n agingstop=5n hcithreshold=0.1 nbtithreshold=0.2 degf=50m
        \\.mosra reltotaltime=1 simmode=2 relmode=0
        \\.mosra reltotaltime=1 relmode=1
        \\.appendmodel nra mosra pch pmos
        \\.sample fs=1g
        \\.sample fs=1g tol=0.01 numf=10 maxfld=5 beta=0.5
        \\
    );
}

test "every statistics refusal is one coded row" {
    const Case = struct { []const u8, Code };
    for ([_]Case{
        .{ ".variation {\n    option {\n    }\n}", .unknown_word },
        .{ ".variation {\n    nmos nch vto=1\n}", .misplaced },
        .{ ".variation {\n    element {\n        widget r=5%\n    }\n}", .unknown_word },
        .{ ".variation {\n    global {\n        nmos nch\n    }\n}", .arity },
        .{ ".variation {\n    local {\n        nmos vto=1\n    }\n}", .arity },
        .{ ".variation {\n    element {\n        resistor r=v(a)\n    }\n}", .reads_circuit },
        .{ ".mosra relstep=1s", .missing_key },
        .{ ".mosra reltotaltime=1V", .wrong_unit },
        .{ ".mosra reltotaltime=1s simmode=2", .wrong_kind },
        .{ ".mosra reltotaltime=1s relmode=nbti", .unknown_word },
        .{ ".mosra reltotaltime=1s dec=1", .unknown_key },
        .{ ".appendmodel from=a to=b type=npn", .unknown_word },
        .{ ".appendmodel from=a type=nmos", .missing_key },
        .{ ".sample fs=1ns", .wrong_unit },
        .{ ".sample fs=1GHz numf=2.5", .fraction },
        .{ ".sample fs=1GHz foo=1", .unknown_key },
    }) |c| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", c[0], "\n.param ok = 1\n" });
        const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .top);
        errdefer std.debug.print("{s}: {any}\n", .{ c[0], got.diags });
        try testing.expectEqual(1, got.diags.len);
        try testing.expectEqual(c[1], got.diags[0].code);
        try testing.expect(std.mem.endsWith(u8, got.text, ".param ok=1\n"));
    }
}

test "statistics and reliability read as their legacy twin" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const new =
        \\.espice 1
        \\.title "stats"
        \\.param avt = 5mV
        \\.model nch bsim4 type=n vth0=0.45
        \\.model pch psp103_nqs type=p
        \\.model nra mosra tit0=1e-4 tn=0.25
        \\.variation {
        \\    global {
        \\        nmos nch vth0=20mV u0=1%
        \\    }
        \\    local {
        \\        nmos nch vth0=avt*1um/sqrt(w*l)
        \\        pmos pch toxo=0.5%
        \\    }
        \\    element {
        \\        resistor r=5%
        \\        capacitor c=1fF
        \\    }
        \\}
        \\.mosra reltotaltime=10s relstep=3s simmode=aged relmode=hci agingstart=1ns agingstop=5ns hcithreshold=0.1V nbtithreshold=0.2V degf=50mV
        \\.appendmodel from=nra to=nch type=nmos
        \\.sample fs=1GHz tol=0.01 numf=10 maxfld=5 beta=0.5
        \\
    ;
    const legacy =
        \\stats
        \\.param avt=5m
        \\.model nch nmos (level=14 vth0=0.45)
        \\.model pch pspnqs103va type=-1
        \\.model nra mosra level=1 tit0=1e-4 tn=0.25
        \\.variation
        \\.global_variation
        \\nmos nch vth0=20m u0=1 %
        \\.end_global_variation
        \\.local_variation
        \\nmos nch vth0='avt*1u/sqrt(w*l)'
        \\pmos pch toxo=0.5%
        \\.end_local_variation
        \\.element_variation
        \\R r=5 %
        \\C c=1f
        \\.end_element_variation
        \\.end_variation
        \\.MOSRA RelTotalTime=10 RelStep=3 SimMode=2 RelMode=1 AgingStart=1n AgingStop=5n HciThreshold=0.1 NbtiThreshold=0.2 DegF=50m
        \\.appendmodel nra MOSRA nch NMOS
        \\.SAMPLE FS=1g TOL=0.01 NUMF=10 MAXFLD=5 BETA=0.5
        \\
    ;
    const got = try dump(a, &try netlist.parse(a, new));
    const want = try dump(a, &try netlist.parse(a, legacy));
    // A capture that dropped the cards would compare equal and empty.
    try testing.expect(std.mem.count(u8, want, "variation ") == 6 and std.mem.indexOf(u8, want, "\nmosra ") != null);
    try testing.expectEqualStrings(want, got);
}
