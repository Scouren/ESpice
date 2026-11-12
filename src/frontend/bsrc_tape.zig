//! B-source programs and tapes. In: a B card's postfix expression. Out:
//! the opcode tapes models/bsource.va interprets, as many as the
//! expression needs. A program has no size of its own: `cut` splits off a
//! subtree that fits one bsource until the rest fits too, and each piece
//! drives a fresh row the rest reads, so a split is the same equations
//! with two unknowns more per piece (its row and its branch). The
//! bsource's arrays are the capacities (`cap`); no deck meets them.
//! Cites: ngspice ptfuncs.c (PTpwl, PTnint, PTddt); models/bsource.va
//! (opcodes, capacities).
//!
//! Contents:
//! - `pub const ports`
//! - `pub const Tape = struct`, `pub fn store(t: Tape, comptime M: type, model: *M) void`
//! - `pub const Ins = struct`
//! - `pub const Prog = struct`, `pub fn replace(p: *Prog, arena: Allocator, range: [2]u32, row: u32) !void`
//! - `pub fn foldConstants(arena: Allocator, ops: []const Op, consts: []const f64) !struct { ops: []const Op, consts: []const f64 }`
//! - `pub fn constant(arena: Allocator, value: f64) !Prog`
//! - `pub fn compile(self: *NetBuilder, ops: []const Op, consts: []const f64) !Prog`
//! - `pub fn cut(arena: Allocator, p: Prog) !?[2]u32`
//! - `pub fn tapeOf(ins: []const Ins, tables: []const []const f64, nodes: *[ports]u32) Tape`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const devices = @import("spice.zig");
const netlist = @import("netlist");
const Op = netlist.expr.Op;
const net_builder = @import("net_builder.zig");
const net_branches = @import("net_branches.zig");
const net_waves = @import("net_waves.zig");
const NetBuilder = net_builder.NetBuilder;

/// Ports of every bsource variant: the output pair, then c0..c7.
pub const ports = devices.bsource.num_ports;

/// One bsource's tape as its parameter arrays hold it: postfix opcodes
/// with two u8 operands each, and a constant pool.
pub const Tape = struct {
    n_ops: u8 = 0,
    /// `ddt` ops, each with its slot in `op_a`; nonzero picks the variant
    /// that has the slots' rows.
    n_ddt: u8 = 0,
    op_code: [cap.ops]Code = @splat(.num),
    op_a: [cap.ops]u8 = @splat(0),
    op_b: [cap.ops]u8 = @splat(0),
    consts: [cap.consts]f64 = @splat(0.0),

    /// Writes the tape into a bsource Model, whose arrays VerA flattens into
    /// one field per slot (see `pwlSlot`).
    pub fn store(t: Tape, comptime M: type, model: *M) void {
        comptime assert(net_waves.slotCount(M, "op_code") == cap.ops and net_waves.slotCount(M, "consts") == cap.consts);
        model.n_ops = t.n_ops;
        inline for (0..cap.ops) |k| {
            @field(model, net_waves.pwlSlot("op_code", k)) = @backingInt(t.op_code[k]);
            @field(model, net_waves.pwlSlot("op_a", k)) = t.op_a[k];
            @field(model, net_waves.pwlSlot("op_b", k)) = t.op_b[k];
        }
        inline for (0..cap.consts) |k| @field(model, net_waves.pwlSlot("consts", k)) = t.consts[k];
    }
};

/// One instruction of a program: rows and constants by value, so a
/// subtree moves to another tape unchanged.
pub const Ins = struct {
    code: Code,
    /// `.v`, `.vd`: the rows read; `.powi`: the exponent; `.pwl`, `.pwlx`:
    /// the table's index in `Prog.tables`.
    a: u32 = 0,
    b: u32 = 0,
    /// `.num`: the constant; `.powc`: the exponent.
    x: f64 = 0,
};

/// A card's expression as postfix instructions, of any length.
pub const Prog = struct {
    ins: std.ArrayList(Ins) = .empty,
    /// Per table op: its corner width (0 for a sharp one), then its (x, y)
    /// pairs, x ascending; at most `cap.pairs` of them.
    tables: std.ArrayList([]const f64) = .empty,

    /// Replaces the subtree `range` of `p.ins` by a read of `row`, which a
    /// piece split off by `cut` drives.
    pub fn replace(p: *Prog, arena: Allocator, range: [2]u32, row: u32) !void {
        assert(range[0] < range[1] and range[1] <= p.ins.items.len);
        try p.ins.replaceRange(arena, range[0], range[1] - range[0], &.{.{ .code = .v, .a = row }});
    }
};

/// The bsource's capacities, its arrays in models/bsource.va; `Tape.store`
/// checks two against the generated Model at compile time.
const cap = struct {
    /// The interpreter's stack, `st[0:15]`.
    const depth = 16;
    const ops = 64;
    const consts = 32;
    /// Control ports c0..c7.
    const probes = ports - 2;
    /// The `ddt` slots of bsource_d and bsource_di: internal rows d0..d3.
    const ddt = 4;
    /// The most (x, y) pairs one table op holds: its width and its pairs
    /// fill the pool. A longer table splits at a midpoint (`emitTable`).
    const pairs = (consts - 1) / 2;
};

/// The tape's opcodes, numbered as models/bsource.va reads them.
const Code = enum(u8) {
    num,
    v,
    vd,
    neg,
    not,
    add,
    sub,
    mul,
    div,
    powi,
    powc,
    pow,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    @"and",
    @"or",
    sel,
    sqrt,
    abs,
    min,
    max,
    exp,
    ln,
    log10,
    sin,
    cos,
    tan,
    atan,
    tanh,
    floor,
    ceil,
    time,
    temper,
    pwl,
    pwlx,
    nint,
    ddt,
    sgn,
    cosh,
    pwr,
    sinh,
    asin,
    acos,
    asinh,
    acosh,
    atanh,
};

/// What a subtree needs of one tape.
const Size = struct {
    start: u32,
    ops: u32 = 0,
    consts: u32 = 0,
    ddt: u32 = 0,
    depth: u32 = 1,
    /// The distinct rows it reads, counted to one past `cap.probes`.
    rows: [cap.probes + 1]u32 = undefined,
    n_rows: u32 = 0,

    fn own(s: *Size, in: Ins, tables: []const []const f64) void {
        s.ops += 1;
        switch (in.code) {
            .num, .powc => s.consts += 1,
            .pwl, .pwlx => s.consts += @intCast(tables[in.a].len),
            .ddt => s.ddt += 1,
            .v => s.read(in.a),
            .vd => {
                s.read(in.a);
                s.read(in.b);
            },
            else => {},
        }
    }

    /// Operand `j`, evaluated with `j` values already on the stack.
    fn take(s: *Size, kid: Size, j: usize) void {
        s.ops += kid.ops;
        s.consts += kid.consts;
        s.ddt += kid.ddt;
        s.depth = @max(s.depth, @as(u32, @intCast(j)) + kid.depth);
        for (kid.rows[0..kid.n_rows]) |row| s.read(row);
    }

    fn read(s: *Size, row: u32) void {
        if (s.n_rows > cap.probes or std.mem.indexOfScalar(u32, s.rows[0..s.n_rows], row) != null) return;
        s.rows[s.n_rows] = row;
        s.n_rows += 1;
    }

    fn fits(s: Size) bool {
        return s.ops <= cap.ops and s.consts <= cap.consts and s.n_rows <= cap.probes and
            s.ddt <= cap.ddt and s.depth <= cap.depth;
    }
};

/// `ops` with every constant subtree folded to one `.num`, the consts it
/// reads renumbered into a fresh pool. A parameter spliced into a B
/// expression arrives as its own postfix (sky130's `rbody` carries
/// `mc_mm_switch*agauss(...)`), so without this the tape would hold
/// distribution calls and spend ops on arithmetic of constants.
/// Distributions fold to their nominal, as `expr.fold` does.
pub fn foldConstants(arena: Allocator, ops: []const Op, consts: []const f64) !struct { ops: []const Op, consts: []const f64 } {
    var out: std.ArrayList(Op) = .empty;
    var pool: std.ArrayList(f64) = .empty;
    var stack: std.ArrayList(netlist.expr.Val) = .empty;
    for (ops) |op| {
        if (op.code == .num) {
            try out.append(arena, .{ .code = .num, .a = @intCast(pool.items.len) });
            try pool.append(arena, consts[op.a]);
            continue;
        }
        const k = netlist.expr.arity(op);
        const is_table = op.code == .call and @as(netlist.expr.Fn, @fromBackingInt(@intCast(op.a))) == .table;
        const foldable = k > 0 and k <= out.items.len and !is_table and op.code != .live and
            for (out.items[out.items.len - k ..]) |o| {
                if (o.code != .num) break false;
            } else true;
        if (!foldable) {
            try out.append(arena, op);
            continue;
        }
        // The operands are the last k consts, in order.
        var mini: [9]Op = undefined;
        if (k + 1 > mini.len) {
            try out.append(arena, op);
            continue;
        }
        for (0..k) |i| mini[i] = .{ .code = .num, .a = @intCast(i) };
        mini[k] = op;
        const args = pool.items[pool.items.len - k ..];
        const v = try netlist.expr.eval(arena, &stack, mini[0 .. k + 1], args, &.{}, null);
        if (std.math.isNan(v)) {
            try out.append(arena, op);
            continue;
        }
        out.shrinkRetainingCapacity(out.items.len - k);
        pool.shrinkRetainingCapacity(pool.items.len - k);
        try out.append(arena, .{ .code = .num, .a = @intCast(pool.items.len) });
        try pool.append(arena, v);
    }
    return .{ .ops = out.items, .consts = pool.items };
}

/// The program of a constant output.
pub fn constant(arena: Allocator, value: f64) !Prog {
    var p: Prog = .{};
    try p.ins.append(arena, .{ .code = .num, .x = value });
    return p;
}

/// `ops` (folded by `foldConstants`) as a program; each probe resolves to
/// its row now. Fails on what no tape expresses: a name, function or
/// probe the bsource cannot read, a table that is not constant or not
/// ascending.
pub fn compile(self: *NetBuilder, ops: []const Op, consts: []const f64) !Prog {
    const arena = self.arena;
    var p: Prog = .{};
    for (ops) |op| switch (op.code) {
        .num => try p.ins.append(arena, .{ .code = .num, .x = consts[op.a] }),
        .vprobe, .iprobe => {
            if (op.a == netlist.none) return error.EmptyProbe;
            var rows: [2]u32 = .{ 0, 0 };
            for ([2]u32{ op.a, op.b }, &rows) |id, *row| {
                if (id == netlist.none) break;
                row.* = if (op.code == .vprobe)
                    try self.rowOf(.from(id))
                else
                    net_branches.branchRow(self, self.nl.pool.str(@fromBackingInt(@intCast(id)))) orelse return error.UnknownCurrentProbe;
            }
            try p.ins.append(arena, .{ .code = if (op.b == netlist.none) .v else .vd, .a = rows[0], .b = rows[1] });
        },
        .ident => try p.ins.append(arena, .{ .code = switch (op.a) {
            2 => .time,
            3 => .temper,
            else => return error.UnsupportedOperand,
        } }),
        .call => try call(arena, &p, @fromBackingInt(@intCast(op.a)), op.b),
        .pow => try power(arena, &p),
        // The tape has no opcode for numparam's `%` and `\`; they fold
        // when their operands are constant.
        .live, .mod, .idiv => return error.UnsupportedOperand,
        // `subst` resolves every one; none reaches a tape.
        .ucall => return error.UnsupportedFunction,
        inline else => |c| try p.ins.append(arena, .{ .code = @field(Code, @tagName(c)) }),
    };
    return p;
}

/// The subtree to split off next, the largest (in ops and constants) that
/// fits one tape, as `[start, end)` of `p.ins`; null when all of `p` fits.
/// A subtree whose operands are all leaves fits (`cap.pairs` bounds a
/// table), so while `p` does not fit there is one to cut, and each cut
/// shortens `p`.
pub fn cut(arena: Allocator, p: Prog) !?[2]u32 {
    if (p.ins.items.len == 0) return null;
    var stack: std.ArrayList(Size) = .empty;
    var best: ?[2]u32 = null;
    var best_size: u32 = 0;
    for (p.ins.items, 0..) |in, i| {
        const k = arity(in.code);
        assert(k <= stack.items.len);
        const kids = stack.items[stack.items.len - k ..];
        var s: Size = .{ .start = if (k == 0) @intCast(i) else kids[0].start };
        s.own(in, p.tables.items);
        for (kids, 0..) |kid, j| s.take(kid, j);
        stack.shrinkRetainingCapacity(stack.items.len - k);
        try stack.append(arena, s);
        if (k > 0 and i + 1 < p.ins.items.len and s.fits() and s.ops + s.consts > best_size) {
            best = .{ s.start, @intCast(i + 1) };
            best_size = s.ops + s.consts;
        }
    }
    assert(stack.items.len == 1);
    if (stack.items[0].fits()) return null;
    assert(best != null);
    return best;
}

/// The tape of a program that fits one bsource: one `cut` returns null
/// for, or a subtree it returned. Each row it reads takes the next control
/// port of `nodes`, after the two output ports.
pub fn tapeOf(ins: []const Ins, tables: []const []const f64, nodes: *[ports]u32) Tape {
    assert(ins.len <= cap.ops);
    var t: Tape = .{ .n_ops = @intCast(ins.len) };
    var n_rows: u8 = 0;
    var n_consts: usize = 0;
    for (ins, 0..) |in, n| {
        t.op_code[n] = in.code;
        switch (in.code) {
            .num, .powc => {
                t.op_a[n] = @intCast(n_consts);
                t.consts[n_consts] = in.x;
                n_consts += 1;
            },
            .pwl, .pwlx => {
                const block = tables[in.a];
                t.op_a[n] = @intCast(n_consts);
                t.op_b[n] = @intCast((block.len - 1) / 2);
                @memcpy(t.consts[n_consts..][0..block.len], block);
                n_consts += block.len;
            },
            .v => t.op_a[n] = port(nodes, &n_rows, in.a),
            .vd => {
                t.op_a[n] = port(nodes, &n_rows, in.a);
                t.op_b[n] = port(nodes, &n_rows, in.b);
            },
            .powi => t.op_a[n] = @intCast(in.a),
            .ddt => {
                t.op_a[n] = t.n_ddt;
                t.n_ddt += 1;
            },
            else => {},
        }
    }
    assert(n_consts <= cap.consts);
    assert(t.n_ddt <= cap.ddt and stackDepth(t) <= cap.depth);
    return t;
}

// ---- private ----

/// A call of `f` with `argc` arguments, already emitted.
fn call(arena: Allocator, p: *Prog, f: netlist.expr.Fn, argc: u32) !void {
    switch (f) {
        // Each ddt has a slot of its own: a charge and the row that holds
        // its derivative (models/bsource.va d0..d3). Deliberate divergence:
        // AC reads jω times its operand's derivative, where ngspice's PTddt
        // has a zero Jacobian and gives 0 (inpptree.c:573).
        .ddt => {
            if (argc != 1) return error.WrongArity;
            try p.ins.append(arena, .{ .code = .ddt });
        },
        .table => try table(arena, p, argc),
        else => switch (try callCode(f, argc)) {
            .pow => try power(arena, p),
            else => |code| try p.ins.append(arena, .{ .code = code }),
        },
    }
}

/// |x|^y: `^`, `**`, the B parser's pow and numparam's pwr, as ngspice's
/// PTpowerH, PTpower and XFU_PWR take it. A constant exponent folds into
/// the op: an integer one repeats the multiply (`powi`) behind an `abs`.
fn power(arena: Allocator, p: *Prog) !void {
    assert(p.ins.items.len >= 2);
    const last = p.ins.items[p.ins.items.len - 1];
    if (last.code != .num) return p.ins.append(arena, .{ .code = .pow });
    _ = p.ins.pop();
    const e = last.x;
    if (e >= 0 and e <= 255 and e == @round(e)) {
        try p.ins.append(arena, .{ .code = .abs });
        return p.ins.append(arena, .{ .code = .powi, .a = @intFromFloat(e) });
    }
    try p.ins.append(arena, .{ .code = .powc, .x = e });
}

/// table(x, d, x1, y1, ...), the smoothed table (37), or with an odd count
/// PTpwl's table(x, x1, y1, ...) (38), whose corner width is 0: the
/// constants after x become the op's table.
fn table(arena: Allocator, p: *Prog, argc: u32) !void {
    const sharp = argc % 2 == 1;
    const k = argc - 1;
    if (argc < 5 or (!sharp and argc < 6) or p.ins.items.len < argc) return error.WrongArity;
    const block = try arena.alloc(f64, k + @intFromBool(sharp));
    block[0] = 0;
    for (p.ins.items[p.ins.items.len - k ..], block[@intFromBool(sharp)..]) |in, *c| {
        if (in.code != .num) return error.NonConstantTable;
        c.* = in.x;
    }
    const pts = block[1..];
    var i: usize = 2;
    while (i < pts.len) : (i += 2) if (!(pts[i] > pts[i - 2])) return error.TableNotAscending;
    p.ins.shrinkRetainingCapacity(p.ins.items.len - k);
    // x, the last subtree left, is read once per piece of a long table.
    const end = p.ins.items.len;
    var start = end;
    var need: u32 = 1;
    while (need > 0) {
        start -= 1;
        need = need - 1 + arity(p.ins.items[start].code);
    }
    const x = try arena.dupe(Ins, p.ins.items[start..end]);
    p.ins.shrinkRetainingCapacity(start);
    try emitTable(arena, p, x, block, sharp);
}

/// Table `block` over `x`: one op while it fits a tape, else
/// `x < mid ? left : right`, whose halves share the two points around the
/// midpoint `mid` of the middle segment. bsource.va picks a corner at the
/// segment midpoints, and each corner reads only its two neighbours, so on
/// its side of `mid` each half picks the corner the whole table does and
/// shapes it the same: the split is exact.
fn emitTable(arena: Allocator, p: *Prog, x: []const Ins, block: []const f64, sharp: bool) Allocator.Error!void {
    const n = (block.len - 1) / 2;
    if (n <= cap.pairs) {
        try p.ins.appendSlice(arena, x);
        try p.ins.append(arena, .{ .code = if (sharp) .pwlx else .pwl, .a = @intCast(p.tables.items.len) });
        return p.tables.append(arena, block);
    }
    // The left half ends on segment (k, k + 1); the right starts on it.
    const k = n / 2 - 1;
    const pts = block[1..];
    try p.ins.appendSlice(arena, x);
    try p.ins.append(arena, .{ .code = .num, .x = 0.5 * (pts[2 * k] + pts[2 * k + 2]) });
    try p.ins.append(arena, .{ .code = .lt });
    for ([2][2]usize{ .{ 0, k + 2 }, .{ k, n } }) |range| {
        const part = try arena.alloc(f64, 1 + 2 * (range[1] - range[0]));
        part[0] = block[0];
        @memcpy(part[1..], pts[2 * range[0] .. 2 * range[1]]);
        try emitTable(arena, p, x, part, sharp);
    }
    try p.ins.append(arena, .{ .code = .sel });
}

/// Operands `code` pops.
fn arity(code: Code) u32 {
    return switch (code) {
        .num, .v, .vd, .time, .temper => 0,
        .sel => 3,
        .add, .sub, .mul, .div, .pow, .pwr, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or", .min, .max => 2,
        else => 1,
    };
}

/// The control port of `row`, the next free one on first read.
fn port(nodes: *[ports]u32, n_rows: *u8, row: u32) u8 {
    for (nodes[2..][0..n_rows.*], 0..) |r, k| if (r == row) return @intCast(k);
    assert(n_rows.* < cap.probes);
    nodes[2 + n_rows.*] = row;
    n_rows.* += 1;
    return n_rows.* - 1;
}

/// The deepest the interpreter's stack gets running `t`.
fn stackDepth(t: Tape) usize {
    var sp: isize = 0;
    var deepest: isize = 0;
    for (t.op_code[0..t.n_ops]) |code| {
        sp += 1 - @as(isize, @intCast(arity(code)));
        deepest = @max(deepest, sp);
    }
    return @intCast(deepest);
}

/// The tape op for a call of `f` with `argc` arguments.
fn callCode(f: netlist.expr.Fn, argc: u32) !Code {
    const want: u32 = switch (f) {
        .min, .max, .pow, .pwr, .bpwr => 2,
        .ternary => 3,
        else => 1,
    };
    if (argc != want) return error.WrongArity;
    return switch (f) {
        .ternary => .sel,
        .ln, .log => .ln,
        // `power`'s |x|^y, and the B parser's signed pwr (`bsourceFn`).
        .pwr => .pow,
        .bpwr => .pwr,
        // C's pow is numparam's, so it reaches a tape only from a
        // parameter's text whose fold failed: pow(-2, 2.5) is NaN, and
        // ngspice-44.2 fails such a deck.
        .pow => error.UnsupportedFunction,
        .agauss, .gauss, .unif, .aunif, .limit, .table, .ddt => error.UnsupportedFunction,
        // numparam's alone, which ngspice-44.2's B parser refuses ("no
        // such function"); reader_subst refuses them in a B card's own
        // text, so these come from a parameter's text that did not fold.
        .sqr, .int, .arctan => error.UnsupportedFunction,
        inline else => |g| @field(Code, @tagName(g)),
    };
}
