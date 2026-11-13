//! HSPICE sweeps: `SWEEP DATA=|MONTE=|OPTIMIZE=`, `.data` and `.variation`
//! blocks, `DEV`/`LOT` spreads.
//! Cites: HSPICE [CR] .DATA, .VARIATION, [SA] Ch.25, Ch.27.
//!
//! Contents:
//! - `pub fn readSweep(r: *Reader, kind: Kind, args: []const Value, line: []const u8) Error!struct { args: []const Value, sweep: Sweep }`
//! - `pub fn readOptimize(r: *Reader, tail: []const Value) Error!Optimize`
//! - `pub fn positiveCount(args: []const Value, i: usize) Error!u32`
//! - `pub fn numbers(r: *Reader, args: []const Value) Error![]const f64`
//! - `pub fn readBlock(r: *Reader, b: [2]u32) Error!void`
//! - `pub fn readVariation(r: *Reader, b: [2]u32) Error!void`
//! - `pub fn sigmaExpr(r: *Reader, t: []const u8, line: []const u8) Error!Span`
//! - `pub fn percentValue(f: *F) ?struct { value: f64, relative: bool }`
//! - `pub fn devLot(r: *Reader, key: []const u8, param: []const u8, model: []const u8, f: *F, line: []const u8) Error!?Variation`
//! - `pub fn readStep(r: *Reader, args: []const Value) Error!Step`

const std = @import("std");
const Ast = @import("../Ast.zig");
const spice_number = @import("../Parse/spice_number.zig");
const expr = @import("../Parse/expr.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const reader_frame = @import("reader_frame.zig");
const sweep_points = @import("sweep_points.zig");
const reader_subst = @import("reader_subst.zig");
const reader_values = @import("reader_values.zig");
const reader_diag = @import("reader_diag.zig");
const reader_params = @import("reader_params.zig");
const tokenizer = @import("../tokenizer.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Kind = card_rows.Kind;
const none = card_rows.none;
const Error = card_rows.Error;
const Span = card_rows.Span;
const Value = card_rows.Value;
const StepTarget = card_rows.StepTarget;
const Monte = card_rows.Monte;
const Sweep = card_rows.Sweep;
const Optimize = card_rows.Optimize;
const Variation = card_rows.Variation;
const cardOf = tokenizer.Token.getKeyword;
const Frame = reader_frame.Frame;
const grids = sweep_points.grids;
const points = sweep_points.points;
const Step = card_rows.Step;
const Grid = sweep_points.Grid;

/// Splits an analysis card's HSPICE sweep tail (`SWEEP ...`, or a
/// bare `DATA=`/`MONTE=` on `.dc`) off its arguments. A bare one
/// after `.dc`'s swept source is `UnsupportedCard`, logged with `line`.
pub fn readSweep(r: *Reader, kind: Kind, args: []const Value, line: []const u8) Error!struct { args: []const Value, sweep: Sweep } {
    var at: ?usize = null;
    for (args, 0..) |a, i| if (a == .name and std.mem.eql(u8, a.name, "sweep")) {
        at = i;
        break;
    };
    if (at == null and kind == .dc and args.len >= 2 and args[0] == .name and
        (std.mem.eql(u8, args[0].name, "data") or std.mem.eql(u8, args[0].name, "monte"))) at = 0;
    // HSPICE takes a bare `DATA=`/`MONTE=` on `.dc` only as the whole
    // sweep [CR .DC]; after a swept source it needs the word `SWEEP`,
    // or the keyword would read as a second source.
    if (at == null and kind == .dc) for (args[@min(1, args.len)..]) |a| {
        if (a == .name and (std.mem.eql(u8, a.name, "data") or std.mem.eql(u8, a.name, "monte")))
            return reader_diag.unsupported(r, line, "DATA= or MONTE= after the swept source of a .dc needs the word SWEEP (.dc v1 0 1 0.1 SWEEP MONTE=n)");
    };
    // HSPICE `.dc param start stop incr` [CR .DC]: a swept `.param`
    // and no source. Its points are the DC sweep, as `.dc DATA=`'s
    // rows are (#94). A card of the name is swept instead
    // (`stepTarget`).
    if (at == null and kind == .dc and args.len == 4 and args[0] == .name) switch (try reader_params.stepTarget(r, args[0].name)) {
        .param => |k| {
            const n = try numbers(r, args[1..]);
            return .{ .args = args[0..0], .sweep = .{ .step = .{ .target = .{ .param = k }, .values = try points(r.arena, .lin, n[0], n[1], n[2], .per_unit) } } };
        },
        .temp, .card => {},
    };
    const i = at orelse return .{ .args = args, .sweep = .none };
    const tail = args[i + @intFromBool(args[i] == .name and std.mem.eql(u8, args[i].name, "sweep")) ..];
    if (tail.len < 2 or tail[0] != .name) return error.ParseError;
    const head = tail[0].name;
    const sweep: Sweep = if (std.mem.eql(u8, head, "optimize")) blk: {
        // ponytail: one optimization per deck.
        if (r.deck.optimize != null) return error.UnsupportedCard;
        r.deck.optimize = try readOptimize(r, tail);
        break :blk .optimize;
    } else if (std.mem.eql(u8, head, "data")) blk: {
        if (tail.len != 2 or tail[1] != .name) return error.ParseError;
        break :blk .{ .data = tail[1].name };
    } else if (std.mem.eql(u8, head, "monte")) blk: {
        if (tail[1] == .name and std.mem.eql(u8, tail[1].name, "list")) {
            const list = try r.arena.alloc(u32, tail.len - 2);
            for (list, 2..) |*t, k| t.* = try positiveCount(tail, k);
            if (list.len == 0) return error.ParseError;
            r.live.monte = true;
            break :blk .{ .monte = .{ .n = @intCast(list.len), .list = list } };
        }
        var m: Monte = .{ .n = try positiveCount(tail, 1) };
        var k: usize = 2;
        while (k < tail.len) {
            if (tail[k] != .name) return error.ParseError;
            if (std.mem.eql(u8, tail[k].name, "firstrun")) {
                m.first = try positiveCount(tail, k + 1);
                k += 2;
            } else if (std.mem.eql(u8, tail[k].name, "sigma_scale") and m.scales.len == 0) {
                // `SIGMA_SCALE=2,2.5,3`: the numbers up to the next name.
                var scales: std.ArrayList(f64) = .empty;
                k += 1;
                while (k < tail.len and tail[k] == .num) : (k += 1) {
                    const s = tail[k].num;
                    if (!(s > 0 and s < std.math.inf(f64)) or std.mem.indexOfScalar(f64, scales.items, s) != null) return error.ParseError;
                    try scales.append(r.arena, s);
                }
                if (scales.items.len == 0) return error.ParseError;
                m.scales = scales.items;
            } else return error.ParseError;
        }
        r.live.monte = true;
        break :blk .{ .monte = m };
    } else blk: {
        const target = try reader_params.stepTarget(r, head);
        if (tail.len >= 2 and tail[1] == .name) {
            const grid = grids.get(tail[1].name) orelse return error.ParseError;
            const n = try numbers(r, tail[2..]);
            if (n.len < 1 or n[0] != @trunc(n[0]) or n[0] < 1) return error.ParseError;
            if (grid == .poi) {
                // In f64: a count past usize must not reach @intFromFloat.
                if (@as(f64, @floatFromInt(n.len)) != 1 + n[0]) return error.ParseError;
                break :blk .{ .step = .{ .target = target, .values = n[1..] } };
            }
            if (n.len != 3) return error.ParseError;
            break :blk .{ .step = .{ .target = target, .values = try points(r.arena, grid, n[1], n[2], n[0], if (grid == .lin) .total else .per_unit) } };
        }
        const n = try numbers(r, tail[1..]);
        if (n.len != 3) return error.ParseError;
        break :blk .{ .step = .{ .target = target, .values = try points(r.arena, .lin, n[0], n[1], n[2], .per_unit) } };
    };
    return .{ .args = args[0..i], .sweep = sweep };
}

/// `OPTIMIZE=name RESULTS=m1,m2 MODEL=optmod`, in any order (`RESULT=`
/// as in the manual's bisection example [SA Ch.19]), and the
/// parameters `name(...)` or `OPTRANGE(...)` define, registered live
/// at their initial values in deck order.
pub fn readOptimize(r: *Reader, tail: []const Value) Error!Optimize {
    var opt: Optimize = .{ .name = "", .results = &.{}, .model = "", .live = &.{}, .lo = &.{}, .hi = &.{}, .dels = &.{}, .grid = &.{} };
    var results: std.ArrayList([]const u8) = .empty;
    const Key = enum { none, optimize, results, result, model };
    var key: Key = .none;
    for (tail) |v| {
        if (v != .name) return error.ParseError;
        if (std.meta.stringToEnum(Key, v.name)) |k| {
            key = k;
            continue;
        }
        switch (key) {
            .optimize => opt.name = v.name,
            .model => opt.model = v.name,
            .results, .result => try results.append(r.arena, v.name),
            .none => return error.ParseError,
        }
    }
    if (opt.name.len == 0 or opt.model.len == 0 or results.items.len == 0) return error.ParseError;
    opt.results = results.items;
    const Def = struct { key: []const u8, text: []const u8 };
    var defs: std.ArrayList(Def) = .empty;
    var it = r.decl.globals.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .text) {
        const text = e.value_ptr.text;
        const paren = std.mem.indexOfScalar(u8, text, '(') orelse continue;
        const head = std.mem.trim(u8, text[0..paren], " \t{'");
        if (std.mem.eql(u8, head, opt.name) or std.mem.eql(u8, head, "optrange"))
            try defs.append(r.arena, .{ .key = e.key_ptr.*, .text = text[paren..] });
    };
    // `globals` iterates in deck order (`Scope`).
    if (defs.items.len == 0) return error.ParseError;
    const n = defs.items.len;
    const live = try r.arena.alloc(u32, n);
    const lo = try r.arena.alloc(f64, n);
    const hi = try r.arena.alloc(f64, n);
    const dels = try r.arena.alloc(f64, n);
    const grid = try r.arena.alloc(f64, n);
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    for (defs.items, live, lo, hi, dels, grid) |d, *k, *l, *u, *h, *g| {
        // `(init, lo, hi[, dels[, grid]])`, each a number or an
        // expression; the grid is ESPice's, HSPICE stops at dels.
        const close = std.mem.lastIndexOfScalar(u8, d.text, ')') orelse return error.ParseError;
        var args: [5]f64 = @splat(0);
        var count: usize = 0;
        var depth: u32 = 0;
        var start: usize = 1;
        for (d.text[1 .. close + 1], 1..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')' and depth > 0) {
                depth -= 1;
                continue;
            }
            if (depth != 0 or (c != ',' and i != close)) continue;
            if (count == args.len) return error.ParseError;
            args[count] = switch (try reader_values.exprValue(r, d.text[start..i], &top, false)) {
                .num => |x| x,
                else => return error.ParseError,
            };
            count += 1;
            start = i + 1;
        }
        if (count < 3 or !(args[1] <= args[0] and args[0] <= args[2] and args[1] < args[2])) return error.ParseError;
        // A grid needs a multiple of itself inside [lo, hi].
        if (!(args[4] >= 0) or (args[4] > 0 and !(@ceil(args[1] / args[4]) <= @floor(args[2] / args[4])))) return error.ParseError;
        r.decl.globals.getPtr(d.key).?.* = .{ .num = args[0] };
        k.* = (try reader_params.liveParam(r, d.key)).?;
        l.* = args[1];
        u.* = args[2];
        h.* = args[3];
        g.* = args[4];
    }
    opt.live = live;
    opt.lo = lo;
    opt.hi = hi;
    opt.dels = dels;
    opt.grid = grid;
    return opt;
}

/// A positive integer argument.
pub fn positiveCount(args: []const Value, i: usize) Error!u32 {
    if (i >= args.len or args[i] != .num) return error.ParseError;
    const n = args[i].num;
    if (!(n >= 1) or n != @trunc(n) or n > std.math.maxInt(u32)) return error.ParseError;
    return @intFromFloat(n);
}

/// Every value as a finite number.
pub fn numbers(r: *Reader, args: []const Value) Error![]const f64 {
    const out = try r.arena.alloc(f64, args.len);
    for (args, out) |a, *o| {
        if (a != .num or !std.math.isFinite(a.num)) return error.ParseError;
        o.* = a.num;
    }
    return out;
}

/// A `.data` or `.variation` block, lines `b[0]..b[1]`.
pub fn readBlock(r: *Reader, b: [2]u32) Error!void {
    r.diag.card = r.ast.line(b[0]);
    var f = r.ast.cursor(b[0]);
    const card = cardOf(f.field().?[1..]).?;
    if (card == .variation) return readVariation(r, b);
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    const name = f.field() orelse return reader_diag.failed(r, r.ast.line(b[0]), error.ParseError);
    var labels: std.ArrayList([]const u8) = .empty;
    var columns: std.ArrayList(StepTarget) = .empty;
    var values: std.ArrayList(f64) = .empty;
    for (b[0]..b[1]) |li| {
        const line = r.ast.line(@intCast(li));
        var lf = r.ast.cursor(@intCast(li));
        if (li == b[0]) {
            _ = lf.field();
            _ = lf.field();
        }
        while (lf.field()) |t| {
            if (t[0] == ',' or t[0] == '+') continue;
            if (F.isWord(t) and spice_number.spiceNumber(t) == null) {
                // `MER`/`LAM` and `FILE=` read external tables.
                if (values.items.len != 0 or lf.nextByte() == '=') return reader_diag.failed(r, line, error.UnsupportedCard);
                try labels.append(r.arena, t);
                try columns.append(r.arena, try reader_params.stepTarget(r, t));
                continue;
            }
            switch (try reader_values.valueAt(r, t, &lf, &top, false, false)) {
                .num => |n| try values.append(r.arena, n),
                else => return reader_diag.failed(r, line, error.ParseError),
            }
        }
    }
    if (columns.items.len == 0 or values.items.len % columns.items.len != 0)
        return reader_diag.failed(r, r.ast.line(b[0]), error.ParseError);
    try r.deck.data.append(r.arena, .{ .name = name, .labels = labels.items, .columns = columns.items, .values = values.items });
}

/// HSPICE `.variation` block [SA Ch.20]: `.global_variation` and
/// `.local_variation` rows `<type> <model> p=sigma [%] ...`, and
/// `.element_variation` rows `<letter> p=sigma [%] ...`. Sigmas are
/// one sigma of a Gaussian, relative when followed by `%`; a sigma
/// that is not a number is an expression (`sigmaExpr`).
pub fn readVariation(r: *Reader, b: [2]u32) Error!void {
    var local = false;
    var element = false;
    for (b[0] + 1..b[1]) |li| {
        const line = r.ast.line(@intCast(li));
        var f = r.ast.cursor(@intCast(li));
        const head = f.field().?;
        if (head[0] == '.') {
            const markers = std.StaticStringMap([2]?bool).initComptime(.{
                .{ ".global_variation", .{ false, false } }, .{ ".end_global_variation", .{ null, null } },
                .{ ".local_variation", .{ true, false } },   .{ ".end_local_variation", .{ null, null } },
                .{ ".element_variation", .{ null, true } },  .{ ".end_element_variation", .{ null, false } },
            });
            const m = markers.get(head) orelse return reader_diag.failed(r, line, error.UnsupportedCard);
            if (m[0]) |l| local = l;
            if (m[1]) |e| element = e;
            continue;
        }
        if (std.mem.eql(u8, head, "option")) continue;
        var model: []const u8 = "";
        var letter: u8 = 0;
        if (element) letter = head[0] else model = f.field() orelse return reader_diag.failed(r, line, error.ParseError);
        while (f.field()) |key| {
            if (!F.isWord(key) or !f.takeEq()) return reader_diag.failed(r, line, error.ParseError);
            const t = f.peek() orelse return reader_diag.failed(r, line, error.ParseError);
            const plain = F.isWord(t) and spice_number.spiceNumber(if (t[t.len - 1] == '%') t[0 .. t.len - 1] else t) != null;
            var row: Variation = .{ .per_device = local or element, .dist = .gauss, .model = model, .letter = letter, .param = key, .value = 1, .relative = false };
            if (plain) {
                const v = percentValue(&f) orelse return reader_diag.failed(r, line, error.ParseError);
                row.value = v.value;
                row.relative = v.relative;
            } else {
                row.sigma = try sigmaExpr(r, f.field().?, line);
                // `'expr' %`: the expression is a percentage.
                if (f.nextByte() == '%') {
                    _ = f.field();
                    row.value = 0.01;
                    row.relative = true;
                }
            }
            try r.deck.variations.append(r.arena, row);
        }
    }
}

/// A `.variation` sigma written as `'expr'`, `{expr}` or a bare
/// name: its postfix over the global `.param`s at their nominal
/// values and the device's `w`, `l`, `m` (`Variation.sigma_names`,
/// `m` also as `mult`), kept as `.live` ops 0..2. Refuses a name it
/// cannot resolve and a distribution call.
pub fn sigmaExpr(r: *Reader, t: []const u8, line: []const u8) Error!Span {
    const mark = r.eval.scratch.mark();
    defer r.eval.scratch.reset(mark);
    try expr.compileAll(r.arena, &r.eval.scratch, if (F.isWord(t)) t else F.body(t));
    const slot = std.StaticStringMap(u32).initComptime(.{ .{ "w", 0 }, .{ "l", 1 }, .{ "m", 2 }, .{ "mult", 2 } });
    for (r.eval.scratch.ops.items[mark.ops..]) |*op| if (op.code == .ident) {
        if (slot.get(r.eval.scratch.names.items[op.a])) |k| op.* = .{ .code = .live, .a = k };
    };
    const start = r.nl.ops.items.len;
    const sites = r.live.site_ops.items.len;
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    try reader_subst.subst(r, &r.eval.scratch, mark.ops, r.eval.scratch.ops.items.len, &top, &r.decl.global_scopes, 0);
    const ops = r.nl.ops.items[start..];
    const probe = try expr.fold(r.arena, &r.eval.stack, ops, r.nl.consts.items, false, &.{ 1, 1, 1 });
    var drawn = r.live.site_ops.items.len != sites;
    for (ops) |op| drawn = drawn or (op.code == .call and expr.isDistribution(@fromBackingInt(@intCast(op.a))));
    if (!probe.known or drawn) return reader_diag.failed(r, line, error.ParseError);
    return .{ .start = @intCast(start), .len = @intCast(ops.len) };
}

/// A number, optionally followed by (or ending in) `%`.
pub fn percentValue(f: *F) ?struct { value: f64, relative: bool } {
    const t = f.field() orelse return null;
    const pct = t[t.len - 1] == '%';
    const n = spice_number.spiceNumber(if (pct) t[0 .. t.len - 1] else t) orelse return null;
    if (!std.math.isFinite(n)) return null;
    if (!pct and f.nextByte() == '%') {
        _ = f.field();
        return .{ .value = n / 100, .relative = true };
    }
    return .{ .value = if (pct) n / 100 else n, .relative = pct };
}

/// HSPICE `dev[/n][/dist]=v` or `lot[/n][/dist]=v` after model value
/// `param`; null when `key` is neither.
pub fn devLot(r: *Reader, key: []const u8, param: []const u8, model: []const u8, f: *F, line: []const u8) Error!?Variation {
    var parts = std.mem.splitScalar(u8, key, '/');
    const head = parts.next().?;
    const per_device = std.mem.eql(u8, head, "dev");
    if (!per_device and !std.mem.eql(u8, head, "lot")) return null;
    var dist: Variation.Dist = .unif;
    while (parts.next()) |p| {
        if (p.len > 0 and std.ascii.isDigit(p[0])) continue;
        const dists = std.StaticStringMap(Variation.Dist).initComptime(.{
            .{ "gauss", .gauss }, .{ "unif", .unif }, .{ "uniform", .unif }, .{ "limit", .limit },
        });
        dist = dists.get(p) orelse return reader_diag.failed(r, line, error.UnsupportedCard);
    }
    if (param.len == 0) return reader_diag.failed(r, line, error.ParseError);
    const v = percentValue(f) orelse return reader_diag.failed(r, line, error.ParseError);
    // A Gaussian's value is its 3-sigma spread [SA Ch.20 "Variations
    // Specified Using DEV and LOT"]; `Variation.value` holds one sigma.
    const value = if (dist == .gauss) v.value / 3 else v.value;
    return .{ .per_device = per_device, .dist = dist, .model = model, .param = param, .value = value, .relative = v.relative };
}

/// `.step [lin|dec|oct] [param] name start stop incr`, `.step
/// [param] name list v...`, with `temp` or a source for the name
/// (ngspice/LTspice form). `dec`/`oct` take points per decade or
/// octave.
pub fn readStep(r: *Reader, args: []const Value) Error!Step {
    var i: usize = 0;
    var grid: Grid = .lin;
    if (i < args.len and args[i] == .name) if (grids.get(args[i].name)) |g| {
        grid = g;
        i += 1;
    };
    const param = i < args.len and args[i] == .name and std.mem.eql(u8, args[i].name, "param");
    i += @intFromBool(param);
    if (i >= args.len or args[i] != .name) return error.ParseError;
    const target: StepTarget = if (param)
        .{ .param = try reader_params.liveParam(r, args[i].name) orelse return error.ParseError }
    else
        try reader_params.stepTarget(r, args[i].name);
    i += 1;
    if (i < args.len and args[i] == .name and std.mem.eql(u8, args[i].name, "list")) {
        // An empty list would plan no runs at all (#66).
        if (i + 1 == args.len) return error.ParseError;
        return .{ .target = target, .values = try numbers(r, args[i + 1 ..]) };
    }
    if (grid == .poi) return error.ParseError;
    const n = try numbers(r, args[i..]);
    if (n.len != 3) return error.ParseError;
    return .{ .target = target, .values = try points(r.arena, grid, n[0], n[1], n[2], .per_unit) };
}

// ---- private ----
