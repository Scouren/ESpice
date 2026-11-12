//! Include expansion, before parsing. In: a deck's text and the path it
//! came from. Out: one text with every `.include`, selected `.lib` section,
//! HSPICE `.load`, `.vec` and external `.data` inlined; an HDL include
//! stays an `.include` of its resolved path.
//! Paths resolve as ngspice resolves them, from the work directory, then
//! the naming file's directory (source_search.locate).
//! Cites: ngspice inpcom.c (.include, .lib sections), HSPICE [CR] .LIB,
//! .LOAD, .VEC, .DATA, .ALTER.
//!
//! Contents:
//! - `pub const Error = Io.Dir.ReadFileAllocError || error{...}`
//! - `pub const ForeignKind = enum`
//! - `pub const splitAlters = source_alter.splitAlters`
//! - `pub fn load(io: Io, arena: Allocator, path: []const u8) Error![]const u8`
//! - `pub fn expand(io: Io, gpa: Allocator, arena: Allocator, origin: []const u8, src: []const u8) Error![]const u8`
//! - `pub fn foreignKindForPath(path: []const u8) ?ForeignKind`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vec = @import("vec.zig");
const source_search = @import("source_search.zig");
const source_alter = @import("source_alter.zig");
const source_data = @import("source_data.zig");
const Fields = source_search.Fields;
const Search = source_search.Search;
const Files = source_search.Files;

/// Every way an expansion fails; nothing is returned, the scratch is freed.
pub const Error = Io.Dir.ReadFileAllocError || error{
    /// A malformed `.include`, `.lib` or `.load` card.
    InvalidInclude,
    /// An unbalanced `.lib`/`.endl`.
    InvalidLibrarySection,
    /// The selected section appears twice in one library.
    DuplicateLibrarySection,
    /// No section of the library has the selected name.
    LibrarySectionNotFound,
    /// A malformed external `.data` block (source_data.zig).
    InvalidData,
    /// A `.vec` file vec.zig cannot read.
    InvalidVector,
    /// Includes nested past `include_depth_max` levels.
    IncludeDepthExceeded,
};

/// What a non-netlist file a deck names holds: a compiled OSDI model
/// (`osdi_include`, `pre_osdi`), HDL source (`verilog_a`, `verilog`), or
/// `data` that a card reads (an HSPICE RLGC or Touchstone file).
pub const ForeignKind = enum { osdi_include, pre_osdi, verilog_a, verilog, data };

/// HSPICE `.alter` runs (source_alter.zig).
pub const splitAlters = source_alter.splitAlters;

const Directive = enum { include, lib, endl, load, data, vec };
const directives = std.StaticStringMap(Directive).initComptime(.{
    .{ ".include", .include }, .{ ".inc", .include }, .{ ".lib", .lib }, .{ ".endl", .endl },
    .{ ".load", .load },       .{ ".data", .data },   .{ ".vec", .vec },
});

/// Includes past this depth are refused; the recursion stays bounded.
const include_depth_max = 32;

/// Reads `path` and expands it (see `expand`). The result is allocated in
/// `arena`. Fails per `Error`.
pub fn load(io: Io, arena: Allocator, path: []const u8) Error![]const u8 {
    const src = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    errdefer arena.free(src);
    const out = try expand(io, std.heap.page_allocator, arena, path, src);
    if (out.ptr != src.ptr) arena.free(src);
    return out;
}

/// Inlines includes and selected .lib sections, finding each file as
/// ngspice does (source_search.locate) from `origin`, the top deck; an HDL
/// include stays an `.include` of its resolved path. Returns `src` itself
/// when it names none, else a copy in `arena`; `gpa` holds the scratch
/// (file buffers, the text being built), all freed before return. Fails
/// per `Error`.
pub fn expand(io: Io, gpa: Allocator, arena: Allocator, origin: []const u8, src: []const u8) Error![]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next(); // The title is opaque even when it starts with .include.
    while (lines.next()) |line| {
        if (directiveOf(std.mem.trim(u8, line, " \t\r")) != null) break;
    } else return src;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var files: Files = .{};
    defer files.deinit(gpa);
    try appendContents(io, gpa, .{ .deck = origin, .files = &files }, origin, src, null, 0, &out);
    return try arena.dupe(u8, out.items);
}

/// The HDL kind a path's extension names; null for a netlist include.
pub fn foreignKindForPath(path: []const u8) ?ForeignKind {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".va", ".vams", ".veriloga" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .verilog_a;
    if (std.ascii.eqlIgnoreCase(ext, ".v") or std.ascii.eqlIgnoreCase(ext, ".sv")) return .verilog;
    return null;
}

// ---- private ----

fn directiveOf(line: []const u8) ?Directive {
    if (line.len == 0 or line[0] != '.') return null;
    var key_buf: [8]u8 = undefined;
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return if (end <= key_buf.len) directives.get(std.ascii.lowerString(key_buf[0..end], line[0..end])) else null;
}

fn appendFile(io: Io, gpa: Allocator, search: Search, path: []const u8, section: ?[]const u8, depth: u8, out: *std.ArrayList(u8)) Error!void {
    // ponytail: bounded recursion; iterative include stack if real PDKs exceed 32.
    if (depth == include_depth_max) return error.IncludeDepthExceeded;
    if (search.files) |files| return appendContents(io, gpa, search, path, try files.get(io, gpa, path), section, depth, out);
    const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(src);
    try appendContents(io, gpa, search, path, src, section, depth, out);
}

/// HSPICE `.load [FILE=f] [RUN=...]` [CR .LOAD]: inlines the `.nodeset`/`.ic`
/// cards an earlier `.save` wrote: `<top deck's stem>.ic0` by default, and
/// `x.ic0` for `FILE=x.ic` (the `.ic#` family). A file not there yet (the
/// run that first saves it) is skipped with a warning. RUN= only picks
/// between `.alter` runs' files, which ESPice does not number; it is
/// accepted and unused.
fn appendLoad(io: Io, gpa: Allocator, search: Search, path: []const u8, tokens: *Fields, depth: u8, out: *std.ArrayList(u8)) Error!void {
    var file: ?[]const u8 = null;
    while (tokens.next()) |key| {
        if (!Fields.isWord(key) or !tokens.takeEq()) return error.InvalidInclude;
        const value = (try source_search.word(tokens)) orelse return error.InvalidInclude;
        if (std.ascii.eqlIgnoreCase(key, "file")) file = value else if (!std.ascii.eqlIgnoreCase(key, "run")) return error.InvalidInclude;
    }
    // `FILE=x.ic` names the `.ic#` family; ESPice writes and reads `#` = 0.
    const name = if (file) |f|
        try std.mem.concat(gpa, u8, &.{ f, if (std.ascii.eqlIgnoreCase(std.fs.path.extension(f), ".ic")) "0" else "" })
    else
        try std.mem.concat(gpa, u8, &.{ std.fs.path.stem(search.deck), ".ic0" });
    defer gpa.free(name);
    const resolved = try source_search.locate(io, gpa, search, path, name);
    defer gpa.free(resolved);
    appendFile(io, gpa, search, resolved, null, depth + 1, out) catch |err| switch (err) {
        error.FileNotFound => std.log.warn(".load: {s} not found; no saved operating point", .{resolved}),
        else => return err,
    };
}

/// HSPICE `.vec 'file'`: the sources and `.dout` cards the vector file
/// stands for (frontend/vec.zig).
fn appendVec(io: Io, gpa: Allocator, path: []const u8, out: *std.ArrayList(u8)) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = try Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .unlimited);
    const text = vec.expand(arena.allocator(), src) catch |err| {
        if (err == error.InvalidVector) std.log.warn(".vec: cannot read {s}", .{path});
        return err;
    };
    try out.appendSlice(gpa, text);
}

fn appendContents(io: Io, gpa: Allocator, search: Search, path: []const u8, src: []const u8, section: ?[]const u8, depth: u8, out: *std.ArrayList(u8)) Error!void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var selected = section == null;
    var found = selected;
    var current_section: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var tokens = Fields.init(trimmed);
        // Title and comments are opaque, including unmatched quotes.
        if (depth == 0 and out.items.len == 0) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            continue;
        }
        if (directiveOf(trimmed)) |kind| {
            _ = try source_search.word(&tokens);
            if (kind == .data) {
                // An inline table passes through; MER and LAM read files.
                const name = tokens.next() orelse "";
                const mode = tokens.next() orelse "";
                const lam = std.ascii.eqlIgnoreCase(mode, "lam");
                if (selected and (lam or std.ascii.eqlIgnoreCase(mode, "mer"))) {
                    try source_data.appendData(io, gpa, search, path, name, lam, tokens, &lines, out);
                } else if (selected) {
                    try out.appendSlice(gpa, line);
                    try out.append(gpa, '\n');
                }
                continue;
            }
            if (kind == .load) {
                if (selected) try appendLoad(io, gpa, search, path, &tokens, depth, out);
                continue;
            }
            if (kind == .endl) {
                // The name after `.endl` is not checked: ngspice ignores it
                // (inpcom.c), and GF180 closes `.lib dio` with `.endl diode`.
                if (current_section == null) return error.InvalidLibrarySection;
                current_section = null;
                selected = section == null;
                continue;
            }
            const file_or_section = (try source_search.word(&tokens)) orelse return error.InvalidInclude;
            const corner = if (kind == .lib) try source_search.word(&tokens) else null;
            if (kind == .lib and corner == null) {
                if (current_section != null) return error.InvalidLibrarySection;
                current_section = file_or_section;
                selected = if (section) |wanted| std.ascii.eqlIgnoreCase(wanted, file_or_section) else false;
                if (selected and found) return error.DuplicateLibrarySection;
                found = found or selected;
                continue;
            }
            if (!selected) continue;
            const resolved = try source_search.locate(io, gpa, search, path, file_or_section);
            defer gpa.free(resolved);
            // HDL includes are left for the runtime loader.
            if (foreignKindForPath(file_or_section) != null) {
                try out.appendSlice(gpa, ".include \"");
                try out.appendSlice(gpa, resolved);
                try out.appendSlice(gpa, "\"\n");
                continue;
            }
            if (kind == .vec) {
                try appendVec(io, gpa, resolved, out);
                continue;
            }
            try appendFile(io, gpa, search, resolved, corner, depth + 1, out);
        } else if (selected) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    if (current_section != null) return error.InvalidLibrarySection;
    if (!found) return error.LibrarySectionNotFound;
}

test "directives and foreign kinds" {
    try std.testing.expectEqual(.include, directiveOf(".INC x").?);
    try std.testing.expectEqual(.endl, directiveOf(".endl\tx").?);
    try std.testing.expectEqual(null, directiveOf(".includes x"));
    try std.testing.expectEqual(null, directiveOf("r1 a b 1"));
    try std.testing.expectEqual(null, directiveOf(""));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(.verilog_a, foreignKindForPath("a/B.VA").?);
    try std.testing.expectEqual(.verilog, foreignKindForPath("x.sv").?);
    try std.testing.expectEqual(null, foreignKindForPath("x.sp"));
    // A deck naming nothing is returned as itself, even with a `.include` title.
    const plain = ".include x\nr1 a 0 1\n";
    try std.testing.expectEqual(plain.ptr, (try expand(std.testing.io, std.testing.allocator, a, "deck.sp", plain)).ptr);
}

test ".load: the top deck names the default file, FILE=x.ic reads x.ic0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.ic0", .data = ".nodeset\n+ a= 1.0000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "run.ic0", .data = ".ic v(b)=2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "inc.sp", .data = ".load\n" });
    const path = try a.print(".zig-cache/tmp/{s}/deck.sp", .{tmp.sub_path});
    // Each inlined file ends in blank lines; only the cards matter here.
    try std.testing.expectEqualStrings("t\n.nodeset\n+ a= 1.0000", std.mem.trimEnd(u8, try expand(io, std.testing.allocator, a, path, "t\n.include 'inc.sp'\n"), "\n"));
    try std.testing.expectEqualStrings("t\n.ic v(b)=2", std.mem.trimEnd(u8, try expand(io, std.testing.allocator, a, path, "t\n.load file='run.ic'\n"), "\n"));
}

test "external .data: MER stacks files, LAM sets them side by side" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1 2\n3,4\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "5 6\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "* sweep points\n$ x\n-1.5k\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "h.txt", .data = "x\n1\n" });
    const path = try a.print(".zig-cache/tmp/{s}/deck.sp", .{tmp.sub_path});
    const Case = struct { []const u8, anyerror![]const u8 };
    for ([_]Case{
        .{ "t\n.data d MER\n+ FILE='a.txt' x=1 y=2\n+ FILE='b.txt' y=1\n.enddata\n.end\n", "t\n.data d x y\n+ 1 2\n+ 3 4\n+ 5 5\n.enddata\n.end\n\n" },
        .{ "t\n.data d LAM\n+ FILE='a.txt' x=1\n+ FILE='b.txt' y=2\n.enddata\n", "t\n.data d x y\n+ 1 6\n+ 3 0\n.enddata\n\n" },
        .{ "t\n.data d MER FILE='a.txt' x=0\n.enddata\n", error.InvalidData },
        .{ "t\n.data d MER x=1\n.enddata\n", error.InvalidData },
        .{ "t\n.data d MER FILE='a.txt'\n.enddata\n", error.InvalidData },
        .{ "t\n.data d MER FILE='c.txt' x=1\n.enddata\n", "t\n.data d x\n+ -1.5k\n.enddata\n\n" },
        .{ "t\n.data d MER FILE='h.txt' x=1\n.enddata\n", error.InvalidData },
    }) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = case[0] });
        const got = load(io, a, path);
        if (case[1]) |want| try std.testing.expectEqualStrings(want, try got) else |err| try std.testing.expectError(err, got);
    }
}

test {
    _ = source_search;
    _ = source_alter;
    _ = source_data;
    _ = @import("tests/source.zig");
}
