//! Deck text through the public API, for the metamorphic tests beside it.
//! In: a deck. Out: the solved problem, a result and its columns by name,
//! its column names as a set, or the deck's refusal.
//!
//! Contents:
//! - `pub fn solve(source: []const u8) !*api.Problem`
//! - `pub fn column(r: api.Result, name: []const u8) !usize`
//! - `pub fn resultOf(p: *api.Problem, kind: api.requests.Kind) !api.Result`
//! - `pub fn at(r: api.Result, k: usize, name: []const u8) !f64`
//! - `pub fn atComplex(r: api.Result, k: usize, name: []const u8) ![2]f64`
//! - `pub fn expectSameNames(want: [][]const u8, got: []const []const u8) !void`
//! - `pub fn expectRefused(text: []const u8) !void`
const std = @import("std");
const api = @import("espice");
const t = std.testing;

/// Parses `source` and runs every query; the caller deinits the problem.
pub fn solve(source: []const u8) !*api.Problem {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "test.cir" } } });
    errdefer p.deinit();
    try p.run_all();
    return p;
}

/// The index of column `name` in `r`, MissingColumn (and its plot named)
/// when it has none.
pub fn column(r: api.Result, name: []const u8) !usize {
    for (r.varnames, 0..) |v, i| if (std.mem.eql(u8, v, name)) return i;
    std.debug.print("no column {s} in {s}\n", .{ name, r.plotname });
    return error.MissingColumn;
}

/// The first requested result of `kind` of solved problem `p` (a split
/// sweep's own, not one of its segment rows'), else its first of `kind`
/// (a prerequisite OP); MissingQuery when it has none.
pub fn resultOf(p: *api.Problem, kind: api.requests.Kind) !api.Result {
    var first: ?api.QueryId = null;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const q = try p.query_info(id);
        if (q.kind != kind) continue;
        if (q.requested) return p.result(id);
        first = first orelse id;
    }
    return p.result(first orelse return error.MissingQuery);
}

/// Column `name` of `r` at point `k`.
pub fn at(r: api.Result, k: usize, name: []const u8) !f64 {
    return r.data[k * r.varnames.len + try column(r, name)];
}

/// Column `name` of complex result `r` at point `k`, as (re, im). Asserts a
/// complex result.
pub fn atComplex(r: api.Result, k: usize, name: []const u8) ![2]f64 {
    std.debug.assert(r.is_complex);
    return r.data[2 * (k * r.varnames.len + try column(r, name)) ..][0..2].*;
}

/// Expects `got` to hold exactly the names in `want`, in any order; sorts
/// `want` in place.
pub fn expectSameNames(want: [][]const u8, got: []const []const u8) !void {
    const sorted = try t.allocator.dupe([]const u8, got);
    defer t.allocator.free(sorted);
    const lt = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f;
    std.mem.sort([]const u8, sorted, {}, lt);
    std.mem.sort([]const u8, want, {}, lt);
    errdefer for (sorted) |n| std.debug.print("got {s}\n", .{n});
    try t.expectEqual(want.len, sorted.len);
    for (want, sorted) |w, g| try t.expectEqualStrings(w, g);
}

/// Expects `text` refused at parse time, as every unsupported name is.
pub fn expectRefused(text: []const u8) !void {
    const p = api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = text, .origin = "test.cir" } } }) catch |got| {
        if (got == error.UnsupportedCard) return;
        std.debug.print("{s} instead of UnsupportedCard: {s}", .{ @errorName(got), text });
        return got;
    };
    p.deinit();
    std.debug.print("accepted, not refused: {s}", .{text});
    return error.TestExpectedError;
}
