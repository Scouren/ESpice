//! Parameter substitution: compiled expression text spliced with the
//! scopes' values and `.func` bodies, probes mapped to nets.
//! Cites: ngspice numparam (xpressn.c).
//!
//! Contents:
//! - `pub fn Methods(comptime S: type) type`
//! - `pub fn subst(r: *R, src: *const expr.Scratch, from: usize, to: usize, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void`
//! - `pub fn bound(bindings: []const Binding, name: []const u8) ?[]const expr.Op`
//! - `pub fn inline_(r: *R, src: *const expr.Scratch, op: expr.Op, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void`
//! - `pub fn compiledText(r: *R, text: []const u8) Error!*const expr.Scratch`
//! - `pub fn levelPath(frame: *const Frame, level: usize) []const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const hypergraph = @import("hypergraph.zig");
const expr = @import("expr.zig");
const measure = @import("measure.zig");
const pattern = @import("pattern.zig");
const core = @import("core");
const Name = core.Name;
const InternPool = core.InternPool;
const assert = std.debug.assert;
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const reader_frame = @import("reader_frame.zig");
const none = card_rows.none;
const Error = card_rows.Error;
const siteKey = netlist_view.siteKey;
const nameKey = netlist_view.nameKey;
const Scope = reader_frame.Scope;
const Frame = reader_frame.Frame;

/// The stage's `Reader` methods over dialect syntax `S`; `Reader(S)`
/// aliases each one as its own decl.
pub fn Methods(comptime S: type) type {
    return struct {
        const R = reader.Reader(S);
        const Binding = R.Binding;
        const find = R.find;

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
        const builtin_funcs = std.StaticStringMap(R.Func).initComptime(.{
            .{ "u", R.Func{ .formals = &.{"x"}, .body = "x > 0 ? 1 : x == 0 ? 0.5 : 0" } },
            .{ "uramp", R.Func{ .formals = &.{"x"}, .body = "x > 0 ? x : 0" } },
            .{ "u2", R.Func{ .formals = &.{"x"}, .body = "min(max(x, 0), 1)" } },
            .{ "eq0", R.Func{ .formals = &.{"x"}, .body = "x == 0" } },
            .{ "ne0", R.Func{ .formals = &.{"x"}, .body = "x != 0" } },
            .{ "gt0", R.Func{ .formals = &.{"x"}, .body = "x > 0" } },
            .{ "lt0", R.Func{ .formals = &.{"x"}, .body = "x < 0" } },
            .{ "ge0", R.Func{ .formals = &.{"x"}, .body = "x >= 0" } },
            .{ "le0", R.Func{ .formals = &.{"x"}, .body = "x <= 0" } },
        });

        /// Copies `src`'s ops `from..to` into the netlist's ops. A name a scope
        /// defines is replaced by its definition, read in the scope that
        /// defined it; probe nets are mapped through `frame`.
        pub fn subst(r: *R, src: *const expr.Scratch, from: usize, to: usize, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void {
            if (depth == 64) return error.ParseError;
            // `expr.Code.ident`'s final operand: declared geometry, then the
            // B-source tape's simulator variables.
            const ident_class = std.StaticStringMap(u32).initComptime(.{ .{ "l", 1 }, .{ "w", 1 }, .{ "mult", 1 }, .{ "time", 2 }, .{ "temper", 3 } });
            var i = from;
            while (i < to) : (i += 1) {
                const op = src.ops.items[i];
                switch (op.code) {
                    .num => try r.emitNum(src.consts.items[op.a]),
                    .ident => {
                        const name = src.names.items[op.a];
                        // A formal of the function being expanded: its argument.
                        if (bound(r.bindings.items, name)) |ops| {
                            try r.ops.appendSlice(r.arena, ops);
                            continue;
                        }
                        const hit = find(scopes, name) orelse {
                            try r.ops.append(r.arena, .{ .code = .ident, .a = ident_class.get(name) orelse 0 });
                            continue;
                        };
                        if (hit.level == 0) if (r.live_names.getIndex(name)) |k| {
                            try r.ops.append(r.arena, .{ .code = .live, .a = @intCast(k) });
                            continue;
                        };
                        switch (hit.entry) {
                            .num => |n| try r.emitNum(n),
                            .text => |text| {
                                const code = try r.compiledText(text);
                                // Calls inside a parameter's text draw once per
                                // scope that defines it: globally, or per instance.
                                const owner = r.site_owner;
                                const ordinal = r.site_ordinal;
                                defer {
                                    r.site_owner = owner;
                                    r.site_ordinal = ordinal;
                                }
                                if (r.monte) r.site_owner = nameKey(nameKey(0, levelPath(frame, hit.level)), name);
                                r.site_ordinal = 0;
                                // A parameter's text never sees the formals of a
                                // function that reads it, and is numparam's in a
                                // B card too.
                                const saved = r.bindings;
                                const bsource = r.bsource;
                                r.bindings = .empty;
                                r.bsource = false;
                                defer r.bindings = saved;
                                defer r.bsource = bsource;
                                try r.subst(code, 0, code.ops.items.len, frame, scopes[0 .. hit.level + 1], depth + 1);
                            },
                        }
                    },
                    .ucall => try r.inline_(src, op, frame, scopes, depth),
                    // The device by its flattened card name (`commit`), for a B-source tape.
                    .iprobe => {
                        const a = if (op.a == none) none else a: {
                            const dev = src.names.items[op.a];
                            const flat = if (frame.path) |path| try r.joined(&.{ dev[0..1], ".", path, ".", dev }) else dev;
                            break :a (try r.internName(flat)).index();
                        };
                        try r.ops.append(r.arena, .{ .code = .iprobe, .a = a, .b = none });
                    },
                    .vprobe => try r.ops.append(r.arena, .{
                        .code = .vprobe,
                        .a = if (op.a == none) none else (try r.netOf(frame, src.names.items[op.a])).index(),
                        .b = if (op.b == none) none else (try r.netOf(frame, src.names.items[op.b])).index(),
                    }),
                    .call => {
                        const f: expr.Fn = @fromBackingInt(@intCast(op.a));
                        if (r.monte and expr.isDistribution(f)) {
                            try r.site_ops.append(r.arena, @intCast(r.ops.items.len));
                            try r.site_keys.append(r.arena, siteKey(r.site_owner, r.site_ordinal));
                            r.site_ordinal += 1;
                        }
                        const g = if (!r.bsource) f else expr.bsourceFn(f) orelse
                            return r.unsupported(r.card, try r.arena.print("'{s}' in a B, E or G expression, where ngspice's B parser has no such function", .{@tagName(f)}));
                        try r.ops.append(r.arena, .{ .code = .call, .a = @backingInt(g), .b = op.b });
                    },
                    else => try r.ops.append(r.arena, op),
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
        pub fn inline_(r: *R, src: *const expr.Scratch, op: expr.Op, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void {
            const name = src.names.items[op.a];
            const ddt = std.mem.eql(u8, name, "ddt");
            const pwl = std.mem.eql(u8, name, "pwl");
            const func = r.funcs.get(name) orelse (if (r.bsource) builtin_funcs.get(name) else null) orelse {
                // The B-source parser's `ddt` and `pwl` (inpptree.c:165,
                // 177); a pwl is the odd-count `table` (expr_ops.zig `Fn`).
                if (r.bsource and (ddt or (pwl and op.b % 2 == 1)))
                    return r.ops.append(r.arena, .{ .code = .call, .a = @backingInt(if (ddt) expr.Fn.ddt else .table), .b = op.b });
                // Three arguments are PSPICE's clamp, which only ngspice's
                // PSPICE mode defines (inpcompat.c:692-695); plain
                // ngspice-44.2 draws nom ± the last one in a `.param` and
                // reads 0 in a B source (measured).
                if (std.mem.eql(u8, name, "limit")) return r.unsupported(r.card, try r.arena.print("limit() with {d} arguments, where ngspice's takes (nominal, variation); three are PSPICE's clamp: translate the deck to ngspice first", .{op.b}));
                if (!r.bsource and (ddt or pwl or builtin_funcs.has(name)))
                    return r.unsupported(r.card, try r.arena.print("'{s}' outside a B, E or G expression: only ngspice's B parser has it", .{name}));
                return r.unsupported(r.card, try r.arena.print("an unknown function '{s}'", .{name}));
            };
            if (func.formals.len != op.b) return error.ParseError;
            // Lift the argument subtrees off the output, last argument first.
            const args = try r.arena.alloc([]const expr.Op, op.b);
            var end = r.ops.items.len;
            var k = args.len;
            while (k > 0) {
                k -= 1;
                const start = expr.subtreeStart(r.ops.items[0..end], end - 1);
                args[k] = try r.arena.dupe(expr.Op, r.ops.items[start..end]);
                end = start;
            }
            r.ops.shrinkRetainingCapacity(end);
            const code = try r.compiledText(func.body);
            const outer = r.bindings.items.len;
            defer r.bindings.shrinkRetainingCapacity(outer);
            for (func.formals, args) |formal, a| try r.bindings.append(r.arena, .{ .name = formal, .ops = a });
            try r.subst(code, 0, code.ops.items.len, frame, scopes, depth + 1);
        }

        /// `text` compiled, once per distinct text: a parameter's or a
        /// function's text is read wherever it is named, once per instance
        /// under a subcircuit. Compiling reads nothing but the text, so a
        /// cached copy is what a fresh compile gives; a text that fails to
        /// compile is not kept and fails the same way again.
        pub fn compiledText(r: *R, text: []const u8) Error!*const expr.Scratch {
            const got = try r.compiled_texts.getOrPut(r.arena, text);
            if (got.found_existing) return got.value_ptr.*;
            errdefer r.compiled_texts.removeByPtr(got.key_ptr);
            // Its names are slices of the text, so the key owns a copy.
            const key = try r.arena.dupe(u8, text);
            const code = try r.arena.create(expr.Scratch);
            code.* = .{};
            try expr.compileAll(S, r.arena, code, key);
            got.key_ptr.* = key;
            got.value_ptr.* = code;
            return code;
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
    };
}
