//! Device operating-point variables (`@m1[gm]`, `@v1[dc]`, #236). In: the
//! deck's `.save`, `.probe` and `.meas` names and the frozen circuit. Out:
//! each variable resolved to its instance (`core.OpVar`), and the probe
//! rows that record it.
//! Cites: #236; VerA `op_vars`; ngspice through `opvar_ngspice.zig`.
//!
//! Contents:
//! - `pub const OpVars`
//! - `pub fn opVars(sim_arena: Allocator, scratch: Allocator, lib: *const device.Library, circuit: *const device.Circuit, cards: []const requests.CardRef, probes: []const u32, labels: []const []const u8, nl: *const netlist.Netlist, queries: []const requests.Query) !OpVars`

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const requests = core.query;
const netlist = @import("netlist");
const device = @import("device");
const ngspice = @import("opvar_ngspice.zig");
const Quantity = core.OpVar.Quantity;
const is_test = @import("builtin").is_test;

/// The variables, and the probe rows that record them: the deck's own
/// `probes` and `labels`, then each named instance's rows, unlabeled.
pub const OpVars = struct { vars: []const core.OpVar, probes: []const u32, labels: []const []const u8 };

/// A device operating-point variable's name, ngspice's
/// `@<card>[<variable>]`, split; `<card>` is the flattened card name.
const OpVarName = struct {
    device: []const u8,
    variable: []const u8,

    /// Null for a name of another form.
    fn of(name: []const u8) ?OpVarName {
        if (name.len == 0 or name[0] != '@') return null;
        const open = std.mem.indexOfScalar(u8, name, '[') orelse return null;
        if (open < 2 or name[name.len - 1] != ']') return null;
        return .{ .device = name[1..open], .variable = name[open + 1 .. name.len - 1] };
    }

    /// Whether `card`, a flattened card name, is the device `n` names.
    fn matches(n: OpVarName, card: []const u8) bool {
        return std.ascii.eqlIgnoreCase(card, n.device);
    }
};

/// A name resolved on one instance: the variable, a name the device does
/// not have, or one whose ngspice value the deck's `.tran` changes in a way
/// ESPice cannot replay.
const Resolved = union(enum) { ok: core.OpVar, unknown, tran };

/// The deck's `.tran`s, as a name ngspice's `.tran` changes reads them: none;
/// each replayable (`post/opvars.zig` replays the integrator over every
/// step from the operating point, which needs every row from t = 0 and
/// that start); or one that is not (TSTART > 0, `uic`, `.op <time>`).
const Trans = enum { none, replay, refuse };

/// What every resolution reads: where it allocates, the circuit, the
/// cards (their `m=` and `scale=`), and the deck's `.tran`s.
const Ctx = struct {
    arena: Allocator,
    lib: *const device.Library,
    circuit: *const device.Circuit,
    nl: *const netlist.Netlist,
    trans: Trans,

    /// `name`, an `OpVarName`, resolved to its instance; `mosfets` maps the
    /// MOSFETs' card names to whether each is p-type. See `opVars` for the
    /// refusals.
    fn opVar(ctx: Ctx, cards: []const requests.CardRef, mosfets: *const std.StringHashMapUnmanaged(bool), name: []const u8) !core.OpVar {
        const split = OpVarName.of(name) orelse {
            if (!is_test) std.log.err("netlist: {s}: a device operating-point variable is @<device>[<variable>]", .{name});
            return error.UnsupportedCard;
        };
        const ref = for (cards) |c| {
            if (split.matches(c.name)) break c;
        } else {
            if (!is_test) std.log.err("netlist: {s}: no device {s}", .{ name, split.device });
            return error.UnsupportedCard;
        };
        const pmos_card = mosfets.get(ref.name);
        switch (try ctx.resolve(ref, pmos_card, name, split.variable)) {
            .ok => |v| return v,
            .unknown => if (!is_test) {
                const there = try ctx.variables(ref, pmos_card);
                std.log.err("netlist: {s}: {s} has no variable '{s}'; its variables are: {s}", .{ name, ref.name, split.variable, there });
            },
            .tran => if (!is_test) std.log.err("netlist: {s}: in a .tran ngspice adds a charging current that {s}'s terminals do not show alone here, or the .tran keeps no step from its operating point (TSTART > 0, uic, .op <time>) to replay it over (#236)", .{ name, ref.name }),
        }
        return error.UnsupportedCard;
    }

    /// `variable` of instance `ref`, published as `label`; `pmos_card` is
    /// null unless its card is a MOSFET's, and then whether it is p-type.
    /// The order: ngspice's row (`opvar_ngspice`), the model's own variable
    /// (BSIM-CMG's `ids` is its own), the MOSFET terminal quantity, the
    /// parameter but `temp`. The row's `card` factor multiplies the value.
    fn resolve(ctx: Ctx, ref: requests.CardRef, pmos_card: ?bool, label: []const u8, variable: []const u8) !Resolved {
        const batch = batchOf(ctx.circuit, ref.type);
        const b = ctx.circuit.batches[batch];
        const type_name = ctx.lib.names.items[@backingInt(ref.type)];
        // diode_t's third port, tj, is thermal: the terminal quantities are
        // electrical, as dioask.c's p (id × vd + id²/gspr) is.
        // ponytail: one model by name; read VerA's port disciplines when a
        // second self-heated model reports terminal quantities.
        const ports = ctx.lib.vtable(ref.type).num_ports - @intFromBool(std.mem.eql(u8, type_name, "diode_t"));
        const lower = try std.ascii.allocLowerString(ctx.arena, variable);
        const row = ngspice.find(type_name, lower);
        var v: core.OpVar = .{ .label = label, .batch = @intCast(batch), .index = ref.index, .ports = ports, .pmos = pmos_card orelse false };
        switch (if (row) |r| r.to else ngspice.Target{ .name = lower }) {
            .none => return .unknown,
            .quantity => |q| v.quantity = q,
            .name => |name| {
                const mosfet = pmos_card != null and ports >= 3;
                if (ownIndex(b.hooks.op_vars, name)) |k| {
                    v.own = k;
                } else if (mosfetQuantity(mosfet, name)) |q| {
                    v.quantity = q;
                } else if (std.mem.eql(u8, name, "temp")) {
                    // A `temp` parameter is 27 unless the card gives one,
                    // where ngspice's is the instance's temperature
                    // (captemp.c, restemp.c, every <dev>temp.c).
                    return .unknown;
                } else if (try paramOrdinal(b, ref.index, name)) |ord| {
                    v.param = ord;
                } else return .unknown;
            },
        }
        if (v.param == null and b.hooks.local_eval == null) return .unknown;
        if (ctx.trans != .none) if (row) |r| switch (r.tran) {
            .same => {},
            .refused => return .tran,
            .charging => |c| {
                if (ctx.trans == .refuse) return .tran;
                for (c.pins) |pin| if ((try paramValue(b, ref.index, pin.name) orelse return .tran) != pin.value) return .tran;
                v.own = null;
                v.param = null;
                v.quantity = c.q;
                v.charging = true;
            },
            .companion => |cap| {
                if (ctx.trans == .refuse or v.own == null) return .tran;
                v.companion = ownIndex(b.hooks.op_vars, cap) orelse return .tran;
            },
        };
        if (row) |r| {
            v.times = ctx.cardFactor(ref.name, r.card);
            v.dynamic = r.tran != .same;
        }
        v.label = try ctx.arena.dupe(u8, label);
        return .{ .ok = v };
    }

    /// What `card` multiplies a value of card `name` by: its `m=`, over its
    /// `scale=` for `times_m_per_scale`, each 1 when the card gives none, as
    /// `net_passive.zig` folds them.
    // ponytail: scans the card letter's devices per name; index the cards
    // by name if a deck saves thousands of these.
    fn cardFactor(ctx: Ctx, name: []const u8, card: ngspice.Card) f64 {
        if (card == .none) return 1;
        const letter = std.ascii.toLower(name[0]);
        if (!std.ascii.isLower(letter)) return 1;
        const kv = for (ctx.nl.bucket(letter)) |e| {
            const d = ctx.nl.device(e);
            if (std.ascii.eqlIgnoreCase(d.name, name)) break d.kv;
        } else return 1;
        const m = cardNumber(kv, "m") orelse 1;
        return switch (card) {
            .none => unreachable,
            .times_m => m,
            .times_m_per_scale => m / (cardNumber(kv, "scale") orelse 1),
        };
    }

    /// The names instance `ref` answers, for the refusal: the model's own
    /// variables, the MOSFET terminal quantities, ngspice's names, the
    /// parameters. Never empty.
    fn variables(ctx: Ctx, ref: requests.CardRef, pmos_card: ?bool) ![]const u8 {
        const b = ctx.circuit.batches[batchOf(ctx.circuit, ref.type)];
        var all: std.ArrayList([]const u8) = .empty;
        if (b.hooks.local_eval != null) {
            try all.appendSlice(ctx.arena, b.hooks.op_vars);
            if (pmos_card != null and ctx.lib.vtable(ref.type).num_ports >= 3) for (core.OpVar.mosfet_quantities) |q| {
                try all.append(ctx.arena, @tagName(q));
            };
        }
        const type_name = ctx.lib.names.items[@backingInt(ref.type)];
        for (ngspice.rows) |r| for (r.devices) |d| if (std.mem.eql(u8, d, type_name)) {
            if ((try ctx.resolve(ref, pmos_card, "", r.name)) == .ok) try all.append(ctx.arena, r.name);
        };
        if (b.hooks.param_layout) |get| for ((try get(b.ctx).unwrap()).fields) |f| {
            if (!std.mem.eql(u8, f.name, "temp")) try all.append(ctx.arena, f.name);
        };
        return listOr(ctx.arena, all.items);
    }
};

/// The device operating-point variables (`@m1[gm]`, #236) the deck's
/// `.save`, `.probe` and `.meas` cards name, and what records them:
/// `probes` and `labels`, then each named instance's rows, unlabeled. A
/// variable is ngspice's name through `opvar_ngspice.rows`, else the
/// model's own (VerA `op_vars`), else for a MOSFET a terminal quantity
/// (`core.OpVar.mosfet_quantities`), else a parameter of the instance or
/// its model (`@v1[dc]`). A name that is none of these, or no `OpVarName`
/// of a device in the deck, is `UnsupportedCard`, logged with the variables
/// there are; so is a name whose ngspice value a `.tran` the deck runs
/// changes past what `post/opvars.zig` replays (`opvar_ngspice.Tran`,
/// `Trans`). So is a variable under a `.dc`
/// that sweeps the temperature or a device of its type, which would
/// evaluate the instance at the sweep's last state, and a parameter under
/// the outer sweep of a `.dc` that sweeps it.
pub fn opVars(
    sim_arena: Allocator,
    scratch: Allocator,
    lib: *const device.Library,
    circuit: *const device.Circuit,
    cards: []const requests.CardRef,
    probes: []const u32,
    labels: []const []const u8,
    nl: *const netlist.Netlist,
    queries: []const requests.Query,
) !OpVars {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (nl.deck.opvar_saves) |s| try names.put(scratch, s, {});
    for (nl.deck.measures) |m| for ([_]core.MeasureClause{ m.first, m.second }) |c| {
        for ([_][]const u8{ c.vec, c.vec2 }) |v| if (netlist.isOpVar(v)) try names.put(scratch, v, {});
        for ([_][]const core.MeasureOp{ c.ops, c.ops2 }) |ops| for (ops) |op| if (op == .vector and netlist.isOpVar(op.vector)) {
            try names.put(scratch, op.vector, {});
        };
    };
    if (names.count() == 0) return .{ .vars = &.{}, .probes = &.{}, .labels = &.{} };
    var trans: Trans = .none;
    for (queries) |q| if (q == .tran) {
        const t = q.tran;
        if (t.t_start > 0 or t.uic or t.snapshot) trans = .refuse else if (trans == .none) trans = .replay;
    };
    // The terminal quantities are a MOSFET's (d, g, s, b); each card maps
    // to whether it is p-type, as `.mosra` reads it.
    // ponytail: the card kind only; a `type=-1` on an nmos or Verilog-A
    // module card reads as n-type. Read the bound model's polarity if a
    // deck spells it that way.
    var mosfets: std.StringHashMapUnmanaged(bool) = .empty;
    for (nl.bucket('m')) |e| {
        const d = nl.device(e);
        try mosfets.put(scratch, d.name, if (d.model) |m| std.ascii.eqlIgnoreCase(m.kind, "pmos") else false);
    }
    const ctx: Ctx = .{ .arena = sim_arena, .lib = lib, .circuit = circuit, .nl = nl, .trans = trans };
    var list: std.ArrayList(core.OpVar) = .empty;
    for (names.keys()) |name| try list.append(sim_arena, try ctx.opVar(cards, &mosfets, name));
    const vars = list.items;
    var rows: std.ArrayList(u32) = .empty;
    try rows.appendSlice(sim_arena, probes);
    var row_labels: std.ArrayList([]const u8) = .empty;
    try row_labels.appendSlice(sim_arena, labels);
    for (vars) |v| {
        if (v.param != null) continue;
        const b = circuit.batches[v.batch];
        for (b.hooks.scatter_tapes(b.ctx).rows[@as(usize, v.index) * b.n_u ..][0..b.n_u]) |row| {
            // A ground unknown's row is `n`.
            if (row >= circuit.n or std.mem.indexOfScalar(u32, rows.items[probes.len..], row) != null) continue;
            try rows.append(sim_arena, row);
            try row_labels.append(sim_arena, "");
        }
    }
    for (queries) |q| if (q == .dc) for ([_]?requests.Dc.SweepTarget{ q.dc.target, q.dc.target2 }, 0..) |target, level| {
        const swept = target orelse continue;
        for (vars) |v| {
            if (v.param) |ord| {
                // The inner sweep's value is the scale (`post/opvars.zig`).
                if (level == 0 or swept == .temp or !try sweeps(circuit, swept.device, v, ord)) continue;
                if (!is_test) std.log.err("netlist: {s} along the outer sweep of a .dc that sweeps it is not supported (#236)", .{v.label});
                return error.UnsupportedCard;
            }
            if (swept != .temp and swept.device.type != circuit.batch_types[v.batch]) continue;
            if (!is_test) std.log.err("netlist: {s} along a .dc that sweeps the temperature or a device of its type is not supported (#236)", .{v.label});
            return error.UnsupportedCard;
        }
    };
    return .{ .vars = vars, .probes = rows.items, .labels = row_labels.items };
}

// ---- private ----

/// The number of the first `key=` in `kv`; null when absent or no number.
fn cardNumber(kv: anytype, key: []const u8) ?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return item.value.number();
    return null;
}

/// `names` space-separated, or a note that there are none: never empty.
fn listOr(arena: Allocator, names: []const []const u8) ![]const u8 {
    if (names.len == 0) return "(none: no variable and no parameter)";
    return std.mem.join(arena, " ", names);
}

/// The circuit batch of device type `t`. Asserts there is one.
fn batchOf(circuit: *const device.Circuit, t: core.DeviceType) usize {
    return std.mem.indexOfScalar(core.DeviceType, circuit.batch_types, t).?;
}

/// The index of `name` among a model's own variables `own`, ignoring case.
fn ownIndex(own: []const []const u8, name: []const u8) ?u32 {
    for (own, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o, name)) return @intCast(k);
    return null;
}

/// The MOSFET terminal quantity `name`, lowercase; null for another name
/// or a device that is no MOSFET.
fn mosfetQuantity(mosfet: bool, name: []const u8) ?Quantity {
    if (!mosfet) return null;
    const q = std.meta.stringToEnum(Quantity, name) orelse return null;
    return if (std.mem.indexOfScalar(Quantity, core.OpVar.mosfet_quantities, q) != null) q else null;
}

/// Parameter `name` of instance `index` (its own or its model's) as its
/// ordinal in the batch's `Hooks.param_layout`; null when there is none.
fn paramOrdinal(b: device.abi.Batch, index: u32, name: []const u8) !?u32 {
    const get = b.hooks.param_layout orelse return null;
    const l = try get(b.ctx).unwrap();
    std.debug.assert(index < l.count);
    for (l.fields, 0..) |f, k| if (std.ascii.eqlIgnoreCase(f.name, name)) return @intCast(k * l.count + index);
    return null;
}

/// Parameter `name` of instance `index`'s value; null when there is none.
fn paramValue(b: device.abi.Batch, index: u32, name: []const u8) !?f64 {
    const ord = try paramOrdinal(b, index, name) orelse return null;
    return (try b.hooks.param_layout.?(b.ctx).unwrap()).ptr(ord).*;
}

/// Whether `swept` is parameter `ord` of variable `v`'s instance.
fn sweeps(circuit: *const device.Circuit, swept: requests.Dc.SweepTarget.Param, v: core.OpVar, ord: u32) !bool {
    if (swept.type != circuit.batch_types[v.batch] or swept.index != v.index) return false;
    const b = circuit.batches[v.batch];
    const l = try b.hooks.param_layout.?(b.ctx).unwrap();
    return std.ascii.eqlIgnoreCase(swept.param_name, l.fields[ord / l.count].name);
}

test {
    _ = ngspice;
}

test "the variables a refusal lists are never empty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try listOr(arena.allocator(), &.{})).len != 0);
    try std.testing.expectEqualStrings("vd gd", try listOr(arena.allocator(), &.{ "vd", "gd" }));
}

test "a MOSFET quantity is a MOSFET's alone, and v and p are no MOSFET quantity" {
    try std.testing.expectEqual(Quantity.gm, mosfetQuantity(true, "gm").?);
    try std.testing.expect(mosfetQuantity(false, "gm") == null);
    try std.testing.expect(mosfetQuantity(true, "p") == null);
    try std.testing.expect(mosfetQuantity(true, "v") == null);
}
