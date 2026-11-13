//! ngspice's device operating-point names (`@d1[qd]`, `@r1[resistance]`,
//! #236) that an ESPice device type spells another way, or whose value
//! ESPice cannot read as ngspice defines it. In: a catalog type name and a
//! lowercased ngspice name. Out: the row saying what the name reads; none
//! when the device's own spelling (VerA `op_vars`, its parameters, the
//! MOSFET terminal quantities) is ngspice's.
//! Cites ngspice src/spicelib/devices: each `IFparm` table and `<dev>ask.c`,
//! line numbers on the rows.
//!
//! Contents:
//! - `pub const Target = union(enum)`
//! - `pub const Tran = union(enum)`
//! - `pub const Charging = struct`
//! - `pub const Pin = struct`
//! - `pub const Card = enum`
//! - `pub const Row = struct`
//! - `pub const rows: [_]Row`
//! - `pub fn find(device: []const u8, name: []const u8) ?Row`

const std = @import("std");
const Quantity = @import("core").OpVar.Quantity;

/// What an ngspice name reads on its device.
pub const Target = union(enum) {
    /// The device's own variable or its parameter of this name.
    name: []const u8,
    /// A terminal quantity, read from the instance's own evaluation.
    quantity: Quantity,
    /// Nothing ESPice reports: an ngspice instance quantity that a model
    /// parameter of the same name would otherwise answer with its value.
    none,
};

/// What ngspice's value is at a `.tran` point (`<dev>load.c`), against
/// one evaluation of the instance there, which carries no charging current.
/// `post/opvars.zig` replays the integrator over the run's rows for the
/// `charging` and `companion` ones.
pub const Tran = union(enum) {
    /// The same as at any other point.
    same,
    /// It adds the charging current: it is the terminal quantity `q`,
    /// charging current included, while each `pins` parameter has its
    /// value; another value charges a node pair that no terminal current
    /// shows alone, and a deck that runs a `.tran` refuses the name.
    charging: Charging,
    /// It adds the integrator's companion conductance: ag0 × the device's
    /// own variable of this name, its capacitance (NIintegrate's geq).
    companion: []const u8,
    /// It adds a charging current no terminal current shows alone, so a
    /// deck that runs a `.tran` refuses the name.
    refused,
};

/// `Tran.charging`: the terminal quantity and the parameters it needs.
pub const Charging = struct { q: Quantity, pins: []const Pin = &.{} };

/// A parameter and the value `Tran.charging` needs it at.
pub const Pin = struct { name: []const u8, value: f64 };

/// The card's instance factors a value lacks against ngspice's: the
/// frontend folds `m=` and `scale=` into R's and L's value (`r` and `l` are
/// the card's × scale / m, `net_passive.zig`), and C takes `m=` as its
/// `$mfactor`, which its op vars do not carry (`device.abi.LocalEval`).
pub const Card = enum {
    none,
    /// × the card's `m=`.
    times_m,
    /// × the card's `m=` / its `scale=`: the card's own value.
    times_m_per_scale,
};

/// ngspice's `name` on the device types `devices` (catalog names).
pub const Row = struct { devices: []const []const u8, name: []const u8, to: Target, tran: Tran = .same, card: Card = .none };

/// One row per ngspice name. A name ESPice spells as ngspice does needs a
/// row only when its `tran` is not `same` or its `card` not `none`.
pub const rows = [_]Row{
    // res.c:14-15 resistance and r, the card's value: restemp.c:67-80
    // keeps the temperature, m and scale out of it (resask.c:43; ngspice
    // 44.2 prints 1000 for `r1 a 0 1k m=2 tc1=1e-3` at .temp 77). :23 tc,
    // :33-34 i and p; resask.c:138-171 i = (v+ - v-) G, p = (v+ - v-)^2 G.
    .{ .devices = res, .name = "resistance", .to = .{ .name = "r" }, .card = .times_m_per_scale },
    .{ .devices = res, .name = "r", .to = .{ .name = "r" }, .card = .times_m_per_scale },
    .{ .devices = res, .name = "tc", .to = .{ .name = "tc1" } },
    .{ .devices = res, .name = "i", .to = .{ .quantity = .id } },
    .{ .devices = res, .name = "p", .to = .{ .quantity = .p } },
    // cap.c:13-15 capacitance, cap and c: the tempered value (captemp.c:91-94)
    // × m (capask.c:35-37); :28-29 i and p, capask.c:82-100: 0 at a DC
    // point, the charging current in a .tran.
    .{ .devices = cap, .name = "capacitance", .to = .{ .name = "capacitance" }, .card = .times_m },
    .{ .devices = cap, .name = "cap", .to = .{ .name = "capacitance" }, .card = .times_m },
    .{ .devices = cap, .name = "c", .to = .{ .name = "capacitance" }, .card = .times_m },
    .{ .devices = cap, .name = "i", .to = .{ .quantity = .id }, .tran = .{ .charging = .{ .q = .id } } },
    .{ .devices = cap, .name = "p", .to = .{ .quantity = .p }, .tran = .{ .charging = .{ .q = .p } } },
    // ind.c:13 inductance, the tempered value (indtemp.c:77-79) without m
    // (indask.c:33-35), which inductor.va's `inductance` divides by m as the
    // frontend folds it; :26-30 v, volt, i, current, p; indask.c:70-80: the
    // branch current, the terminal voltage, their product.
    .{ .devices = ind, .name = "inductance", .to = .{ .name = "inductance" }, .card = .times_m },
    .{ .devices = ind, .name = "v", .to = .{ .quantity = .v } },
    .{ .devices = ind, .name = "volt", .to = .{ .quantity = .v } },
    .{ .devices = ind, .name = "i", .to = .{ .quantity = .id } },
    .{ .devices = ind, .name = "current", .to = .{ .quantity = .id } },
    .{ .devices = ind, .name = "p", .to = .{ .quantity = .p } },
    // vsrc.c:46-47 i and p; vsrcask.c:146-158: the branch current,
    // (v+ - v-) i.
    .{ .devices = vsrc, .name = "i", .to = .{ .quantity = .id } },
    .{ .devices = vsrc, .name = "p", .to = .{ .quantity = .p } },
    // isrc.c:14 c (an alias of dc), :39 v (isrcask.c:79-82).
    .{ .devices = isrc, .name = "c", .to = .{ .name = "dc" } },
    .{ .devices = isrc, .name = "v", .to = .{ .quantity = .v } },
    // dio.c:31-32 id and c, the junction's current; in a .tran
    // dioload.c:703-707 adds its charging current, which KCL at the
    // junction's node makes the anode's (through RS, or the collapsed node
    // without it), and ag0 × capd to gd (:33); p (:39, dioask.c:105-118) is
    // id × the terminal voltage. ngspice 44.2 prints all three so in a
    // .tran (`src/tests/opvars.zig`). :37 qd, an alias of charge. diode_t's
    // p sums a and c alone (prepared_opvars.zig), not tj's T × heat flow.
    .{ .devices = dio, .name = "id", .to = .{ .quantity = .id }, .tran = .{ .charging = .{ .q = .id } } },
    .{ .devices = dio, .name = "c", .to = .{ .quantity = .id }, .tran = .{ .charging = .{ .q = .id } } },
    .{ .devices = dio, .name = "gd", .to = .{ .name = "gd" }, .tran = .{ .companion = "cd" } },
    .{ .devices = dio, .name = "qd", .to = .{ .name = "charge" } },
    .{ .devices = dio, .name = "p", .to = .{ .quantity = .p }, .tran = .{ .charging = .{ .q = .p } } },
    // bjt.c:37-39 ic, ib, ie: the intrinsic currents, which leave out the
    // substrate diode's (bjtask.c; ngspice 44.2 prints ie 8.2e-4 A with
    // the emitter's ammeter at 1e-12 A and the substrate forward biased).
    // In a .tran bjtload.c:808-818 adds the B-E and B-C charging currents,
    // which makes them the terminal currents while no charge sits from the
    // outer base (xcjc = 1) or on the substrate (cjs = 0, iss = 0): ngspice
    // 44.2 prints each ammeter's current then, and ib 12% off it at xcjc =
    // 0.5. :44-45 gpi and gmu add ag0 × capbe and capbc, bjt.c's cpi and cmu.
    .{ .devices = bjt, .name = "ic", .to = .{ .name = "ic" }, .tran = .{ .charging = .{ .q = .id, .pins = bjt_pins } } },
    .{ .devices = bjt, .name = "ib", .to = .{ .name = "ib" }, .tran = .{ .charging = .{ .q = .ig, .pins = bjt_pins } } },
    .{ .devices = bjt, .name = "ie", .to = .{ .name = "ie" }, .tran = .{ .charging = .{ .q = .is, .pins = bjt_pins } } },
    .{ .devices = bjt, .name = "gpi", .to = .{ .name = "gpi" }, .tran = .{ .companion = "cpi" } },
    .{ .devices = bjt, .name = "gmu", .to = .{ .name = "gmu" }, .tran = .{ .companion = "cmu" } },
    // bjt.c:56 csub, the substrate capacitance: gummel_poon.va's `capsub`,
    // as its aliasparam `csub` spells the model's CJS.
    .{ .devices = bjt, .name = "csub", .to = .{ .name = "capsub" } },
    // bjt.c:40 is (the substrate current, bjtask.c:243-260), :78-79 vaf,
    // var, :82-83 ikf, ikr (the instance's, scaled and at its
    // temperature): not the model's IS, VAF, VAR, IKF, IKR.
    .{ .devices = bjt, .name = "is", .to = .none },
    .{ .devices = bjt, .name = "vaf", .to = .none },
    .{ .devices = bjt, .name = "var", .to = .none },
    .{ .devices = bjt, .name = "ikf", .to = .none },
    .{ .devices = bjt, .name = "ikr", .to = .none },
    // vbic.c:41-43 ic, ib, ie: the currents into the terminals c, b, e
    // (vbicask.c:79-99, the state's branch currents, which vbicload.c:869-899
    // charges in a .tran; ngspice 44.2 prints each ammeter's current, in a
    // .tran too, until an extrinsic or overlap charge (cjep, cjcp, cbeo,
    // cbco), a B-E split (wbe < 1) or the excess-phase network (td) moves
    // one off a terminal: each of the first four alone puts ic or ib
    // 1e-4 to 6x off its ammeter). :44 is is the current out of the
    // substrate (vbicask.c:100-104, as ngspice 44.2 prints it), the sign of
    // no terminal quantity, and not the model's IS. :51-52 gpi and gmu add
    // ag0 × cbe and cbc in a .tran (vbicload.c:871, :882; ngspice 44.2).
    .{ .devices = vbic, .name = "ic", .to = .{ .quantity = .id }, .tran = .{ .charging = .{ .q = .id, .pins = vbic_pins } } },
    .{ .devices = vbic, .name = "ib", .to = .{ .quantity = .ig }, .tran = .{ .charging = .{ .q = .ig, .pins = vbic_pins } } },
    .{ .devices = vbic, .name = "ie", .to = .{ .quantity = .is }, .tran = .{ .charging = .{ .q = .is, .pins = vbic_pins } } },
    .{ .devices = vbic, .name = "is", .to = .none },
    .{ .devices = vbic, .name = "gpi", .to = .{ .name = "gpi" }, .tran = .{ .companion = "cbe" } },
    .{ .devices = vbic, .name = "gmu", .to = .{ .name = "gmu" }, .tran = .{ .companion = "cbc" } },
    // vdmos.c:26 is, -id less the gate's charging currents in a .tran
    // (vdmosask.c:147-160), not the source terminal's current, which the
    // body diode adds to; :27 ig, 0 but in a .tran (:131-146), where it is
    // the gate's charging current, the gate ammeter's in ngspice 44.2; :45
    // and :47 rs and rd, the instance's, not the model's RS and RD.
    .{ .devices = vdmos, .name = "is", .to = .none },
    .{ .devices = vdmos, .name = "ig", .to = .{ .quantity = .ig }, .tran = .{ .charging = .{ .q = .ig } } },
    // vdmos.c:33 idio: in a .tran vdmosload.c:980 adds the body diode's
    // charging current, as dioload.c does, which the drain shares with the
    // channel and the gate.
    .{ .devices = vdmos, .name = "idio", .to = .{ .name = "idio" }, .tran = .refused },
    .{ .devices = vdmos, .name = "rs", .to = .none },
    .{ .devices = vdmos, .name = "rd", .to = .none },
    // mos1.c:59-72 (mos2.c:59-70, mos3.c:53-65, mos9.c alike) gmb, an
    // alias of gmbs; and every level's rs, rd, cbd, cbs, the instance's,
    // not the model parameters.
    .{ .devices = &.{ "mos1", "mos2", "mos3", "mos9" }, .name = "gmb", .to = .{ .quantity = .gmbs } },
    .{ .devices = mos, .name = "rs", .to = .none },
    .{ .devices = mos, .name = "rd", .to = .none },
    .{ .devices = mos, .name = "cbd", .to = .none },
    .{ .devices = mos, .name = "cbs", .to = .none },
    // jfet.c:34, jfet2.c:36 is: the source current, not the model's IS.
    .{ .devices = jfet, .name = "is", .to = .none },
};

const res = &[_][]const u8{"resistor"};
const cap = &[_][]const u8{"capacitor"};
const ind = &[_][]const u8{"inductor"};
const vsrc = &[_][]const u8{"vsource"};
const isrc = &[_][]const u8{"isource"};
const dio = &[_][]const u8{ "diode", "diode_t" };
const bjt = &[_][]const u8{"gummel_poon"};
const vbic = &[_][]const u8{"vbic13_4t"};
const vdmos = &[_][]const u8{"vdmos"};
const mos = &[_][]const u8{ "mos1", "mos2", "mos3", "mos6", "mos9" };
const jfet = &[_][]const u8{ "jfet", "jfet2" };
const bjt_pins = &[_]Pin{ .{ .name = "xcjc", .value = 1 }, .{ .name = "cjs", .value = 0 }, .{ .name = "iss", .value = 0 } };
const vbic_pins = &[_]Pin{
    .{ .name = "cjep", .value = 0 }, .{ .name = "cjcp", .value = 0 }, .{ .name = "cbeo", .value = 0 },
    .{ .name = "cbco", .value = 0 }, .{ .name = "wbe", .value = 1 },  .{ .name = "td", .value = 0 },
};

/// The row for ngspice's `name` on catalog type `device`; null when the
/// device spells it as ngspice does. `name` is lowercase.
pub fn find(device: []const u8, name: []const u8) ?Row {
    for (rows) |r| {
        if (!std.mem.eql(u8, r.name, name)) continue;
        for (r.devices) |d| if (std.mem.eql(u8, d, device)) return r;
    }
    return null;
}

test "every row names a lowercase ngspice name once per device type" {
    for (rows, 0..) |a, i| {
        for (a.name) |c| try std.testing.expect(!std.ascii.isUpper(c));
        for (rows[i + 1 ..]) |b| if (std.mem.eql(u8, a.name, b.name)) for (a.devices) |d| {
            for (b.devices) |e| try std.testing.expect(!std.mem.eql(u8, d, e));
        };
    }
    try std.testing.expectEqualStrings("charge", find("diode", "qd").?.to.name);
    try std.testing.expectEqualStrings("cd", find("diode", "gd").?.tran.companion);
    try std.testing.expectEqual(Quantity.is, find("gummel_poon", "ie").?.tran.charging.q);
    // A quantity's own charging current is that quantity's.
    for (rows) |r| if (r.tran == .charging and r.to == .quantity) try std.testing.expectEqual(r.to.quantity, r.tran.charging.q);
    try std.testing.expect(find("diode", "vd") == null);
    try std.testing.expect(find("mos6", "gmb") == null);
    try std.testing.expectEqual(Card.times_m_per_scale, find("resistor", "r").?.card);
    try std.testing.expectEqual(Quantity.is, find("vbic13_4t", "ie").?.to.quantity);
}
