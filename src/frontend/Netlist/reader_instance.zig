//! The lowering's `?@` instance card. In: `?@<name> ( <ports> ) <master>
//! [key=value | flag]...`, the card of an ESPice-language instance whose
//! kind its master decides. Out: the legacy card of that kind as
//! `<letter>@<name>` text, which `readDevice` reads as any other card: an
//! X card for a subcircuit, the model type's letter for a `.model`, an N
//! card (a Verilog-A module) for any other master.
//! Cites: docs/using/language.md (Instances, the ports of a modelled
//! device); ngspice inpdomod.c (model types), inp2w.c and inp2s.c (the
//! switch's sensing source and ON/OFF word).
//!
//! Contents:
//! - `pub fn legacyCard(r: *Reader, card: F, frame: *const Frame) Error!F`
//! - `pub fn probeLetter(r: *Reader, frame: *const Frame, dev: []const u8) u8`
//! - `pub fn letterOfKind(kind: []const u8) u8`
//! - `pub const Ports = struct`
//! - `pub const Order = union(enum)`
//! - `pub fn order(a: Allocator, given: []const []const u8, nodes: []const []const u8, ports: Ports) Allocator.Error!Order`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const reader_diag = @import("reader_diag.zig");
const reader_expand = @import("reader_expand.zig");
const F = Ast.Cursor;
const Reader = reader.Reader;
const Error = card_rows.Error;
const Frame = reader_frame.Frame;

/// A master's port names in order; the first `required` must be given.
pub const Ports = struct { names: []const []const u8, required: usize };

/// `order`'s verdict: the nodes in the master's port order, or the port
/// name that refuses the list.
pub const Order = union(enum) {
    nodes: []const []const u8,
    /// Not one of the master's ports.
    unknown: []const u8,
    /// Given twice.
    repeated: []const u8,
    /// A required port, or one before a given optional port, left out.
    missing: []const u8,
};

/// ngspice's VDMOS: three terminals, then the thermal ones when given.
const vdmos_ports: Ports = .{ .names = &.{ "d", "g", "s", "tj", "tc" }, .required = 3 };

/// `.model` types by the card letter they make (ngspice inpdomod.c; the
/// semiconductor ones are Circuit/spice.zig `families`). tests/fuzz.zig
/// reads a `?@` card of every type against its hand-written legacy card.
const kinds = std.StaticStringMap(u8).initComptime(.{
    .{ "nmos", 'm' }, .{ "pmos", 'm' }, .{ "vdmos", 'm' }, .{ "vdmosn", 'm' }, .{ "vdmosp", 'm' },
    .{ "npn", 'q' },  .{ "pnp", 'q' },  .{ "d", 'd' },     .{ "njf", 'j' },    .{ "pjf", 'j' },
    .{ "nmf", 'z' },  .{ "pmf", 'z' },  .{ "nhfet", 'z' }, .{ "phfet", 'z' },  .{ "sw", 's' },
    .{ "csw", 'w' },  .{ "ltra", 'o' }, .{ "txl", 'y' },   .{ "cpl", 'p' },    .{ "urc", 'u' },
    .{ "r", 'r' },    .{ "res", 'r' },  .{ "c", 'c' },     .{ "l", 'l' },
});

/// The legacy card `card`, a `?@` card read under `frame`, stands for, as
/// a cursor over new text in the arena. `ParseError`, with a row naming
/// the port or setting, for a port list that mixes positional nodes and
/// `port=node` pairs, names a port the master lacks, repeats one or leaves
/// a required one out, or for a setting the resolved kind does not take.
/// An unknown master reads as an N card, which fails as an N card naming
/// no module does.
pub fn legacyCard(r: *Reader, card: F, frame: *const Frame) Error!F {
    const a = r.arena;
    const line = card.line;
    var f = card;
    const head = f.field() orelse return error.ParseError;
    assert(std.mem.startsWith(u8, head, "?@"));
    if (head.len == 2 or (f.nextByte() orelse return error.ParseError) != '(') return error.ParseError;
    _ = f.field();

    // The port list: all nodes, or all `port=node` pairs.
    var given: std.ArrayList([]const u8) = .empty;
    var nodes: std.ArrayList([]const u8) = .empty;
    while (true) {
        const t = f.field() orelse return error.ParseError;
        if (t[0] == ')') break;
        if (t[0] == ',') continue;
        if (!F.isWord(t)) return error.ParseError;
        const named = f.takeEq();
        if (named != (given.items.len > 0) and nodes.items.len > 0)
            return refuse(r, line, "a port list mixes nodes and port=node pairs at '{s}'", .{t});
        if (named) {
            try given.append(a, t);
            const node = f.field() orelse return error.ParseError;
            if (!F.isWord(node)) return error.ParseError;
            try nodes.append(a, node);
        } else try nodes.append(a, t);
    }
    const master = f.field() orelse return error.ParseError;
    if (!F.isWord(master)) return error.ParseError;

    // The kind: a subcircuit, else a `.model` in scope, else a module.
    const sub = r.decl.subckt_ids.get(master);
    const letter = masterLetter(r, master, frame);
    const ports: ?Ports = if (sub) |id| .{ .names = r.decl.subckts.items[id].ports, .required = r.decl.subckts.items[id].ports.len } else if (isVdmos(r, master, frame)) vdmos_ports else modelPorts(letter);
    const ordered: []const []const u8 = if (given.items.len == 0) nodes.items else switch (try order(a, given.items, nodes.items, ports orelse
        return refuse(r, line, "port '{s}' is named, but '{s}' takes its ports in order only", .{ given.items[0], master }))) {
        .nodes => |n| n,
        .unknown => |p| return refuse(r, line, "'{s}' has no port '{s}'", .{ master, p }),
        .repeated => |p| return refuse(r, line, "port '{s}' is given twice", .{p}),
        .missing => |p| return refuse(r, line, "port '{s}' of '{s}' is not given", .{ p, master }),
    };

    // The settings, each mapped to the legacy field the kind takes.
    var probe: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var rest: std.ArrayList(u8) = .empty;
    const switch_kind = letter == 's' or letter == 'w';
    while (f.field()) |t| {
        if (!F.isWord(t) or !f.takeEq()) {
            try rest.print(a, " {s}", .{t});
            continue;
        }
        const v = f.field() orelse return error.ParseError;
        if (std.mem.eql(u8, t, "probe")) {
            if (letter != 'w') return refuse(r, line, "probe= on a master that is no current-controlled switch", .{});
            probe = v;
        } else if (std.mem.eql(u8, t, "initial")) {
            if (!switch_kind) return refuse(r, line, "initial= on a master that is no switch", .{});
            if (!std.mem.eql(u8, v, "on") and !std.mem.eql(u8, v, "off")) return refuse(r, line, "initial={s}: a switch starts on or off", .{v});
            state = v;
        } else try rest.print(a, " {s}={s}", .{ t, v });
    }
    if (letter == 'w' and probe == null) return refuse(r, line, "a current-controlled switch without probe=", .{});

    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{c}@{s}", .{ letter, head[2..] });
    for (ordered) |n| try out.print(a, " {s}", .{n});
    if (probe) |p| try out.print(a, " {s}", .{p});
    try out.print(a, " {s}{s}", .{ master, rest.items });
    if (state) |s| try out.print(a, " {s}", .{s});
    assert(out.items[1] == '@');
    return F.initLine(a, out.items);
}

/// The kind letter of the device named `dev` that an `i(dev)` inside
/// `frame`'s subcircuit reads, the prefix of its flattened name
/// (`reader_card.commit`): that of the body's `<letter>@<dev>` or
/// `?@<dev>` card, else `dev`'s first letter, as ngspice reads a name.
/// Asserts `dev` is not empty.
// ponytail: scans the body per probe; index the body's heads by name if a
// subcircuit holds thousands of cards and probes.
pub fn probeLetter(r: *Reader, frame: *const Frame, dev: []const u8) u8 {
    assert(dev.len > 0);
    const fallback = dev[0];
    const id = frame.sub orelse return fallback;
    const sub = r.decl.subckts.items[id];
    const tags = r.ast.cards.items(.tag);
    var nested: u32 = 0;
    for (sub.first..sub.end) |i| {
        if (sub.has_nested and reader_expand.skipNested(tags[i], &nested)) continue;
        if (tags[i] != .device) continue;
        var f = r.ast.cursor(@intCast(i));
        const head = f.field() orelse continue;
        if (head.len < 3 or head[1] != '@' or !std.ascii.eqlIgnoreCase(head[2..], dev)) continue;
        if (head[0] != '?') return std.ascii.toLower(head[0]);
        // `?@<dev> ( <ports> ) <master>`: the master's kind.
        while (f.field()) |t| if (t[0] == ')') break;
        return masterLetter(r, f.field() orelse return fallback, frame);
    }
    return fallback;
}

/// The card letter of `.model` type `kind`; `n`, a Verilog-A module's, for
/// a type ngspice does not read itself.
pub fn letterOfKind(kind: []const u8) u8 {
    var buf: [8]u8 = undefined;
    if (kind.len > buf.len) return 'n';
    return kinds.get(std.ascii.lowerString(&buf, kind)) orelse 'n';
}

/// `nodes` reordered by their port names `given` to `ports`' order.
/// Asserts the two lists are as long.
pub fn order(a: Allocator, given: []const []const u8, nodes: []const []const u8, ports: Ports) Allocator.Error!Order {
    assert(given.len == nodes.len);
    assert(ports.required <= ports.names.len);
    const slots = try a.alloc(?[]const u8, ports.names.len);
    @memset(slots, null);
    for (given, nodes) |name, node| {
        const k = for (ports.names, 0..) |p, k| {
            if (std.mem.eql(u8, p, name)) break k;
        } else return .{ .unknown = name };
        if (slots[k] != null) return .{ .repeated = name };
        slots[k] = node;
    }
    // The given ports must fill a prefix at least `required` long.
    const count = @max(given.len, ports.required);
    const out = try a.alloc([]const u8, count);
    for (slots[0..count], out, ports.names[0..count]) |s, *o, p| o.* = s orelse return .{ .missing = p };
    assert(out.len >= ports.required);
    return .{ .nodes = out };
}

// ---- private ----

/// The ports of a modelled device by its letter (language.md, "The ports
/// of a modelled device"). CPL lines take positional ports only, and a
/// Verilog-A module's ports are known only once it is compiled, after the
/// read: neither has a row.
fn modelPorts(letter: u8) ?Ports {
    return switch (letter) {
        'm' => .{ .names = &.{ "d", "g", "s", "b" }, .required = 4 },
        'q' => .{ .names = &.{ "c", "b", "e", "s" }, .required = 3 },
        'd' => .{ .names = &.{ "a", "k", "tj" }, .required = 2 },
        'j', 'z' => .{ .names = &.{ "d", "g", "s" }, .required = 3 },
        's' => .{ .names = &.{ "p", "n", "cp", "cn" }, .required = 4 },
        'w', 'r', 'c', 'l' => .{ .names = &.{ "p", "n" }, .required = 2 },
        'o', 'y' => .{ .names = &.{ "a1", "b1", "a2", "b2" }, .required = 4 },
        'u' => .{ .names = &.{ "n1", "n2", "n3" }, .required = 3 },
        else => null,
    };
}

fn isVdmos(r: *const Reader, master: []const u8, frame: *const Frame) bool {
    const kind = modelKind(r, master, frame) orelse return false;
    return std.ascii.startsWithIgnoreCase(kind, "vdmos");
}

/// The card letter `master` makes in `frame`'s scope: `x` for a
/// subcircuit, the type's letter for a `.model`, else `n`, a Verilog-A
/// module's.
fn masterLetter(r: *const Reader, master: []const u8, frame: *const Frame) u8 {
    if (r.decl.subckt_ids.get(master) != null) return 'x';
    return letterOfKind(modelKind(r, master, frame) orelse return 'n');
}

/// The type of the `.model` `name` names in `frame`'s scope: the
/// subcircuit's own card, a global one, or the first card of its bins
/// (`name.1`, ...); null when no card has the name.
fn modelKind(r: *const Reader, name: []const u8, frame: *const Frame) ?[]const u8 {
    const models = r.nl.models.items;
    if (frame.sub) |id| {
        const sub = r.decl.subckts.items[id];
        for (r.local.models.items[sub.models_lo..sub.models_hi]) |m| if (std.mem.eql(u8, m.name, name)) return models[m.top].kind;
    }
    if (r.nl.model_ids.get(name)) |row| return models[row].kind;
    for (models) |m| if (card_table.isBinOf(m.name, name)) return m.kind;
    return null;
}

/// Records why `line` is refused, naming the port or setting, and
/// returns `ParseError`.
fn refuse(r: *Reader, line: []const u8, comptime fmt: []const u8, args: anytype) Error {
    return reader_diag.invalid(r, line, try r.arena.print(fmt, args));
}
