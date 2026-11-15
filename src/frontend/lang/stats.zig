//! Rows and lowerings of the statistics and reliability directives:
//! `.variation .mosra .appendmodel .sample`. In: a bound statement (for
//! `.variation`, its block of `global`, `local` and `element` blocks of
//! sigma rows). Out: the legacy cards: the `.variation` block with its
//! `.global_variation`, `.local_variation`, `.element_variation` parts
//! (each closed by its `.end_*` card), `.mosra` with SimMode and RelMode
//! as the integers the reader reads, `.appendmodel src mosra dst type`,
//! `.sample`.
//! Cites: docs/using/language.md "Statistics", "Reliability";
//! src/frontend/Netlist/reader_sweeps.zig `readVariation`, `sigmaExpr`,
//! `percentValue`; src/frontend/Netlist/reader_directives.zig
//! `readMosra`, `readSample` and its `.appendmodel` arm;
//! src/frontend/Jobs/variant_mismatch.zig (an element row matches the
//! card letter); src/core/deck.zig `Mosra`.
//!
//! Contents:
//! - `pub const rows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const check = @import("check.zig");
const number = @import("number.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;
const Index = ast.Index;

/// This area's rows of the directive table.
pub const rows = .{
    .variation = Row{ .block = true, .lower = variation },
    .mosra = Row{ .keys = &mosra_keys, .lower = mosra },
    .appendmodel = Row{ .keys = &append_keys, .lower = appendmodel },
    .sample = Row{ .keys = &sample_keys, .lower = sample },
};

/// `readMosra`'s keys, in its order.
const mosra_keys = [_]Slot{
    .{ .key = "reltotaltime", .ty = .quantity, .q = .time, .need = .required },
    .{ .key = "relstarttime", .ty = .quantity, .q = .time },
    .{ .key = "relstep", .ty = .quantity, .q = .time },
    // SimMode 0: degradation only; 2: the aged runs too (reader 1 and 3 refused).
    .{ .key = "simmode", .ty = .word, .words = &.{ "degradation", "aged" } },
    // RelMode 0, 1, 2.
    .{ .key = "relmode", .ty = .word, .words = &.{ "both", "hci", "bti" } },
    .{ .key = "agingstart", .ty = .quantity, .q = .time },
    .{ .key = "agingstop", .ty = .quantity, .q = .time },
    .{ .key = "hcithreshold", .ty = .quantity, .q = .voltage },
    .{ .key = "nbtithreshold", .ty = .quantity, .q = .voltage },
    .{ .key = "degf", .ty = .quantity, .q = .voltage },
};

/// The legacy integer of each `simmode` and `relmode` word, by word index.
const simmode_codes = [_][]const u8{ "0", "2" };
const relmode_codes = [_][]const u8{ "0", "1", "2" };

const append_keys = [_]Slot{
    .{ .key = "from", .ty = .reference, .need = .required },
    .{ .key = "to", .ty = .reference, .need = .required },
    .{ .key = "type", .ty = .word, .words = &.{ "nmos", "pmos" }, .need = .required },
};

const sample_keys = [_]Slot{
    .{ .key = "fs", .ty = .quantity, .q = .frequency, .need = .required },
    .{ .key = "tol", .ty = .real },
    .{ .key = "numf", .ty = .integer },
    .{ .key = "maxfld", .ty = .integer },
    .{ .key = "beta", .ty = .real },
};

/// The parts of a `.variation` block.
const Part = enum(u2) { global, local, element };

/// The card letter an `element` row's head names (`variant_mismatch.zig`
/// matches it against each device's letter): the primitives, the kinds
/// of modelled device, and Verilog-A module instances.
const element_letters = std.StaticStringMap(u8).initComptime(.{
    .{ "resistor", 'r' }, .{ "capacitor", 'c' }, .{ "inductor", 'l' }, .{ "mutual", 'k' },
    .{ "vsource", 'v' },  .{ "isource", 'i' },   .{ "vcvs", 'e' },     .{ "vccs", 'g' },
    .{ "cccs", 'f' },     .{ "ccvs", 'h' },      .{ "bsource", 'b' },  .{ "tline", 't' },
    .{ "sparam", 's' },   .{ "wline", 'w' },     .{ "mosfet", 'm' },   .{ "bjt", 'q' },
    .{ "diode", 'd' },    .{ "jfet", 'j' },      .{ "mesfet", 'z' },   .{ "vswitch", 's' },
    .{ "cswitch", 'w' },  .{ "ltra", 'o' },      .{ "txl", 'y' },      .{ "cpl", 'p' },
    .{ "urc", 'u' },      .{ "module", 'n' },
});

// ---- private ----

/// `.variation { global { ... } local { ... } element { ... } }` is
/// `.variation`, each part as `.<part>_variation` ... `.end_<part>_variation`,
/// then `.end_variation`.
fn variation(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    try l.put(".variation");
    try l.endCard();
    for (a.span(a.statement(b.stmt).block)) |s| {
        const st = if (a.tag(s) == .row) a.statement(s) else null;
        const items: []const Index = if (st) |x| a.span(x.items) else &.{};
        if (st == null or !st.?.has_block or items.len != 1 or a.tag(items[0]) != .word) {
            try l.diags.add(.misplaced, a.at(s), "a .variation block holds global { }, local { } and element { }");
            continue;
        }
        const part = std.meta.stringToEnum(Part, a.text(items[0])) orelse {
            try l.diags.add(.unknown_word, a.at(items[0]), a.text(items[0]));
            continue;
        };
        try l.print(".{t}_variation", .{part});
        try l.endCard();
        for (a.span(st.?.block)) |r| try sigmaRow(l, r, part);
        try l.print(".end_{t}_variation", .{part});
        try l.endCard();
    }
    try l.put(".end_variation");
    try l.endCard();
}

/// `<type> <model> key=sigma ...` (global, local) or `<primitive>
/// key=sigma ...` (element), as the legacy row with the element's letter.
fn sigmaRow(l: *Lowerer, r: Index, part: Part) Allocator.Error!void {
    const a = l.a;
    if (a.tag(r) != .row or a.statement(r).has_block) return l.diags.add(.misplaced, a.at(r), "a sigma row is a line of its own");
    const items = a.span(a.statement(r).items);
    const head: usize = if (part == .element) 1 else 2;
    var sigmas: usize = 0;
    for (items) |it| sigmas += @intFromBool(a.tag(it) == .setting);
    if (items.len != head + sigmas or sigmas == 0) return l.diags.add(.arity, a.at(r), if (part == .element) "<primitive> key=sigma ..." else "<type> <model> key=sigma ...");
    for (items[0..head]) |h| if (a.tag(h) == .setting) return l.diags.add(.arity, a.at(h), "the row's head before its sigmas");
    if (part == .element) {
        if (a.tag(items[0]) != .word) return l.diags.add(.wrong_kind, a.at(items[0]), a.text(items[0]));
        const letter = element_letters.get(a.text(items[0])) orelse return l.diags.add(.unknown_word, a.at(items[0]), a.text(items[0]));
        try l.print("{c}", .{letter});
    } else {
        // The type is HSPICE's and the reader skips it: the model name selects.
        try check.value(l, .{ .key = "type", .ty = .reference }, items[0]);
        try check.value(l, .{ .key = "model", .ty = .reference }, items[1]);
        try l.putName(items[0]);
        try l.put(" ");
        try l.putName(items[1]);
    }
    for (items[head..]) |s| {
        const key = a.node(s).lhs;
        const v = a.node(s).rhs;
        if (a.tag(key) != .word) try l.diags.add(.wrong_kind, a.at(key), a.text(key));
        try check.value(l, .{ .key = "sigma", .ty = .expr }, v);
        try l.print(" {s}=", .{a.text(key)});
        try sigma(l, v);
    }
    try l.endCard();
}

/// A sigma: `5%` is relative and stays `5%` (`percentValue`); any other
/// literal or name as the number, an expression quoted (`sigmaExpr`).
fn sigma(l: *Lowerer, v: Index) Allocator.Error!void {
    const a = l.a;
    if (a.tag(v) == .number) if (number.read(a.text(v)).number) |n| if (n.unit == .pct) {
        return l.print("{s}%", .{n.mantissa});
    };
    try expr.writeValue(l, v, .param);
}

/// `.mosra reltotaltime= ...` is `.mosra reltotaltime=... simmode=2 ...`.
fn mosra(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".mosra");
    for (mosra_keys, b.keys) |s, n| if (n != ast.none) {
        try l.print(" {s}=", .{s.key});
        if (s.ty != .word) {
            try expr.writeValue(l, n, .param);
            continue;
        }
        const codes: []const []const u8 = if (std.mem.eql(u8, s.key, "simmode")) &simmode_codes else &relmode_codes;
        // A word the slot does not list was reported by the check.
        const i = for (s.words, 0..) |w, k| {
            if (std.mem.eql(u8, w, l.a.text(n))) break k;
        } else 0;
        try l.put(codes[i]);
    };
    try l.endCard();
}

/// `.appendmodel from=src to=dst type=nmos` is `.appendmodel src mosra dst nmos`.
fn appendmodel(l: *Lowerer, b: Bound) Allocator.Error!void {
    const from, const to, const ty = b.keys[0..3].*;
    if (from == ast.none or to == ast.none or ty == ast.none) return;
    try l.put(".appendmodel ");
    try l.putName(from);
    try l.put(" mosra ");
    try l.putName(to);
    try l.print(" {s}", .{l.a.text(ty)});
    try l.endCard();
}

/// `.sample fs= [tol= numf= maxfld= beta=]`, the same keys.
fn sample(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".sample");
    for (sample_keys, b.keys) |s, n| if (n != ast.none) {
        try l.print(" {s}=", .{s.key});
        try expr.writeValue(l, n, .param);
    };
    try l.endCard();
}
