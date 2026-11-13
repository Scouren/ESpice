//! Where a file a deck names is found and how its name is read. In: the
//! naming file's path and a name as written. Out: a resolved path, and the
//! file's bytes read once per expansion.
//! Cites: ngspice-45 inpcom.c inp_pathresolve_at.
//!
//! Contents:
//! - `pub const Fields = tokenizer.Tokenizer("\"'", false)`
//! - `pub const Search = struct`
//! - `pub const Files = struct`
//! - `pub fn get(self: *Files, io: Io, gpa: Allocator, path: []const u8) Io.Dir.ReadFileAllocError![]const u8`
//! - `pub fn deinit(self: *Files, gpa: Allocator) void`
//! - `pub fn locate(io: Io, gpa: Allocator, search: Search, path: []const u8, name: []const u8) Allocator.Error![]u8`
//! - `pub fn word(fields: *Fields) error{InvalidInclude}!?[]const u8`
//! - `pub fn firstWord(t: []const u8) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tokenizer = @import("../tokenizer.zig");

/// A card's fields with `"` and `'` quoting, no braces.
pub const Fields = tokenizer.Tokenizer("\"'", false);

/// Where a file a deck names is looked for (`locate`). Borrows every slice.
pub const Search = struct {
    /// The top-level deck: `locate` looks beside it last, and its stem
    /// names `.load`'s default file.
    deck: []const u8,
    /// The work directory, absolute, which every path `locate` returns
    /// starts from, so no later reader joins it onto another directory
    /// (an HDL `.include` reaches `prepare.loadModels`, which reads a
    /// relative path beside the deck). "." keeps the paths relative.
    cwd: []const u8 = ".",
    /// The files read so far, so a library named by several `.lib` cards
    /// (one per section) is read once; null reads each time.
    files: ?*Files = null,
};

/// File bytes by resolved path, owned by the expansion's scratch allocator.
pub const Files = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    /// `path`'s bytes, read on first use. They live until `deinit`.
    pub fn get(self: *Files, io: Io, gpa: Allocator, path: []const u8) Io.Dir.ReadFileAllocError![]const u8 {
        const got = try self.map.getOrPut(gpa, path);
        if (got.found_existing) return got.value_ptr.*;
        errdefer self.map.removeByPtr(got.key_ptr);
        const key = try gpa.dupe(u8, path);
        errdefer gpa.free(key);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        got.key_ptr.* = key;
        got.value_ptr.* = bytes;
        assert(self.map.contains(path));
        return bytes;
    }

    /// Frees every path and every file's bytes, with the `gpa` that read them.
    pub fn deinit(self: *Files, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.map.deinit(gpa);
        self.* = undefined;
    }
};

/// Where the file at `path` finds `name`, as ngspice does: `name` itself
/// when absolute, else the first that exists of `./name` in the work
/// directory, then beside `path` (ngspice-45 inp_pathresolve_at,
/// inpcom.c:2207-2252; `dir` is the naming file's directory, inp.c:530,
/// inpcom.c:594 and 1564). Then, an ESPice extension, beside the top deck
/// with a warning, so a nested file named from the deck's directory reads
/// the same from wherever espice runs. Beside `path` when none exists, so
/// the open reports the usual error. Not followed: ngspice's `sourcepath` (`.`, its own scripts
/// directory and $NGSPICE_INPUT_DIR, cpitf.c:248-253) and `.include`'s
/// retry from the last included file's directory (inpcom.c:1535-1536).
/// Every result starts from `search.cwd`: the one resolution, which no
/// reader may resolve again. Caller owns returned string and must free with `gpa`.
pub fn locate(io: Io, gpa: Allocator, search: Search, path: []const u8, name: []const u8) Allocator.Error![]u8 {
    const here = try std.fs.path.resolve(gpa, &.{ search.cwd, std.fs.path.dirname(path) orelse ".", name });
    errdefer gpa.free(here);
    if (std.fs.path.isAbsolute(name)) return here;
    const found = blk: {
        if (try existing(io, gpa, &.{ search.cwd, name })) |p| break :blk p;
        if (Io.Dir.cwd().access(io, here, .{})) |_| return here else |_| {}
        const top = (try existing(io, gpa, &.{ search.cwd, std.fs.path.dirname(search.deck) orelse ".", name })) orelse return here;
        if (!@import("builtin").is_test) std.log.warn("{s}: '{s}' is not beside it; read {s}", .{ path, name, top });
        break :blk top;
    };
    gpa.free(here);
    return found;
}

/// The next field as a name: a quoted body or a bare word; null at the end
/// of the card or at a `$`/`;` comment. InvalidInclude for any other field.
pub fn word(fields: *Fields) error{InvalidInclude}!?[]const u8 {
    const rest = fields.rest();
    if (rest.len == 0 or rest[0] == '$' or rest[0] == ';') return null;
    const f = fields.field() orelse return null;
    assert(f.len > 0);
    if (Fields.isQuote(f[0])) return Fields.body(f);
    return if (Fields.isWord(f)) f else error.InvalidInclude;
}

/// The text before the first blank or tab.
pub fn firstWord(t: []const u8) []const u8 {
    return t[0 .. std.mem.indexOfAny(u8, t, " \t") orelse t.len];
}

// ---- private ----

/// `parts` joined, owned by `gpa`, when that file exists; else null.
fn existing(io: Io, gpa: Allocator, parts: []const []const u8) Allocator.Error!?[]u8 {
    const p = try std.fs.path.resolve(gpa, parts);
    if (Io.Dir.cwd().access(io, p, .{})) |_| return p else |_| {}
    gpa.free(p);
    return null;
}

test word {
    var f = Fields.init("'a b' c $ d");
    try std.testing.expectEqualStrings("a b", (try word(&f)).?);
    try std.testing.expectEqualStrings("c", (try word(&f)).?);
    try std.testing.expectEqual(null, try word(&f));
    try std.testing.expectEqualStrings(".lib", firstWord(".lib x"));
}
