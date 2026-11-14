//! An HDL `.include` compiles the file ngspice's include order finds: the
//! name in the work directory first, then beside the naming deck (ngspice-45
//! inpcom.c inp_pathresolve_at, lines 2207-2252). `prepare.loadModels`
//! compiles that file and never resolves its name a second time.
//! Oracle: the divider's closed form. 1 V through R1 = 100 into the model's
//! R gives v(out) = R / (100 + R): 0.5 for the work directory's x.va
//! (R = 100), 0.75 for the deck directory's decoy (R = 300).
//! Red before (source_search `locate` returning paths relative to the work
//! directory, source.zig `expand` without `.cwd`): the expanded `.include`
//! named the work directory's file relative to the work directory, and
//! loadModels joined it onto the deck's directory. The first run compiled
//! the decoy (v(out) = 0.75). The second failed: the path beside the deck,
//! relative, was joined onto the deck's directory again and named no file.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

/// `va_order`, a Verilog-A resistor; `{s}` is its R in ohms.
const model =
    \\`include "disciplines.vams"
    \\module va_order(p, n);
    \\    inout p, n;
    \\    electrical p, n;
    \\    parameter real R = {s} from (0:inf);
    \\    analog begin
    \\        I(p, n) <+ V(p, n) / R;
    \\    end
    \\endmodule
    \\
;

// ---- private ----

/// v(out) of the divider deck at `path`.
fn vout(path: []const u8) !f64 {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .file = path } });
    defer p.deinit();
    try p.run_all();
    return decks.at(try decks.resultOf(p, .op), 0, "v(out)");
}

test "an HDL .include compiles the work directory's file, then the deck directory's, as ngspice includes" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The work directory is the build root: `name` reaches m/x.va from
    // there, and the decoy from the deck's directory d.
    const name = try a.print(".zig-cache/tmp/{s}/m/x.va", .{tmp.sub_path});
    const decoy = try a.print("d/{s}", .{name});
    try tmp.dir.createDirPath(io, "m");
    try tmp.dir.createDirPath(io, std.fs.path.dirname(decoy).?);
    try tmp.dir.writeFile(io, .{ .sub_path = "m/x.va", .data = try a.print(model, .{"100.0"}) });
    try tmp.dir.writeFile(io, .{ .sub_path = decoy, .data = try a.print(model, .{"300.0"}) });
    const text = "include order\n.include '{s}'\nN1 out 0 va_order\nR1 in out 100\nV1 in 0 1\n.op\n.end\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "d/deck.sp", .data = try a.print(text, .{name}) });
    const path = try a.print(".zig-cache/tmp/{s}/d/deck.sp", .{tmp.sub_path});
    try t.expectApproxEqRel(@as(f64, 0.5), try vout(path), 1e-12);
    // Without the work directory's file, the one beside the deck.
    try tmp.dir.deleteFile(io, "m/x.va");
    try t.expectApproxEqRel(@as(f64, 0.75), try vout(path), 1e-12);
}
