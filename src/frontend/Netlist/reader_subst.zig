//! Parameter substitution: compiled expression text spliced with the
//! scopes' values and `.func` bodies, probes mapped to nets.
//! Cites: ngspice numparam (xpressn.c).
//!
//! Contents:
//! - `pub const Hit = struct`
//! - `pub fn subst(r: *Reader, src: *const expr.Scratch, from: usize, to: usize, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void`
//! - `pub fn bound(bindings: []const Binding, name: []const u8) ?[]const expr.Op`
//! - `pub fn inline_(r: *Reader, src: *const expr.Scratch, op: expr.Op, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void`
//! - `pub fn compiledText(r: *Reader, text: []const u8) Error!*const expr.Scratch`
//! - `pub fn compiledAt(r: *Reader, line: []const u8, pos: usize) Error!reader.Compiled`
//! - `pub fn levelPath(frame: *const Frame, level: usize) []const u8`
//! - `pub fn find(scopes: []const *const Scope, name: []const u8) ?Hit`
//! - `pub fn emitNum(r: *Reader, n: f64) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const expr = @import("../Parse/expr.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const reader_frame = @import("reader_frame.zig");
const reader_nets = @import("reader_nets.zig");
const reader_diag = @import("reader_diag.zig");
const Reader = reader.Reader;
const none = card_rows.none;
const Error = card_rows.Error;
const siteKey = netlist_view.siteKey;
const nameKey = netlist_view.nameKey;
const Scope = reader_frame.Scope;
const Frame = reader_frame.Frame;
const Binding = reader.Binding;
const Entry = reader_frame.Entry;
const readsLive = @import("card_table.zig").readsLive;

pub const Hit = struct { entry: Entry, level: usize };

/// Functions ngspice defines outside numparam, as the `.func` bodies
/// a deck's own `.func` of the same name overrides: the B-source
/// parser's step and sign tests (inpptree.c:158-172,
/// ptfuncs.c:186-252), read only in a B, E or G expression, as
/// ngspice-44.2 reads them ("Undefined parameter [u]" in a value).
/// Their derivatives are ngspice's (inpptree.c:526-542): zero,
/// uramp's the step, and u2's one between 0 and 1. PSPICE's `if`
/// is not one: plain ngspice-44.2 stops on it everywhere
/// ("Undefined parameter [if]", "no such function 'if'";
/// src/tests/expressions.zig).
const builtin_funcs = std.StaticStringMap(reader.Func).initComptime(.{
    .{ "u", reader.Func{ .formals = &.{"x"}, .body = "x > 0 ? 1 : x == 0 ? 0.5 : 0" } },
    .{ "uramp", reader.Func{ .formals = &.{"x"}, .body = "x > 0 ? x : 0" } },
    .{ "u2", reader.Func{ .formals = &.{"x"}, .body = "min(max(x, 0), 1)" } },
    .{ "eq0", reader.Func{ .formals = &.{"x"}, .body = "x == 0" } },
    .{ "ne0", reader.Func{ .formals = &.{"x"}, .body = "x != 0" } },
    .{ "gt0", reader.Func{ .formals = &.{"x"}, .body = "x > 0" } },
    .{ "lt0", reader.Func{ .formals = &.{"x"}, .body = "x < 0" } },
    .{ "ge0", reader.Func{ .formals = &.{"x"}, .body = "x >= 0" } },
    .{ "le0", reader.Func{ .formals = &.{"x"}, .body = "x <= 0" } },
});

/// Copies `src`'s ops `from..to` into the netlist's ops. A name a scope
/// defines is replaced by its definition, read in the scope that
/// defined it; probe nets are mapped through `frame`.
pub fn subst(r: *Reader, src: *const expr.Scratch, from: usize, to: usize, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void {
    if (depth == 64) return error.ParseError;
    // `expr.Code.ident`'s final operand: declared geometry, then the
    // B-source tape's simulator variables.
    const ident_class = std.StaticStringMap(u32).initComptime(.{ .{ "l", 1 }, .{ "w", 1 }, .{ "mult", 1 }, .{ "time", 2 }, .{ "temper", 3 } });
    var i = from;
    while (i < to) : (i += 1) {
        const op = src.ops.items[i];
        switch (op.code) {
            .num => try emitNum(r, src.consts.items[op.a]),
            .ident => {
                const name = src.names.items[op.a];
                // A formal of the function being expanded: its argument.
                if (bound(r.eval.bindings.items, name)) |ops| {
                    try r.nl.ops.appendSlice(r.arena, ops);
                    continue;
                }
                const hit = find(scopes, name) orelse {
                    try r.nl.ops.append(r.arena, .{ .code = .ident, .a = ident_class.get(name) orelse 0 });
                    continue;
                };
                if (hit.level == 0) if (r.live.names.getIndex(name)) |k| {
                    try r.nl.ops.append(r.arena, .{ .code = .live, .a = @intCast(k) });
                    continue;
                };
                switch (hit.entry) {
                    .num => |n| try emitNum(r, n),
                    .text => |text| {
                        // Instance scopes are fixed once built; the
                        // globals are not (a later `.param` redefines).
                        const key: reader.ParamKey = .{ .scope = @intFromPtr(scopes[hit.level]), .row = scopes[hit.level].getIndex(name).? };
                        if (hit.level > 0) if (r.eval.param_memo.get(key)) |n| {
                            try emitNum(r, n);
                            continue;
                        };
                        const ops_mark = r.nl.ops.items.len;
                        const consts_mark = r.nl.consts.items.len;
                        const sites_mark = r.live.site_ops.items.len;
                        const code = try compiledText(r, text);
                        // Calls inside a parameter's text draw once per
                        // scope that defines it: globally, or per instance.
                        const owner = r.eval.site_owner;
                        const ordinal = r.eval.site_ordinal;
                        defer {
                            r.eval.site_owner = owner;
                            r.eval.site_ordinal = ordinal;
                        }
                        if (r.live.monte) r.eval.site_owner = nameKey(nameKey(0, levelPath(frame, hit.level)), name);
                        r.eval.site_ordinal = 0;
                        // A parameter's text never sees the formals of a
                        // function that reads it, and is numparam's in a
                        // B card too.
                        const saved = r.eval.bindings;
                        r.eval.bindings = .empty;
                        defer r.eval.bindings = saved;
                        var numparam = frame.*;
                        numparam.bsource = false;
                        try subst(r, code, 0, code.ops.items.len, &numparam, scopes[0 .. hit.level + 1], depth + 1);
                        // A constant (no swept name, no Monte Carlo
                        // draw) folds once: later reads splice the number.
                        const ops = r.nl.ops.items[ops_mark..];
                        if (hit.level == 0 or readsLive(ops) or r.live.site_ops.items.len != sites_mark) continue;
                        const v = try expr.fold(r.arena, &r.eval.stack, ops, r.nl.consts.items, false, r.live.nominal.items);
                        if (!v.known) continue;
                        r.nl.ops.shrinkRetainingCapacity(ops_mark);
                        r.nl.consts.shrinkRetainingCapacity(consts_mark);
                        try emitNum(r, v.num);
                        try r.eval.param_memo.put(r.arena, key, v.num);
                    },
                }
            },
            .ucall => try inline_(r, src, op, frame, scopes, depth),
            // The device by its flattened card name (`commit`), for a B-source tape.
            .iprobe => {
                const a = if (op.a == none) none else a: {
                    const dev = src.names.items[op.a];
                    const flat = if (frame.path) |path| try reader_nets.joined(r, &.{ dev[0..1], ".", path, ".", dev }) else dev;
                    break :a (try reader_nets.internName(r, flat)).index();
                };
                try r.nl.ops.append(r.arena, .{ .code = .iprobe, .a = a, .b = none });
            },
            .vprobe => try r.nl.ops.append(r.arena, .{
                .code = .vprobe,
                .a = if (op.a == none) none else (try reader_nets.netOf(r, frame, src.names.items[op.a])).index(),
                .b = if (op.b == none) none else (try reader_nets.netOf(r, frame, src.names.items[op.b])).index(),
            }),
            .call => {
                const f: expr.Fn = @fromBackingInt(@intCast(op.a));
                if (r.live.monte and expr.isDistribution(f)) {
                    try r.live.site_ops.append(r.arena, @intCast(r.nl.ops.items.len));
                    try r.live.site_keys.append(r.arena, siteKey(r.eval.site_owner, r.eval.site_ordinal));
                    r.eval.site_ordinal += 1;
                }
                const g = if (!frame.bsource) f else expr.bsourceFn(f) orelse
                    return reader_diag.unsupported(r, r.diag.card, try r.arena.print("'{s}' in a B, E or G expression, where ngspice's B parser has no such function", .{@tagName(f)}));
                try r.nl.ops.append(r.arena, .{ .code = .call, .a = @backingInt(g), .b = op.b });
            },
            else => try r.nl.ops.append(r.arena, op),
        }
    }
}

/// The ops a formal named `name` stands for, the innermost binding.
pub fn bound(bindings: []const Binding, name: []const u8) ?[]const expr.Op {
    var i = bindings.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, bindings[i].name, name)) return bindings[i].ops;
    }
    return null;
}

/// Emits a call `op` of a function outside `expr.Fn`: a `.func`
/// expands to its body with each formal bound to its argument (the
/// arguments' final ops, the last `op.b` subtrees emitted), and so
/// does a `builtin_funcs` name no `.func` defines in a B, E or G
/// expression, where `ddt` and an odd-count `pwl` become their
/// `expr.Fn` call. Any other name, one of those outside such an
/// expression, and a `limit` of other than two arguments
/// (`expr_compile` passes those here), is `UnsupportedCard`, logged
/// with the function and `r.card`: every value, `.param`, `.meas`
/// and B or E expression reaches its functions here, so none reads
/// a stand-in for it (ngspice's numparam fails the deck: "Undefined
/// parameter").
pub fn inline_(r: *Reader, src: *const expr.Scratch, op: expr.Op, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void {
    const name = src.names.items[op.a];
    const ddt = std.mem.eql(u8, name, "ddt");
    const pwl = std.mem.eql(u8, name, "pwl");
    const func = r.decl.funcs.get(name) orelse (if (frame.bsource) builtin_funcs.get(name) else null) orelse {
        // The B-source parser's `ddt` and `pwl` (inpptree.c:165,
        // 177); a pwl is the odd-count `table` (expr_ops.zig `Fn`).
        if (frame.bsource and (ddt or (pwl and op.b % 2 == 1)))
            return r.nl.ops.append(r.arena, .{ .code = .call, .a = @backingInt(if (ddt) expr.Fn.ddt else .table), .b = op.b });
        // Three arguments are PSPICE's clamp, which only ngspice's
        // PSPICE mode defines (inpcompat.c:692-695); plain
        // ngspice-44.2 draws nom ± the last one in a `.param` and
        // reads 0 in a B source (measured).
        if (std.mem.eql(u8, name, "limit")) return reader_diag.unsupported(r, r.diag.card, try r.arena.print("limit() with {d} arguments, where ngspice's takes (nominal, variation); three are PSPICE's clamp: translate the deck to ngspice first", .{op.b}));
        if (!frame.bsource and (ddt or pwl or builtin_funcs.has(name)))
            return reader_diag.unsupported(r, r.diag.card, try r.arena.print("'{s}' outside a B, E or G expression: only ngspice's B parser has it", .{name}));
        return reader_diag.unsupported(r, r.diag.card, try r.arena.print("an unknown function '{s}'", .{name}));
    };
    if (func.formals.len != op.b) return error.ParseError;
    // Lift the argument subtrees off the output, last argument first.
    const args = try r.arena.alloc([]const expr.Op, op.b);
    var end = r.nl.ops.items.len;
    var k = args.len;
    while (k > 0) {
        k -= 1;
        const start = expr.subtreeStart(r.nl.ops.items[0..end], end - 1);
        args[k] = try r.arena.dupe(expr.Op, r.nl.ops.items[start..end]);
        end = start;
    }
    r.nl.ops.shrinkRetainingCapacity(end);
    const code = try compiledText(r, func.body);
    const outer = r.eval.bindings.items.len;
    defer r.eval.bindings.shrinkRetainingCapacity(outer);
    for (func.formals, args) |formal, a| try r.eval.bindings.append(r.arena, .{ .name = formal, .ops = a });
    try subst(r, code, 0, code.ops.items.len, frame, scopes, depth + 1);
}

/// `text` compiled, once per distinct text: a parameter's or a
/// function's text is read wherever it is named, once per instance
/// under a subcircuit. Compiling reads nothing but the text, so a
/// cached copy is what a fresh compile gives; a text that fails to
/// compile is not kept and fails the same way again.
pub fn compiledText(r: *Reader, text: []const u8) Error!*const expr.Scratch {
    const got = try r.eval.compiled_texts.getOrPut(r.arena, text);
    if (got.found_existing) return got.value_ptr.*;
    errdefer r.eval.compiled_texts.removeByPtr(got.key_ptr);
    // Its names are slices of the text, so the key owns a copy.
    const key = try r.arena.dupe(u8, text);
    const code = try r.arena.create(expr.Scratch);
    code.* = .{};
    try expr.compileAll(r.arena, code, key);
    got.key_ptr.* = key;
    got.value_ptr.* = code;
    return code;
}

/// The expression that starts at byte `pos` of `line`, a card of the
/// deck's own text, compiled once per run however many instances read
/// it. Keyed by the byte's address: the deck's text never moves or
/// changes during a read. Asserts `line` is the deck's (`Ast.source`).
pub fn compiledAt(r: *Reader, line: []const u8, pos: usize) Error!reader.Compiled {
    assert(r.ast.inSource(line) and pos <= line.len);
    const got = try r.eval.compiled_at.getOrPut(r.arena, @intFromPtr(line.ptr) + pos);
    if (got.found_existing) return got.value_ptr.*;
    errdefer r.eval.compiled_at.removeByPtr(got.key_ptr);
    const code = try r.arena.create(expr.Scratch);
    code.* = .{};
    got.value_ptr.* = .{ .code = code, .end = try expr.compile(r.arena, code, line, pos) };
    return got.value_ptr.*;
}

/// The instance path whose scope sits at `level` of `frame`'s
/// scopes: its first `level` dotted components, "" for globals.
pub fn levelPath(frame: *const Frame, level: usize) []const u8 {
    const path = frame.path orelse return "";
    if (level == 0) return "";
    var seen: usize = 0;
    for (path, 0..) |c, i| if (c == '.') {
        seen += 1;
        if (seen == level) return path[0..i];
    };
    return path;
}

pub fn find(scopes: []const *const Scope, name: []const u8) ?Hit {
    var i = scopes.len;
    while (i > 0) {
        i -= 1;
        if (scopes[i].get(name)) |entry| return .{ .entry = entry, .level = i };
    }
    return null;
}

pub fn emitNum(r: *Reader, n: f64) Error!void {
    try r.nl.consts.append(r.arena, n);
    try r.nl.ops.append(r.arena, .{ .code = .num, .a = @intCast(r.nl.consts.items.len - 1) });
}

// ---- private ----
