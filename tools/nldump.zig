//! The reader's golden. In: deck paths. Out: per deck, the SHA-256 of a
//! canonical text dump of everything the reader returns (the `Netlist` of
//! the main run and of each `.alter` run, or the error) and of everything
//! it logged, so a refactor of src/frontend's reader is checked byte for
//! byte over the whole corpus; and, with `--reps`, the parse time alone.
//! Cites: none (house tool; compiler-construction rule 9, goldens).
//!
//! Contents:
//! - `pub const std_options: std.Options`
//! - `pub fn main(init: std.process.Init) !void`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const netlist = @import("netlist");

/// Log lines go into the deck's dump instead of stderr.
pub const std_options: std.Options = .{ .logFn = captureLog };

/// What the reader logged for the deck being read.
var logged: std.ArrayList(u8) = .empty;

/// `nldump [--text | --ast] [--reps N] --out FILE (--list FILE | DECK...)`.
/// `--out` gets one `path<TAB>sha256<TAB>dump bytes` line per deck, in
/// argument order; `--text` writes the dumps themselves to stderr instead;
/// `--ast` writes each deck's cards as `Ast.parse` reads them (row, tag,
/// tokens) and nothing else; `--reps N` adds a fourth column, the fastest
/// of N parses in nanoseconds (source expansion and the dump excluded).
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var decks: std.ArrayList([]const u8) = .empty;
    var out_path: ?[]const u8 = null;
    var text = false;
    var ast = false;
    var reps: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--text")) {
            text = true;
        } else if (std.mem.eql(u8, arg, "--ast")) {
            ast = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--reps")) {
            reps = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--list")) {
            const list = try Io.Dir.cwd().readFileAlloc(io, args.next() orelse return error.MissingValue, a, .unlimited);
            var it = std.mem.tokenizeScalar(u8, list, '\n');
            while (it.next()) |path| try decks.append(a, path);
        } else try decks.append(a, arg);
    }
    var report: Io.Writer.Allocating = .init(a);
    var total_ns: u64 = 0;
    for (decks.items) |path| {
        var session = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer session.deinit();
        logged.clearRetainingCapacity();
        var dump: Io.Writer.Allocating = .init(session.allocator());
        const w = &dump.writer;
        if (ast) {
            dumpAst(io, session.allocator(), path) catch |err| std.debug.print("error.{s}\n", .{@errorName(err)});
            continue;
        }
        var best_ns: u64 = std.math.maxInt(u64);
        readDeck(io, session.allocator(), path, w, reps, &best_ns) catch |err| try w.print("error.{s}\n", .{@errorName(err)});
        try w.print("log:\n{s}", .{logged.items});
        if (text) {
            std.debug.print("== {s}\n{s}", .{ path, dump.written() });
            continue;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(dump.written(), &digest, .{});
        try report.writer.print("{s}\t{x}\t{d}", .{ path, digest[0..16], dump.written().len });
        if (reps != 0 and best_ns != std.math.maxInt(u64)) {
            try report.writer.print("\t{d}", .{best_ns});
            total_ns += best_ns;
        }
        try report.writer.writeByte('\n');
    }
    if (text or ast) return;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path orelse return error.MissingOut, .data = report.written() });
    if (reps != 0) std.debug.print("parse total: {d:.3} ms over {d} decks\n", .{ @as(f64, @floatFromInt(total_ns)) / 1e6, decks.items.len });
}

// ---- private ----

/// Reads the deck at `path` as `frontend.prepare` does (its `.alter` runs
/// split off and each one's includes expanded) and dumps every run to `w`.
fn readDeck(io: Io, session: Allocator, path: []const u8, w: *Io.Writer, reps: usize, best_ns: *u64) !void {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, session, .unlimited);
    const runs = try netlist.source.splitAlters(session, raw);
    for (runs, 0..) |run, k| {
        const text = try netlist.source.expand(io, std.heap.page_allocator, session, path, run);
        try w.print("run {d}:\n", .{k});
        const nl = netlist.parse(session, text) catch |err| {
            try w.print("error.{s}\n", .{@errorName(err)});
            continue;
        };
        try dumpValue(w, netlist.Netlist, nl);
        try w.writeByte('\n');
        if (k != 0) continue;
        const mark = logged.items.len;
        for (0..reps) |_| {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const start = Io.Timestamp.now(io, .awake);
            _ = netlist.parse(scratch.allocator(), text) catch {};
            best_ns.* = @min(best_ns.*, @as(u64, @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds)));
        }
        logged.shrinkRetainingCapacity(mark);
    }
}

/// The cards of the deck at `path` (its first run, includes expanded) as
/// stage 1 hands them on: one line per card, `row tag: token|token|...`.
fn dumpAst(io: Io, session: Allocator, path: []const u8) !void {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, session, .unlimited);
    const runs = try netlist.source.splitAlters(session, raw);
    const tree = try netlist.Ast.parse(session, try netlist.source.expand(io, std.heap.page_allocator, session, path, runs[0]), .deck);
    std.debug.print("== {s}\ntitle: {s}\n", .{ path, tree.title });
    for (tree.cards.items(.tag), 0..) |tag, i| {
        std.debug.print("{d} {s}:", .{ i, @tagName(tag) });
        var c = tree.cursor(@intCast(i));
        var sep: u8 = ' ';
        while (c.field()) |t| : (sep = '|') std.debug.print("{c}{s}", .{ sep, t });
        std.debug.print("\n", .{});
    }
}

/// `v` as canonical text: every number exact (floats by their bits), every
/// string by its bytes, a hash map's entries sorted by key, and no address.
fn dumpValue(w: *Io.Writer, comptime T: type, v: T) Io.Writer.Error!void {
    if (T == core.InternPool) {
        try w.print("pool{{{d} offs,", .{v.offs.items.len});
        try dumpValue(w, []const u8, v.bytes.items);
        return w.writeByte('}');
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try w.writeAll(if (v) "t" else "f"),
        .int => try w.print("{d}", .{v}),
        .float => try w.print("{x}", .{@as(u64, @bitCast(@as(f64, v)))}),
        // By name: a deleted variant must not renumber every later one.
        .@"enum" => if (std.enums.tagName(T, v)) |n| try w.writeAll(n) else try w.print("{d}", .{@intFromEnum(v)}),
        .optional => |o| if (v) |x| try dumpValue(w, o.child, x) else try w.writeAll("null"),
        .array => |arr| {
            try w.writeByte('[');
            for (v) |x| {
                try dumpValue(w, arr.child, x);
                try w.writeByte(',');
            }
            try w.writeByte(']');
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) {
                try w.print("\"{f}\"", .{std.ascii.hexEscape(v, .lower)});
            } else {
                try w.print("[{d}:", .{v.len});
                for (v) |x| {
                    try dumpValue(w, p.child, x);
                    try w.writeByte(',');
                }
                try w.writeByte(']');
            },
            .one => try dumpValue(w, p.child, v.*),
            else => @compileError("nldump: no dump for " ++ @typeName(T)),
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("nldump: untagged union " ++ @typeName(T));
            switch (v) {
                inline else => |payload, tag| {
                    try w.print("{s}(", .{@tagName(tag)});
                    try dumpValue(w, @TypeOf(payload), payload);
                    try w.writeByte(')');
                },
            }
        },
        .@"struct" => |s| {
            if (@hasField(T, "bytes") and @hasField(T, "len") and @hasDecl(T, "Field")) {
                // std.MultiArrayList: row by row.
                try w.print("rows[{d}:", .{v.len});
                for (0..v.len) |i| {
                    try dumpValue(w, @TypeOf(v.get(i)), v.get(i));
                    try w.writeByte(',');
                }
                return w.writeByte(']');
            }
            if (@hasDecl(T, "KV") and @hasDecl(T, "iterator")) {
                // An unordered hash map keyed by strings: sorted by key.
                const Entry = struct { key: []const u8, at: usize };
                var buf: [1 << 16]Entry = undefined;
                var n: usize = 0;
                var it = v.iterator();
                while (it.next()) |e| : (n += 1) buf[n] = .{ .key = e.key_ptr.*, .at = n };
                std.mem.sort(Entry, buf[0..n], {}, struct {
                    fn lt(_: void, x: Entry, y: Entry) bool {
                        return std.mem.lessThan(u8, x.key, y.key);
                    }
                }.lt);
                try w.print("map[{d}:", .{n});
                for (buf[0..n]) |e| {
                    try dumpValue(w, []const u8, e.key);
                    try w.writeByte('=');
                    try dumpValue(w, @TypeOf(v.get(e.key).?), v.get(e.key).?);
                    try w.writeByte(',');
                }
                return w.writeByte(']');
            }
            if (@hasField(T, "items") and @hasField(T, "capacity")) return dumpValue(w, @TypeOf(v.items), v.items);
            try w.writeByte('{');
            inline for (s.field_names, s.field_types) |name, F| {
                try w.writeAll(name ++ "=");
                try dumpValue(w, F, @field(v, name));
                try w.writeByte(';');
            }
            try w.writeByte('}');
        },
        else => @compileError("nldump: no dump for " ++ @typeName(T)),
    }
}

fn captureLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;
    const line = std.fmt.allocPrint(std.heap.page_allocator, comptime level.asText() ++ ": " ++ format ++ "\n", args) catch return;
    defer std.heap.page_allocator.free(line);
    logged.appendSlice(std.heap.page_allocator, line) catch {};
}
