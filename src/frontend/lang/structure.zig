//! Rows and lowerings of the structure, parameter, file, option and state
//! directives: `.title .param .func .model .subckt .global .connect
//! .if/.elseif/.else .include .lib .hdl .verilog .vec .load .save .alter
//! .option .ic .nodeset .probe`. In: a bound statement. Out: its legacy
//! card(s).
//! Cites: docs/using/language.md "Parameters and functions", "Structure",
//! "Files", "Options", "Initial conditions and output", "Subcircuits";
//! docs/using/reference.md "Dot cards".
//!
//! Contents:
//! - `pub const rows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const model = @import("model.zig");
const source = @import("../source.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;
const Index = ast.Index;

/// This area's rows of the directive table.
pub const rows = .{
    .title = Row{ .subjects = &.{.{ .key = "text", .ty = .string, .need = .required }}, .lower = title },
    .param = Row{ .open = true, .lower = param },
    .func = Row{ .open = true, .lower = func },
    .model = model.row,
    .subckt = Row{
        .subjects = &.{ .{ .key = "name", .ty = .reference, .need = .required }, .{ .key = "ports", .ty = .ports, .need = .required } },
        .open = true,
        .block = true,
        .lower = subckt,
    },
    .global = Row{ .subjects = &.{.{ .key = "node", .ty = .node, .need = .required }}, .variadic = true, .lower = global },
    .connect = Row{ .subjects = &.{ .{ .key = "a", .ty = .node, .need = .required }, .{ .key = "b", .ty = .node, .need = .required } }, .lower = connect },
    .@"if" = Row{ .subjects = &.{.{ .key = "condition", .ty = .expr, .need = .required }}, .block = true, .lower = ifBranch },
    .elseif = Row{ .subjects = &.{.{ .key = "condition", .ty = .expr, .need = .required }}, .block = true, .lower = ifBranch },
    .@"else" = Row{ .block = true, .lower = ifBranch },
    .include = Row{ .subjects = &.{.{ .key = "file", .ty = .string, .need = .required }}, .lower = include },
    .lib = Row{ .subjects = &.{ .{ .key = "file or section", .ty = .any, .need = .required }, .{ .key = "section", .ty = .reference } }, .lower = lib },
    .hdl = Row{ .subjects = &.{.{ .key = "file", .ty = .string, .need = .required }}, .lower = pathCard },
    .verilog = Row{ .subjects = &.{.{ .key = "file", .ty = .string, .need = .required }}, .lower = pathCard },
    .vec = Row{ .subjects = &.{.{ .key = "file", .ty = .string, .need = .required }}, .lower = pathCard },
    .load = Row{ .keys = &.{.{ .key = "file", .ty = .string }}, .lower = load },
    .save = Row{ .keys = &save_keys, .lower = save },
    .alter = Row{ .block = true, .lower = alter },
    .option = Row{ .keys = &option_keys, .lower = option },
    .ic = Row{ .open = true, .lower = state },
    .nodeset = Row{ .open = true, .lower = state },
    .probe = Row{ .subjects = &.{.{ .key = "probe", .ty = .probe, .need = .required }}, .variadic = true, .lower = probe },
};

const save_keys = [_]Slot{
    .{ .key = "type", .ty = .word, .words = &.{ "ic", "nodeset" } },
    .{ .key = "file", .ty = .string },
    .{ .key = "level", .ty = .word, .words = &.{ "all", "top", "select", "none" } },
    .{ .key = "time", .ty = .quantity, .q = .time },
};

const option_keys = [_]Slot{
    .{ .key = "reltol", .ty = .real },
    .{ .key = "abstol", .ty = .quantity, .q = .current },
    .{ .key = "vntol", .ty = .quantity, .q = .voltage },
    .{ .key = "chgtol", .ty = .real },
    .{ .key = "gmin", .ty = .quantity, .q = .conductance },
    .{ .key = "itl1", .ty = .integer },
    .{ .key = "itl2", .ty = .integer },
    .{ .key = "itl4", .ty = .integer },
    .{ .key = "dv", .ty = .quantity, .q = .voltage },
    .{ .key = "trtol", .ty = .real },
    .{ .key = "method", .ty = .word, .words = &.{ "trap", "gear" } },
    .{ .key = "maxord", .ty = .integer },
    .{ .key = "xmu", .ty = .real },
    .{ .key = "temp", .ty = .quantity, .q = .temperature },
    .{ .key = "tnom", .ty = .quantity, .q = .temperature },
    .{ .key = "delmax", .ty = .quantity, .q = .time },
    .{ .key = "tran_ceiling", .ty = .word, .words = &.{ "compatibility", "duration" } },
    .{ .key = "gshunt", .ty = .quantity, .q = .conductance },
    .{ .key = "cshunt", .ty = .quantity, .q = .capacitance },
    .{ .key = "rshunt", .ty = .quantity, .q = .resistance },
    .{ .key = "scale", .ty = .real },
    .{ .key = "wnflag", .ty = .integer },
    .{ .key = "seed", .ty = .integer },
    .{ .key = "sampling_method", .ty = .word, .words = &.{"lhs"} },
    .{ .key = "runlvl", .ty = .integer },
    .{ .key = "accurate", .ty = .flag },
    .{ .key = "fast", .ty = .flag },
    .{ .key = "em_recovery", .ty = .real },
    .{ .key = "search", .ty = .string },
    .{ .key = "soa", .ty = .flag },
    .{ .key = "maxwarns", .ty = .integer },
    .{ .key = "soalimits", .ty = .string },
    .{ .key = "vpi", .ty = .string },
};

// ---- private ----

/// The title line is written first (lower.zig `run`); here only where it stands.
fn title(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (l.role != .top or l.depth != 1 or l.titled) return l.diags.add(.misplaced, l.a.at(b.stmt), ".title");
    l.titled = true;
}

/// `.param a = 1V b = a/2` is `.param a=1 b='a/2'`; each name keeps its
/// literal's unit for the checks after it.
fn param(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.open.len == 0) return l.diags.add(.arity, a.at(b.stmt), ".param");
    try l.put(".param");
    for (b.open) |s| {
        const key = a.node(s).lhs;
        const v = a.node(s).rhs;
        if (a.tag(key) != .word) try l.diags.add(.wrong_kind, a.at(key), "a .param name (a function is .func)");
        try l.put(" ");
        try l.putName(key);
        try l.put("=");
        const optimized = a.tag(v) == .call and std.mem.eql(u8, a.callee(v), "optimize");
        if (optimized) try @import("sweeps.zig").optimizeParam(l, v) else try expr.writeValue(l, v, .param);
        try l.setParamUnit(a.text(key), if (a.tag(v) == .number) @import("check.zig").unitOf(l, v) else null);
    }
    try l.endCard();
}

/// `.func f(a, b) = a*b` is `.func f(a, b) {a*b}`.
fn func(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.open.len != 1) return l.diags.add(.arity, a.at(b.stmt), ".func");
    const head = a.node(b.open[0]).lhs;
    if (a.tag(head) != .call) return l.diags.add(.wrong_kind, a.at(head), a.text(head));
    try l.print(".func {s}(", .{a.callee(head)});
    for (a.children(head), 0..) |arg, i| {
        if (a.tag(arg) != .word) try l.diags.add(.wrong_kind, a.at(arg), a.text(arg));
        if (i > 0) try l.put(", ");
        try l.putName(arg);
    }
    try l.put(") {");
    try expr.write(l, a.node(b.open[0]).rhs, .func);
    try l.put("}");
    try l.endCard();
}

/// `.subckt inv (in out) wn=1u { ... }` is `.subckt inv in out wn=1u` ... `.ends`.
fn subckt(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.subjects.len != 2) return;
    try l.put(".subckt ");
    try l.putName(b.subjects[0]);
    try ports(l, b.subjects[1]);
    try settings(l, b.open, .param);
    try l.endCard();
    try l.block(l.a.statement(b.stmt).block);
    try l.put(".ends");
    try l.endCard();
}

/// Writes a positional port list (` a b c`); a `port=node` in it is refused.
fn ports(l: *Lowerer, node: Index) Allocator.Error!void {
    const a = l.a;
    const one = [1]Index{if (a.tag(node) == .paren) a.node(node).lhs else ast.none};
    const items: []const Index = switch (a.tag(node)) {
        .paren => &one,
        .group, .tuple => a.children(node),
        else => return,
    };
    for (items) |p| switch (a.tag(p)) {
        .word, .string, .number => {
            try l.put(" ");
            try l.putName(p);
        },
        else => try l.diags.add(.wrong_kind, a.at(p), a.text(p)),
    };
}

/// ` key=value` per setting, each value in `ctx`.
fn settings(l: *Lowerer, items: []const Index, ctx: expr.Ctx) Allocator.Error!void {
    const a = l.a;
    for (items) |s| {
        const key = a.node(s).lhs;
        if (a.tag(key) != .word) try l.diags.add(.wrong_kind, a.at(key), a.text(key));
        try l.put(" ");
        try l.putName(key);
        try l.put("=");
        try expr.writeValue(l, a.node(s).rhs, ctx);
    }
}

fn global(l: *Lowerer, b: Bound) Allocator.Error!void {
    try l.put(".global");
    try names(l, b.subjects);
}

fn connect(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.subjects.len != 2) return;
    try l.put(".connect");
    try names(l, b.subjects);
}

fn names(l: *Lowerer, nodes: []const Index) Allocator.Error!void {
    for (nodes) |n| {
        try l.put(" ");
        try l.putName(n);
    }
    try l.endCard();
}

/// `.if c { }` `.elseif c { }` `.else { }` is `.if (c)` ... `.elseif (c)`
/// ... `.else` ... `.endif`, closed after the chain's last branch.
fn ifBranch(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const word = a.text(b.stmt);
    const opens = std.mem.eql(u8, word, ".if");
    // Read before the body's statements move `next`.
    const continues = !std.mem.eql(u8, word, ".else") and (l.next == .elseif or l.next == .@"else");
    if (!opens and l.prev != .@"if" and l.prev != .elseif) return l.diags.add(.misplaced, a.at(b.stmt), word);
    try l.put(word);
    if (b.subjects.len == 1) {
        try l.put(" (");
        try expr.write(l, b.subjects[0], .param);
        try l.put(")");
    }
    try l.endCard();
    try l.block(a.statement(b.stmt).block);
    if (continues) return;
    try l.put(".endif");
    try l.endCard();
}

fn include(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.subjects.len != 1) return;
    if (source.foreignKindForPath(l.a.name(b.subjects[0])) != null) return l.diags.add(.hdl_include, l.a.at(b.subjects[0]), l.a.text(b.subjects[0]));
    try pathCard(l, b);
}

/// `.hdl "f"`, `.verilog "f"`, `.vec "f"`, `.include "f"`: the card and its path.
fn pathCard(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.subjects.len != 1) return;
    try l.print("{s} {s}", .{ l.a.text(b.stmt), l.a.text(b.subjects[0]) });
    try l.endCard();
}

/// `.lib "file" section` reads a section; `.lib section { ... }` defines
/// one, `.lib section` ... `.endl`.
fn lib(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const st = a.statement(b.stmt);
    if (st.has_block) {
        if (b.subjects.len != 1 or a.tag(b.subjects[0]) != .word) return l.diags.add(.arity, a.at(b.stmt), ".lib section { ... }");
        try l.print(".lib {s}", .{a.text(b.subjects[0])});
        try l.endCard();
        try l.block(st.block);
        try l.put(".endl");
        return l.endCard();
    }
    if (b.subjects.len != 2 or a.tag(b.subjects[0]) != .string) return l.diags.add(.arity, a.at(b.stmt), ".lib \"file\" section");
    try l.print(".lib {s} ", .{a.text(b.subjects[0])});
    try l.putName(b.subjects[1]);
    try l.endCard();
}

/// `.load file="x.ic"` is `.load file="x.ic"`; `.load` alone reads the deck's own.
fn load(l: *Lowerer, b: Bound) Allocator.Error!void {
    try l.put(".load");
    if (b.keys[0] != ast.none) try l.print(" file={s}", .{l.a.text(b.keys[0])});
    try l.endCard();
}

/// `.save` with no key is the operating-point save's defaults, which
/// `TYPE=nodeset` selects: a bare legacy `.save` is a vector list.
fn save(l: *Lowerer, b: Bound) Allocator.Error!void {
    const row = schema.rows.get(.save);
    try l.put(".save");
    var any = false;
    for (row.keys, b.keys) |s, n| if (n != ast.none) {
        any = true;
        try l.print(" {s}=", .{s.key});
        if (s.ty == .quantity) try expr.writeValue(l, n, .param) else try l.put(l.a.text(n));
    };
    if (!any) try l.put(" type=nodeset");
    try l.endCard();
}

/// `.alter { ... }` is `.alter` and the block: the run lasts to the next
/// `.alter`, so only `.alter` may follow one.
fn alter(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (l.role != .top or l.depth != 1) return l.diags.add(.misplaced, l.a.at(b.stmt), ".alter");
    if (l.next != null and l.next != .alter) try l.diags.add(.misplaced, l.a.at(b.stmt), "a statement after an .alter block would join its run");
    try l.put(".alter");
    try l.endCard();
    try l.block(l.a.statement(b.stmt).block);
}

/// `.option reltol=1e-4 soa` is `.options reltol=1e-4 soa`: the settings
/// in the order written (the reader keeps it), then the flags, so no
/// number after one reads as its value.
fn option(l: *Lowerer, b: Bound) Allocator.Error!void {
    const row = schema.rows.get(.option);
    // Value nodes are made in source order.
    const order = try l.arena.alloc(usize, row.keys.len);
    for (order, 0..) |*o, i| o.* = i;
    std.sort.insertion(usize, order, b.keys, struct {
        fn lessThan(keys: []const Index, x: usize, y: usize) bool {
            return keys[x] < keys[y];
        }
    }.lessThan);
    try l.put(".options");
    for (order) |k| if (b.keys[k] != ast.none and row.keys[k].ty != .flag) {
        const s = row.keys[k];
        const n = b.keys[k];
        try l.print(" {s}=", .{s.key});
        switch (s.ty) {
            .word, .string => try l.put(l.a.text(n)),
            else => try expr.writeValue(l, n, .param),
        }
    };
    for (row.keys, b.keys) |s, n| if (n != ast.none and s.ty == .flag) try l.print(" {s}", .{s.key});
    try l.endCard();
}

/// `.ic v(n)=1V` is `.ic v(n)=1`; so is `.nodeset`.
fn state(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.open.len == 0) return l.diags.add(.arity, a.at(b.stmt), a.text(b.stmt));
    try l.put(a.text(b.stmt));
    for (b.open) |s| {
        const key = a.node(s).lhs;
        if (a.tag(key) != .call or !std.mem.eql(u8, a.callee(key), "v")) try l.diags.add(.wrong_kind, a.at(key), a.text(key));
        try l.put(" ");
        try l.putProbe(key);
        try l.put("=");
        try expr.writeValue(l, a.node(s).rhs, .param);
    }
    try l.endCard();
}

/// `.probe v(out) i(Vdd)` is `.save v(out) i(Vdd)`.
fn probe(l: *Lowerer, b: Bound) Allocator.Error!void {
    try l.put(".save");
    for (b.subjects) |p| {
        try l.put(" ");
        try l.putProbe(p);
    }
    try l.endCard();
}
