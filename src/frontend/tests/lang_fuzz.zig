//! Fuzz target for the ESPice language front end: any bytes after the
//! `.espice 1` header. Oracles, cheapest first: no panic, no leak
//! (`testing.allocator`), no error but `OutOfMemory`; the same text and
//! rows on a second lowering (determinism); every row's offset inside the
//! file. Plain `zig build test` replays the corpus and a seeded run over
//! a token alphabet; `--fuzz` explores.

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const Smith = testing.Smith;

/// Inputs stop growing past this many bytes.
const input_max = 1 << 12;

/// Tokens of the language, and some it refuses, that generated decks join.
const alphabet = [_][]const u8{
    "\n",       " ",         "(",        ")",        "[",       "]",     "{",     "}",       ",",      "=",
    "+",        "-",         "*",        "**",       "/",       "%",     "==",    "!=",      "<",      "?",
    ":",        "&&",        "||",       "!",        "\"",      "\"q\"", "//c\n", "1",       "1.5k",   "1M",
    "5%",       "2V",        "1meg",     "a",        "v(a)",    "i(V1)", "time",  ".param ", ".tran ", ".model ",
    ".subckt ", ".if ",      ".else ",   ".alter ",  ".lib ",   ".dc ",  ".ac ",  ".op",     ".meas ", ".option ",
    "R1 ",      "resistor ", "vsource ", "bsource ", "pulse(",  "pwl(",  "lin(",  "dec(",    "n=",     "step=",
    "stop=",    "v=",        "sweep ",   "tol(",     "mutual ", "^",     "'",     "\\",      ".data ", "x ",
};

const seeds = [_][]const u8{
    ".param a = 1V b = a/2\n.tran stop=1ns step=1ps\n",
    ".subckt s (a b) w=1 {\n R1 (a b) resistor w\n}\nX1 (1 2) s w=2\n",
    "V1 (a 0) vsource pulse(0, 1, td=1n) ac=1\nB1 (o 0) bsource v=laplace(v(a), num=[1], den=[1, 1m])\n",
    ".if a == 1 {\n.param b = 2\n}\n.else {\n}\n.model m bsim4 type=n {\n vth0 = 1\n}\n",
    "((((((((((((((((",
};

const corpus = blk: {
    var out: [seeds.len][]const u8 = undefined;
    for (seeds, &out) |text, *o| o.* = raw(text);
    break :blk out;
};

// ---- private ----

/// One raw-mode corpus entry: what `rawBytes` reads back.
fn raw(comptime text: []const u8) []const u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u32, text.len)) ++ text;
}

fn rawBytes(_: void, s: *Smith) anyerror!void {
    var buf: [input_max]u8 = undefined;
    try holds(buf[0..s.slice(&buf)]);
}

fn lowerOnce(gpa: std.mem.Allocator, body: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", body });
    _ = try lang.lowerRows(gpa, arena.allocator(), src, .top);
}

/// Lowers `.espice 1` + `body` twice and checks the oracles.
fn holds(body: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", body });
    const first = try lang.lowerRows(testing.allocator, arena.allocator(), src, .top);
    const second = try lang.lowerRows(testing.allocator, arena.allocator(), src, .top);
    try testing.expectEqualStrings(first.text, second.text);
    try testing.expectEqual(first.diags.len, second.diags.len);
    for (first.diags, second.diags) |x, y| {
        try testing.expectEqual(x.code, y.code);
        try testing.expectEqual(x.at, y.at);
        try testing.expect(x.at <= src.len);
    }
}

test "fuzz the language front end: raw bytes after the header" {
    try testing.fuzz({}, rawBytes, .{ .corpus = &corpus });
}

test "the front end holds every oracle on 2000 seeded decks of language tokens" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    var buf: [input_max]u8 = undefined;
    for (0..2000) |_| {
        var len: usize = 0;
        const n = r.uintLessThan(usize, 80);
        for (0..n) |_| {
            const t = alphabet[r.uintLessThan(usize, alphabet.len)];
            if (len + t.len > buf.len) break;
            @memcpy(buf[len..][0..t.len], t);
            len += t.len;
        }
        try holds(buf[0..len]);
    }
}

test "the seed decks hold every oracle" {
    for (seeds) |s| try holds(s);
}

test "an allocation failure anywhere surfaces as OutOfMemory, with nothing leaked" {
    for (seeds) |s| try testing.checkAllAllocationFailures(testing.allocator, lowerOnce, .{s});
}
