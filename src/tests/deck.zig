//! Deck text through the public API, for the metamorphic tests beside it.
//! In: a deck. Out: the solved problem, a result and its columns by name,
//! or the deck's refusal.
//!
//! Contents:
//! - `pub fn solve(source: []const u8) !*api.Problem`
//! - `pub fn column(r: api.Result, name: []const u8) !usize`
//! - `pub fn resultOf(p: *api.Problem, kind: api.requests.Kind) !api.Result`
//! - `pub fn at(r: api.Result, k: usize, name: []const u8) !f64`
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
