//! Tests for the model catalog and HDL loader error propagation. Oracles:
//! `byName` and `modelName` as inverses, the declared error of the first
//! bad file in list order with the library left at its built-ins, and the
//! generated Model and Instance types for every alias a models/*.va file
//! declares (each model's file owns its key set; the binder has no table).
const std = @import("std");
const bind = @import("device_abi").bind;
const catalog = @import("../catalog.zig");
const loader = @import("../loader.zig");
const Library = @import("../Library.zig");

const no_paths: loader.BuildPaths = .{ .work_dir = "", .contract = "", .dyn = "", .gompute = "", .device_abi = "", .core = "" };

/// Catalog models whose models/ file is not `<name>.va`: build.zig's
/// `upstream_models` rows that rename. A file with aliases and no catalog
/// model fails the alias test, so a new rename lands here.
const renamed = std.StaticStringMap([]const u8).initComptime(.{
    .{ "bsimsoi_va", "bsimsoi" },      .{ "l_utsoi", "L_UTSOI_102" },    .{ "hisimhv_va", "hisimhv" },
    .{ "hicumL2_va", "hicumL2_v320" }, .{ "hicumL0", "hicumL0_v2p1p0" }, .{ "mextram", "bjt505" },
    .{ "mextram_t", "bjt505t" },       .{ "mvsg", "mvsg_cmc_5.0.0" },
});

// ---- private ----

/// The card keys .va source `text` declares as §3.4.7 aliases, lowercased
/// as a card hands them over: each `aliasparam` name, and the first
/// argument of each use of a macro whose name holds ALIAS, whatever that
/// macro expands to. Comments are skipped.
fn aliasKeys(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    var macros: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, try uncommented(arena, text), '\n');
    while (lines.next()) |line| {
        const s = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, s, "`define")) {
            const name = ident(std.mem.trimStart(u8, s["`define".len..], " \t"));
            if (std.ascii.findIgnoreCase(name, "alias") != null) try macros.append(arena, name);
            continue;
        }
        for (0..line.len) |i| {
            const key = ident(aliasAt(line, i, macros.items) orelse continue);
            if (key.len > 0) try keys.append(arena, try std.ascii.allocLowerString(arena, key));
        }
    }
    return keys.items;
}

/// The text after `aliasparam` or after `` `MACRO( `` (one of `macros`)
/// when one starts at `line[i]`, else null.
fn aliasAt(line: []const u8, i: usize, macros: []const []const u8) ?[]const u8 {
    const blank = " \t";
    if (i > 0 and isIdent(line[i - 1])) return null;
    if (std.mem.startsWith(u8, line[i..], "aliasparam")) return std.mem.trimStart(u8, line[i + "aliasparam".len ..], blank);
    if (line[i] != '`') return null;
    const rest = line[i + 1 ..];
    const name = ident(rest);
    for (macros) |m| if (std.mem.eql(u8, name, m)) {
        const args = std.mem.trimStart(u8, rest[name.len..], blank);
        if (args.len == 0 or args[0] != '(') return null;
        return std.mem.trimStart(u8, args[1..], blank);
    };
    return null;
}

/// `text` with every `//` and `/* */` comment blanked.
fn uncommented(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try arena.dupe(u8, text);
    var i: usize = 0;
    while (i + 1 < out.len) : (i += 1) {
        const line = std.mem.startsWith(u8, out[i..], "//");
        if (!line and !std.mem.startsWith(u8, out[i..], "/*")) continue;
        // A line comment keeps its newline; a block comment ends past `*/`.
        const stop = if (line)
            std.mem.findScalarPos(u8, out, i, '\n') orelse out.len
        else if (std.mem.findPos(u8, out, i + 2, "*/")) |e| e + 2 else out.len;
        @memset(out[i..stop], ' ');
        i = stop - 1;
    }
    return out;
}

fn ident(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and isIdent(s[n])) n += 1;
    return s[0..n];
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// True when a card key `key` binds on `D`'s Model or Instance.
fn binds(comptime D: type, key: []const u8) bool {
    const p = [_]bind.Param{.{ .key = key, .value = null }};
    var hit = [_]bool{false};
    bind.markKnown(D.Model, &p, &hit);
    if (comptime @hasDecl(D, "Instance")) bind.markKnown(D.Instance, &p, &hit);
    return hit[0];
}

test "catalog reflects the generated model set" {
    try std.testing.expect(catalog.has("resistor"));
    try std.testing.expect(!catalog.has("does_not_exist"));
}

test "every alias a models/*.va file declares binds on the catalog models built from it" {
    // Oracle: the generated Model and Instance types, through the binder a
    // card goes through. The CMC VBIC 1.3 release defines its ALIAS macro
    // empty, so `ALIAS(dtemp,trise)` declared nothing and a card's dtemp
    // and dta were dropped with no error. Reads models/ from the build root.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var wrong: std.ArrayList(u8) = .empty;
    const dir = try std.Io.Dir.cwd().openDir(io, "models", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".va")) continue;
        const keys = try aliasKeys(a, try dir.readFileAlloc(io, e.name, a, .unlimited));
        if (keys.len == 0) continue;
        files += 1;
        const stem = e.name[0 .. e.name.len - ".va".len];
        var owners: usize = 0;
        inline for (catalog.catalog) |entry| if (comptime @hasDecl(entry.type, "Model")) {
            if (std.mem.eql(u8, renamed.get(entry.name) orelse entry.name, stem)) {
                owners += 1;
                for (keys) |key| if (!binds(entry.type, key)) try wrong.print(a, "{s}: {s}; ", .{ entry.name, key });
            }
        };
        if (owners == 0) try wrong.print(a, "{s}: no catalog model; ", .{e.name});
    }
    try std.testing.expect(files > 0);
    try std.testing.expectEqualStrings("", wrong.items);
}

test "every model's TNOM and TREF default in degC, the unit a card gives them in" {
    // Oracle: the card's unit. ngspice reads TNOM/TREF in degC and adds
    // CONSTCtoK itself (bjtmpar.c:41-43). A field defaulting near 300 is in
    // kelvin, so it reads a card's `tref=25` as 25 K.
    @setEvalBranchQuota(1_000_000);
    const gpa = std.testing.allocator;
    var wrong: std.ArrayList(u8) = .empty;
    defer wrong.deinit(gpa);
    inline for (catalog.catalog) |e| {
        if (comptime !@hasDecl(e.type, "Model")) continue;
        inline for (.{ "tnom", "tref", "TNOM", "TREF" }) |name| {
            if (comptime @hasField(e.type.Model, name)) {
                const default: f64 = comptime @field(@as(e.type.Model, .{}), name);
                if (!(default > -100 and default < 200)) try wrong.print(gpa, "{s}.{s}={d}; ", .{ e.name, name, default });
            }
        }
    }
    try std.testing.expectEqualStrings("", wrong.items);
}

test "modelName inverts byName" {
    try std.testing.expectEqualStrings("resistor", catalog.modelName(catalog.byName("resistor")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), catalog.modelName(u8));
}

test "loading no files registers nothing" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    try lib.loadWith(std.testing.io, &.{}, no_paths);
    try std.testing.expectEqual(@as(usize, Library.builtin_count), lib.names.items.len);
}

test "the first failing file in list order wins" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    const missing = "/nonexistent-espice-test-dir/missing.va";
    try std.testing.expectError(error.FileNotFound, lib.loadWith(std.testing.io, &.{ missing, "first.sv" }, no_paths));
    try std.testing.expectError(error.UnsupportedHdlExtension, lib.loadWith(std.testing.io, &.{ "first.sv", missing }, no_paths));
    try std.testing.expectEqual(@as(usize, Library.builtin_count), lib.names.items.len);
}

test "parallel model preparation propagates errors" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    try std.testing.expectError(error.UnsupportedHdlExtension, lib.loadWith(
        std.testing.io,
        &.{ "first.sv", "second.vhd" },
        no_paths,
    ));
}
