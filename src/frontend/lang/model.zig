//! `.model` of the ESPice language. In: `.model name family [type=]
//! settings`. Out: `.model name <legacy type> [level=n] [type=±1]
//! settings`, the type, level and polarity from the family table,
//! `tol(...)` as HSPICE's `LOT/`/`DEV/` keys; a family the table does not
//! list is a Verilog-A module's name and passes as written.
//! Cites: docs/using/language.md "Models"; docs/using/devices.md "Model
//! type and LEVEL", "Polarity"; src/frontend/Circuit/spice.zig (the level
//! tables, `module_map`); each module's `TYPE` in models/*.va;
//! src/frontend/Netlist/reader_sweeps.zig `devLot`.
//!
//! Contents:
//! - `pub const row`
//! - `pub const Polarity`
//! - `pub const Family`
//! - `pub const families`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const number = @import("number.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Bound = schema.Bound;
const Index = ast.Index;

/// The `.model` row of the directive table.
pub const row: schema.Row = .{
    .subjects = &.{ .{ .key = "name", .ty = .reference, .need = .required }, .{ .key = "family", .ty = .reference, .need = .required } },
    .open = true,
    .lower = lower,
};

/// Which `type=` words a family takes, and what the legacy card reads
/// them as: the type word itself (`kind`: `nmos`/`pmos`, `npn`/`pnp`), or
/// the model's own polarity parameter (`param`: `type=1`/`type=-1`, a
/// Verilog-A module's `TYPE`; devices.md "Polarity").
pub const Polarity = enum(u3) { none, np_kind, bjt_kind, np_param, bjt_param };

/// One family: its legacy type word (`p` the P one, for `np_kind` and
/// `bjt_kind`) and its LEVEL. A type word with no LEVEL is a Verilog-A
/// module's name (spice.zig `module_map`) or a type no LEVEL refines.
pub const Family = struct { n: []const u8, p: []const u8 = "", level: ?u16 = null, polarity: Polarity = .none };

/// Every family the language names, to its legacy `.model` type. A test
/// (tests/lang_devices.zig) holds it to every device spice.zig selects.
pub const families = std.StaticStringMap(Family).initComptime(.{
    .{ "mos1", mos(1) },                               .{ "mos2", mos(2) },                                                     .{ "mos3", mos(3) },                                 .{ "mos6", mos(6) },
    .{ "mos9", mos(9) },                               .{ "bsim1", mos(4) },                                                    .{ "bsim2", mos(5) },                                .{ "bsim3", mos(8) },
    .{ "bsim4", mos(14) },                             .{ "bsimsoi", mos(10) },                                                 .{ "b3soifd", mos(55) },                             .{ "b3soidd", mos(56) },
    .{ "hisim2", mos(68) },                            .{ "hisimhv", mos(73) },                                                 .{ "bsimcmg", mos(72) },                             .{ "bsimbulk", mos(77) },
    .{ "bsimimg", mos(78) },                           .{ "l_utsoi", mos(76) },                                                 .{ "psp103", mos(1040) },                            .{ "psp103_nqs", module("pspnqs103va", .np_param) },
    .{ "psp103_t", module("psp103tva", .np_param) },   .{ "psp104", module("psp104va", .np_param) },                            .{ "psp104_nqs", module("pspnqs104va", .np_param) }, .{ "psp104_t", module("psp104tva", .np_param) },
    .{ "hisimsoi", module("hisimsoi_va", .np_param) }, .{ "hisimsotb", module("hisimsotb_va", .np_param) },                     .{ "mosvar", module("mosvar", .none) },              .{ "vdmos", Family{ .n = "vdmos", .p = "vdmosp", .polarity = .np_kind } },
    .{ "asmhemt", module("asmhemt", .none) },          .{ "mvsg", module("mvsg_cmc", .np_param) },                              .{ "gummel_poon", bjt(1) },                          .{ "vbic", bjt(4) },
    .{ "hicuml2", bjt(8) },                            .{ "mextram", bjt(6) },                                                  .{ "mextram_t", module("bjt505t", .bjt_param) },     .{ "hicuml0", module("hicuml0va", .bjt_param) },
    .{ "diode", Family{ .n = "d", .level = 1 } },      .{ "juncap200", Family{ .n = "d", .level = 6, .polarity = .np_param } }, .{ "diode_cmc", module("diode_cmc", .none) },        .{ "asmesd", module("asmesd", .bjt_param) },
    .{ "asmesd_dio", module("asmesd_dio", .none) },    .{ "r2_cmc", module("r2_cmc", .none) },                                  .{ "r3_cmc", module("r3_cmc", .none) },              .{ "jfet", np("njf", "pjf", 1) },
    .{ "jfet2", np("njf", "pjf", 2) },                 .{ "mesfet", np("nmf", "pmf", 1) },                                      .{ "mesa", np("nmf", "pmf", 2) },                    .{ "hfet1", np("nmf", "pmf", 5) },
    .{ "hfet2", np("nmf", "pmf", 6) },                 .{ "vswitch", Family{ .n = "sw" } },                                     .{ "cswitch", Family{ .n = "csw" } },                .{ "ltra", Family{ .n = "ltra" } },
    .{ "txl", Family{ .n = "txl" } },                  .{ "cpl", Family{ .n = "cpl" } },                                        .{ "urc", Family{ .n = "urc" } },                    .{ "resistor", Family{ .n = "r" } },
    .{ "capacitor", Family{ .n = "c" } },              .{ "inductor", Family{ .n = "l" } },                                     .{ "opt", Family{ .n = "opt" } },                    .{ "mosra", Family{ .n = "mosra", .level = 1 } },
});

// ---- private ----

fn mos(comptime level: u16) Family {
    return np("nmos", "pmos", level);
}

fn bjt(comptime level: u16) Family {
    return .{ .n = "npn", .p = "pnp", .level = level, .polarity = .bjt_kind };
}

fn np(comptime n: []const u8, comptime p: []const u8, comptime level: u16) Family {
    return .{ .n = n, .p = p, .level = level, .polarity = .np_kind };
}

/// A family the legacy card names by its Verilog-A module (devices.md:
/// "An `N` card whose `.model` type is a model's Verilog-A module name").
fn module(comptime name: []const u8, comptime polarity: Polarity) Family {
    return .{ .n = name, .polarity = polarity };
}

fn lower(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    if (b.subjects.len != 2) return;
    const family_name = a.name(b.subjects[1]);
    const family = families.get(family_name);
    // The polarity, for a family that has one: the type word, or the
    // module's own `type` parameter after the level.
    var kind: []const u8 = if (family) |f| f.n else family_name;
    var type_param: ?[]const u8 = null;
    var type_node: Index = ast.none;
    if (family) |f| if (f.polarity != .none) {
        for (b.open) |s| if (isKey(a, s, "type")) {
            type_node = a.node(s).rhs;
        };
        const words: [2][]const u8 = switch (f.polarity) {
            .np_kind, .np_param => .{ "n", "p" },
            .bjt_kind, .bjt_param => .{ "npn", "pnp" },
            .none => unreachable,
        };
        if (type_node == ast.none) return l.diags.add(.missing_key, a.at(b.stmt), "type");
        const t = a.text(type_node);
        const second = std.mem.eql(u8, t, words[1]);
        if (!second and !std.mem.eql(u8, t, words[0])) return l.diags.add(.unknown_family, a.at(type_node), t);
        switch (f.polarity) {
            .np_kind, .bjt_kind => kind = if (second) f.p else f.n,
            .np_param, .bjt_param => type_param = if (second) "-1" else "1",
            .none => unreachable,
        }
    };
    try l.put(".model ");
    try l.putName(b.subjects[0]);
    try l.print(" {s}", .{kind});
    if (family) |f| if (f.level) |lv| try l.print(" level={d}", .{lv});
    if (type_param) |t| try l.print(" type={s}", .{t});
    for (b.open) |s| {
        const key = a.node(s).lhs;
        if (a.tag(key) != .word) {
            try l.diags.add(.wrong_kind, a.at(key), a.text(key));
            continue;
        }
        if (a.node(s).rhs == type_node) continue;
        if (family != null and std.ascii.eqlIgnoreCase(a.text(key), "level")) try l.diags.add(.retired, a.at(key), "level= (the family names the model)");
        try l.print(" {s}=", .{a.text(key)});
        try value(l, a.node(s).rhs);
    }
    try l.endCard();
}

fn isKey(a: *const ast.Ast, s: Index, key: []const u8) bool {
    return a.tag(a.node(s).lhs) == .word and std.mem.eql(u8, a.text(a.node(s).lhs), key);
}

/// A model value; `tol(v, lot=gauss(5%), dev=unif(2%))` is
/// `v lot/gauss=5% dev/unif=2%`, the value then HSPICE's tolerance keys.
fn value(l: *Lowerer, v: Index) Allocator.Error!void {
    const a = l.a;
    if (a.tag(v) != .call or !std.mem.eql(u8, a.callee(v), "tol")) return expr.writeValue(l, v, .param);
    const args = a.children(v);
    if (args.len == 0 or a.tag(args[0]) == .setting) return l.diags.add(.arity, a.at(v), "tol");
    try expr.writeValue(l, args[0], .param);
    for (args[1..]) |arg| {
        if (a.tag(arg) != .setting) return l.diags.add(.arity, a.at(arg), "tol");
        const key = a.text(a.node(arg).lhs);
        if (!std.mem.eql(u8, key, "lot") and !std.mem.eql(u8, key, "dev")) try l.diags.add(.unknown_key, a.at(arg), key);
        const dist = a.node(arg).rhs;
        const dists = std.StaticStringMap(void).initComptime(.{ .{"gauss"}, .{"unif"}, .{"limit"} });
        if (a.tag(dist) != .call or !dists.has(a.callee(dist)) or a.children(dist).len != 1)
            return l.diags.add(.wrong_kind, a.at(dist), "gauss(x), unif(x) or limit(x)");
        const x = a.children(dist)[0];
        const n = if (a.tag(x) == .number) number.read(a.text(x)).number else null;
        // The legacy reader takes a number here, `%` making it relative.
        const lit = n orelse return l.diags.add(.no_legacy, a.at(x), "a computed tolerance");
        try l.print(" {s}/{s}=", .{ key, a.callee(dist) });
        if (lit.unit == .pct) {
            try l.print("{s}%", .{lit.mantissa});
        } else try expr.write(l, x, .param);
    }
}
