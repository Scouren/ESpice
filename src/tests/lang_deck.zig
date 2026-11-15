//! A deck in the ESPice language run from disk through the real
//! `Jobs.prepare` path (`Problem.init` with a file source): its header
//! detected and lowered before `.alter` runs split, an `.include` of a
//! legacy file, a `.hdl` Verilog-A module instance, and a legacy deck that
//! includes a file in the language (source.zig's hook).
//! Oracle: the legacy reader as reference implementation. Each deck has a
//! legacy twin written by hand from the spec's Legacy entries; both run,
//! and every query's columns and points, and the printed `.meas` text,
//! are the same bit for bit (the two read to the same cards).

const std = @import("std");
const api = @import("espice");
const t = std.testing;

/// A Verilog-A resistor whose ports are declared `(p, n)`.
const va_r =
    \\`include "disciplines.vams"
    \\module va_r(p, n);
    \\    inout p, n;
    \\    electrical p, n;
    \\    parameter real r = 1.0 from (0:inf);
    \\    analog I(p, n) <+ V(p, n) / r;
    \\endmodule
    \\
;

/// Two equal resistors, in each dialect.
const cells_legacy = "* legacy cells\n.subckt div2 a b g\nR1 a b 1k\nR2 b g 1k\n.ends\n";
const cells_new =
    \\.espice 1
    \\.subckt div2 (a b g) {
    \\    R1 (a b) resistor 1kOhm
    \\    R2 (n=g p=b) resistor 1kOhm
    \\}
    \\
;

const top_new =
    \\.espice 1
    \\.title "lang deck"
    \\.include "cells.sp"
    \\.hdl "va_r.va"
    \\.param rl = 1kOhm
    \\V1    (in 0)              vsource 1V
    \\X1    (a=in b=mid g=0)    div2
    \\N1    (mid 0)             va_r r=2k
    \\Rload (mid 0)             resistor rl
    \\.op
    \\.dc V1=lin(0, 1V, step=0.5V)
    \\.meas dc vm = find(v(mid), at=1)
    \\.alter {
    \\    .param rl = 2kOhm
    \\}
    \\
;

const top_legacy =
    \\lang deck
    \\.include "cells.sp"
    \\.hdl "va_r.va"
    \\.param rl=1k
    \\V1 in 0 DC 1
    \\X1 in mid 0 div2
    \\N1 mid 0 va_r r=2k
    \\Rload mid 0 {rl}
    \\.op
    \\.dc V1 0 1 0.5
    \\.meas dc vm find v(mid) at=1
    \\.alter
    \\.param rl=2k
    \\.end
    \\
;

/// A legacy deck reading its cells from a file; `{s}` names the file.
const reverse = "legacy includes {s}\n.include \"{s}\"\nV1 in 0 1\nX1 in mid 0 div2\n.op\n.end\n";

// ---- private ----

fn run(path: []const u8) !*api.Problem {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .file = path } });
    errdefer p.deinit();
    try p.run_all();
    return p;
}

/// Runs the decks at `new` and `legacy`, `queries` queries each (the
/// `.alter` runs' included); every query and measure agrees.
fn expectTwins(new: []const u8, legacy: []const u8, queries: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const want = try run(legacy);
    defer want.deinit();
    const got = try run(new);
    defer got.deinit();
    try t.expectEqual(queries, want.query_count());
    try t.expectEqual(want.query_count(), got.query_count());
    for (0..want.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        try t.expectEqual((try want.query_info(id)).kind, (try got.query_info(id)).kind);
        const w = try want.result(id);
        const g = try got.result(id);
        try t.expectEqual(w.npoints, g.npoints);
        try t.expectEqual(w.varnames.len, g.varnames.len);
        for (w.varnames, g.varnames) |wn, gn| try t.expectEqualStrings(wn, gn);
        try t.expectEqualSlices(f64, w.data, g.data);
    }
    try t.expectEqualStrings(try measures(arena.allocator(), want), try measures(arena.allocator(), got));
}

fn measures(a: std.mem.Allocator, p: *api.Problem) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    var errors: std.Io.Writer.Allocating = .init(a);
    try p.print_measures(&text.writer, &errors.writer);
    try t.expectEqualStrings("", errors.written());
    return text.written();
}

test "a deck in the language runs from disk as its legacy twin: an include, a module, .alter, and the reverse include" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try a.print(".zig-cache/tmp/{s}/", .{tmp.sub_path});
    for ([_][2][]const u8{
        .{ "va_r.va", va_r },                                                  .{ "cells.sp", cells_legacy },
        .{ "cells_new.sp", cells_new },                                        .{ "top.sp", top_new },
        .{ "twin.sp", top_legacy },                                            .{ "rev.sp", try a.print(reverse, .{ "cells_new.sp", "cells_new.sp" }) },
        .{ "rev_twin.sp", try a.print(reverse, .{ "cells.sp", "cells.sp" }) },
    }) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    try expectTwins(try std.mem.concat(a, u8, &.{ dir, "top.sp" }), try std.mem.concat(a, u8, &.{ dir, "twin.sp" }), 4);
    try expectTwins(try std.mem.concat(a, u8, &.{ dir, "rev.sp" }), try std.mem.concat(a, u8, &.{ dir, "rev_twin.sp" }), 1);
}

test "a deck in the language that does not lower fails Problem.init with ParseError" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.sp", .data = ".espice 1\nR1 (a 0) resistor 1M\n.tran stop=1V step=1ns\n" });
    const path = try arena.allocator().print(".zig-cache/tmp/{s}/bad.sp", .{tmp.sub_path});
    try t.expectError(error.ParseError, api.Problem.init(t.allocator, t.io, .{ .source = .{ .file = path } }));
}
