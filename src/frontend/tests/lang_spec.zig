//! The spec page against the front end. Oracle: docs/using/language.md
//! itself, read at test time (build.zig declares it a file input). Every
//! ```espice fence lexes, parses and lowers with no row (a fence without
//! the header gets `.espice 1` prepended). And nothing is lost: the
//! legacy cards the fences lower to reach every dot-card keyword of the
//! legacy tokenizer and every element letter of reference.md's Elements
//! table, or the keyword or letter is in `retired` with its reason. Name
//! lists are compared, never counts.

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const parse = @import("../lang/parse.zig");
const Ast = @import("../Ast.zig");
const Token = @import("../tokenizer.zig").Token;
const letterOfKind = @import("../Netlist/reader_instance.zig").letterOfKind;
const schema = @import("../lang/schema.zig");

const page_path = "docs/using/language.md";
const reference_path = "docs/using/reference.md";

/// Legacy keywords and element letters no fence reaches, each with why.
/// A retired name that a fence reaches fails the test until it goes.
const retired = std.StaticStringMap([]const u8).initComptime(.{
    .{ "end", "no .end: the file ends where it ends" },
    .{ "title", "the legacy .title card is ignored; the language's .title is the title line" },
    .{ "macro", "an alias: .subckt" },
    .{ "eom", "an alias: the .subckt block's }" },
    .{ "parameter", "an alias: .param" },
    .{ "parameters", "an alias: .param" },
    .{ "option", "an alias: .options, which .option lowers to" },
    .{ "opt", "an alias: .options" },
    .{ "opts", "an alias: .options" },
    .{ "measure", "an alias: .meas" },
    .{ "temp", ".option temp=" },
    .{ "probe", "the legacy .probe is ignored; the language's .probe is .save" },
    .{ "print", "no effect" },
    .{ "plot", "no effect" },
    .{ "graph", "no effect" },
    .{ "width", "no effect" },
    .{ "protect", "no effect" },
    .{ "unprotect", "no effect" },
    .{ "prot", "no effect" },
    .{ "unprot", "no effect" },
    .{ "csparam", "no effect" },
    .{ "pat", "no effect" },
    .{ "control", "skipped with a warning; no statement" },
    .{ "endc", "skipped with a warning; no statement" },
    .{ "store", "skipped with a warning; no statement" },
    .{ "osdi_include", "refused in both dialects: load Verilog-A with .hdl" },
    .{ "pre_osdi", "refused in both dialects: load Verilog-A with .hdl" },
});

/// The ```espice fences of a page, in order.
const Fences = struct {
    rest: []const u8,
    count: usize = 0,

    fn next(it: *Fences) !?[]const u8 {
        const open = std.mem.indexOf(u8, it.rest, "```espice\n") orelse return null;
        const start = open + "```espice\n".len;
        const close = std.mem.indexOfPos(u8, it.rest, start, "\n```") orelse return error.UnclosedFence;
        defer it.rest = it.rest[close + 4 ..];
        it.count += 1;
        return it.rest[start .. close + 1];
    }
};

// ---- private ----

fn withHeader(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    return if (lang.detect(body)) body else std.mem.concat(a, u8, &.{ ".espice 1\n", body });
}

fn isKeyByte(c: u8) bool {
    return std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_';
}

/// The text of the section headed `heading`, up to the next `## `.
fn section(page: []const u8, heading: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, page, heading) orelse return "";
    const end = std.mem.indexOfPos(u8, page, start + 1, "\n## ") orelse page.len;
    return page[start..end];
}

test "every espice fence of the spec page parses and lowers" {
    const gpa = testing.allocator;
    const page = try std.Io.Dir.cwd().readFileAlloc(testing.io, page_path, gpa, .limited(1 << 20));
    defer gpa.free(page);
    var fences: Fences = .{ .rest = page };
    while (try fences.next()) |body| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const src = try withHeader(arena.allocator(), body);
        errdefer std.debug.print("fence {d}:\n{s}\n", .{ fences.count, src });
        // Parsing alone: no row at all.
        var diags: lang.diag.Diags = .{ .gpa = arena.allocator() };
        _ = try parse.parse(arena.allocator(), src, &diags);
        for (diags.rows.items) |d| std.debug.print("parse: {t} at {any}: {s}\n", .{ d.code, lang.diag.lineCol(src, d.at), d.subject });
        try testing.expectEqual(0, diags.rows.items.len);
        // Lowering: no row at all either.
        const got = try lang.lowerRows(gpa, arena.allocator(), src, .top);
        for (got.diags) |d| std.debug.print("lower: {t} at {any}: {s}\n", .{ d.code, lang.diag.lineCol(src, d.at), d.subject });
        try testing.expectEqual(0, got.diags.len);
    }
    // A capture with no fence means the capture broke.
    try testing.expect(fences.count > 20);
}

test "nothing lost: the page's fences reach every legacy keyword and element letter, or it is retired" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try std.Io.Dir.cwd().readFileAlloc(testing.io, page_path, a, .limited(1 << 20));
    const reference = try std.Io.Dir.cwd().readFileAlloc(testing.io, reference_path, a, .limited(1 << 20));

    // Every fence's legacy cards, and the masters they declare.
    var cards: std.ArrayList(Ast) = .empty;
    var masters: std.StringHashMapUnmanaged(u8) = .empty;
    var fences: Fences = .{ .rest = page };
    while (try fences.next()) |body| {
        const text = try lang.lower(gpa, a, try withHeader(a, body), page_path, .top);
        const ast = try Ast.parse(a, text, .deck);
        for (0..ast.len()) |i| {
            var f = ast.cursor(@intCast(i));
            const head = f.field() orelse continue;
            const name = f.field() orelse continue;
            if (std.ascii.eqlIgnoreCase(head, ".subckt")) try masters.put(a, try std.ascii.allocLowerString(a, name), 'x');
            if (std.ascii.eqlIgnoreCase(head, ".model")) try masters.put(a, try std.ascii.allocLowerString(a, name), letterOfKind(f.field() orelse continue));
        }
        try cards.append(a, ast);
    }

    var reached: std.StringHashMapUnmanaged(void) = .empty;
    for (cards.items) |ast| for (0..ast.len()) |i| {
        var f = ast.cursor(@intCast(i));
        const head = f.field() orelse continue;
        if (head[0] == '.') {
            try reached.put(a, try std.ascii.allocLowerString(a, head[1..]), {});
            continue;
        }
        // `?@name (ports) master`: the letter the reader resolves.
        const letter = if (head[0] != '?') std.ascii.toLower(head[0]) else l: {
            while (f.field()) |t| if (t[0] == ')') break;
            const master = try std.ascii.allocLowerString(a, f.field() orelse continue);
            break :l masters.get(master) orelse 'n';
        };
        try reached.put(a, try a.dupe(u8, &.{letter}), {});
    };

    // The names that must be accounted for.
    var want: std.ArrayList([]const u8) = .empty;
    for (Token.keywords.keys()) |k| try want.append(a, k);
    var lines = std.mem.splitScalar(u8, section(reference, "## Elements"), '\n');
    var letters: usize = 0;
    while (lines.next()) |line| if (line.len > 6 and std.mem.startsWith(u8, line, "| `") and line[4] == '`') {
        try want.append(a, try a.dupe(u8, &.{std.ascii.toLower(line[3])}));
        letters += 1;
    };
    try testing.expect(letters > 20);

    var lost: std.ArrayList(u8) = .empty;
    var stale: std.ArrayList(u8) = .empty;
    for (want.items) |name| {
        const hit = reached.contains(name);
        if (!hit and !retired.has(name)) try lost.print(a, "{s} ", .{name});
        if (hit and retired.has(name)) try stale.print(a, "{s} ", .{name});
    }
    for (retired.keys()) |name| for (want.items) |w| {
        if (std.mem.eql(u8, w, name)) break;
    } else try stale.print(a, "{s}(unknown) ", .{name});
    try testing.expectEqualStrings("", lost.items);
    try testing.expectEqualStrings("", stale.items);
}

test "each analysis and reliability statement's keys on the page are its schema row's" {
    // Oracle: the signature columns of the page's tables, read as name
    // lists (`key=` and a bare `[flag]`) and compared with each row's keys.
    // `.dc` names its targets as keys: its row takes any.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try std.Io.Dir.cwd().readFileAlloc(testing.io, page_path, a, .limited(1 << 20));
    var documented: std.AutoArrayHashMapUnmanaged(schema.Directive, std.StringArrayHashMapUnmanaged(void)) = .empty;
    for ([_][]const u8{ "## Analyses", "## Reliability" }) |heading| {
        var lines = std.mem.splitScalar(u8, section(page, heading), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "| `.")) continue;
            const span_end = std.mem.indexOfScalarPos(u8, line, 4, '`') orelse continue;
            const name_end = std.mem.indexOfAnyPos(u8, line[0..span_end], 4, " ") orelse span_end;
            const d = schema.directive(line[4..name_end]) orelse {
                std.debug.print("no directive: {s}\n", .{line[4..name_end]});
                return error.UnknownDirective;
            };
            if (d == .dc) continue;
            // The signature: the rest of the name's span (Reliability's
            // table), else the whole Signature column, every form in it.
            const sig = if (name_end < span_end) line[name_end..span_end] else sig: {
                const start = std.mem.indexOfScalarPos(u8, line, span_end, '|') orelse continue;
                var end = start + 1;
                while (end < line.len and !(line[end] == '|' and line[end - 1] != '\\')) end += 1;
                break :sig line[start..end];
            };
            const keys = try documented.getOrPutValue(a, d, .empty);
            var i: usize = 0;
            while (i < sig.len) : (i += 1) {
                if (!isKeyByte(sig[i])) continue;
                const start = i;
                while (i < sig.len and isKeyByte(sig[i])) i += 1;
                const word = sig[start..i];
                const keyed = i < sig.len and sig[i] == '=';
                const flag = start > 0 and sig[start - 1] == '[' and i < sig.len and sig[i] == ']';
                if (keyed or flag) try keys.value_ptr.put(a, word, {});
            }
        }
    }
    try testing.expect(documented.count() >= 40);
    var diff: std.ArrayList(u8) = .empty;
    for (documented.keys(), documented.values()) |d, keys| {
        const row = schema.rows.get(d);
        for (keys.keys()) |k| if (for (row.keys) |slot| {
            if (std.mem.eql(u8, slot.key, k)) break false;
        } else true) try diff.print(a, ".{t}: page {s} not in the row; ", .{ d, k });
        for (row.keys) |slot| if (!keys.contains(slot.key)) try diff.print(a, ".{t}: row {s} not on the page; ", .{ d, slot.key });
    }
    try testing.expectEqualStrings("", diff.items);
}
