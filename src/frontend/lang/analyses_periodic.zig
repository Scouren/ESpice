//! Rows and lowerings of the periodic and harmonic-balance analyses:
//! `.pss .pac .pxf .pnoise .ptdnoise .qpss .hb .hbac .hbxf .hbnoise .hblin
//! .phasenoise`. In: a bound statement. Out: its legacy card and SWEEP
//! tail. Where the legacy card is positional, a later value given with an
//! earlier one left out writes the earlier one's default only where
//! docs/using/analyses.md states it (`.pss` points 256, `.qpss` harmonics
//! 5); otherwise it is `no_filler`.
//! Cites: docs/using/language.md "Periodic steady state", "Harmonic
//! balance"; docs/using/analyses.md `.pss` ... `.qpss`; src/frontend/Jobs/
//! analysis_rf.zig (`pssJob` and `ngspiceOscillator`; `pacJob`,
//! `pnoiseJob`: `acGrid` grids; `hbJob`, `hbTones`; `qpssJob`; `hbacJob`:
//! `frequencySweep` grids, `[f0 [K [M]]]`, K the harmonics and M the
//! sidebands; `hblinJob`; `phasenoiseJob`: METHOD 0, 1, 2 the
//! `PhaseNoise.Algorithm` nlp, pac, bpn), analysis_time.zig `ptdNoise`
//! and `ptdTimes` (TIME one time or a lin/dec/oct/poi grid).
//!
//! Contents:
//! - `pub const rows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const check = @import("check.zig");
const args = @import("analysis_args.zig");
const analyses = @import("analyses.zig");
const tail = @import("sweeps.zig").tail;
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;
const Index = ast.Index;
const none = ast.none;

/// This area's rows of the directive table.
pub const rows = .{
    .pss = Row{ .keys = &pss_keys, .sweeps = true, .lower = pss },
    .pac = Row{ .keys = &.{ f0_req, freq }, .sweeps = true, .lower = pac },
    .pxf = Row{ .keys = &.{ .{ .key = "out", .ty = .probe }, f0_req, freq }, .sweeps = true, .lower = pxf },
    .pnoise = Row{ .keys = &.{ out, src_req, freq, f0_req, .{ .key = "sidebands", .ty = .integer } }, .sweeps = true, .lower = pnoise },
    .ptdnoise = Row{ .keys = &.{ out, .{ .key = "time", .ty = .any, .need = .required }, .{ .key = "tdelta", .ty = .quantity, .q = .time }, freq }, .sweeps = true, .lower = ptdnoise },
    .qpss = Row{ .keys = &qpss_keys, .sweeps = true, .lower = qpss },
    .hb = Row{ .keys = &hb_keys, .sweeps = true, .lower = hb },
    .hbac = Row{ .keys = &.{ freq, f0, harmonics }, .sweeps = true, .lower = hbLptv },
    .hbxf = Row{ .keys = &.{ out, freq, f0, harmonics }, .sweeps = true, .lower = hbLptv },
    .hbnoise = Row{ .keys = &.{ out, .{ .key = "src", .ty = .reference }, freq, f0, harmonics, .{ .key = "sidebands", .ty = .integer } }, .sweeps = true, .lower = hbLptv },
    .hblin = Row{ .keys = &hblin_keys, .sweeps = true, .lower = hblin },
    .phasenoise = Row{ .keys = &phasenoise_keys, .sweeps = true, .lower = phasenoise },
};

const out: Slot = .{ .key = "out", .ty = .probe, .need = .required };
const src_req: Slot = .{ .key = "src", .ty = .reference, .need = .required };
const freq: Slot = .{ .key = "freq", .ty = .range, .need = .required };
const f0: Slot = .{ .key = "f0", .ty = .quantity, .q = .frequency };
const f0_req: Slot = .{ .key = "f0", .ty = .quantity, .q = .frequency, .need = .required };
const harmonics: Slot = .{ .key = "harmonics", .ty = .integer };
const osc: Slot = .{ .key = "osc", .ty = .probe };

const pss_keys = [_]Slot{
    f0_req,
    .{ .key = "points", .ty = .integer },
    osc,
    .{ .key = "settle", .ty = .integer },
    // ngspice's oscillator form, which `tstab` selects.
    .{ .key = "tstab", .ty = .quantity, .q = .time },
    harmonics,
    .{ .key = "sciter", .ty = .integer },
    .{ .key = "steadycoeff", .ty = .real },
    .{ .key = "uic", .ty = .flag },
};

const qpss_keys = [_]Slot{
    .{ .key = "f1", .ty = .quantity, .q = .frequency, .need = .required },
    .{ .key = "f2", .ty = .quantity, .q = .frequency, .need = .required },
    .{ .key = "nharms", .ty = .list, .elem = .integer },
};

const hb_keys = [_]Slot{
    f0,
    harmonics,
    osc,
    // The multitone form, which `tones` selects.
    .{ .key = "tones", .ty = .list, .elem = .quantity, .q = .frequency },
    .{ .key = "nharms", .ty = .list, .elem = .integer },
    .{ .key = "intmodmax", .ty = .integer },
    .{ .key = "subharms", .ty = .integer },
    .{ .key = "ss_tone", .ty = .integer },
};

const hblin_keys = [_]Slot{
    freq,
    .{ .key = "noisecalc", .ty = .flag },
    .{ .key = "filename", .ty = .string },
    .{ .key = "dataformat", .ty = .word, .words = &.{ "ri", "ma", "db" } },
};

const phasenoise_keys = [_]Slot{
    out,
    freq,
    f0,
    harmonics,
    .{ .key = "method", .ty = .word, .words = &.{ "nlp", "pac", "bpn" } },
    .{ .key = "carrierindex", .ty = .integer },
};

// ---- private ----

/// `.pss f0= [points=]` is `.pss f0 [points]`; with `osc=v(n)`, `.pss v(n)
/// f0 [points [settle]]`; with `tstab=`, ngspice's `.pss f0 tstab n points
/// harmonics sciter steadycoeff [uic]`, every key of which is required.
fn pss(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const freq0, const points, const o, const settle, const tstab = b.keys[0..5].*;
    if (freq0 == none) return;
    if (tstab != none) {
        for (pss_keys[1..8], b.keys[1..8]) |s, k| if (k == none and !std.mem.eql(u8, s.key, "settle")) try l.diags.add(.missing_key, a.at(b.stmt), s.key);
        if (settle != none) return l.diags.add(.no_legacy, a.at(settle), "settle= with tstab=: ngspice's form settles for tstab");
        const rest = [_]Index{ points, b.keys[5], b.keys[6], b.keys[7] };
        if (o == none or std.mem.indexOfScalar(Index, &rest, none) != null) return;
        if (a.tag(o) != .call or a.children(o).len != 1 or !std.mem.eql(u8, a.callee(o), "v")) return l.diags.add(.wrong_kind, a.at(o), a.text(o));
        try l.put(".pss");
        try args.num(l, freq0);
        try args.num(l, tstab);
        try args.name(l, a.children(o)[0]);
        for (rest) |k| try args.num(l, k);
        if (b.keys[8] != none) try l.put(" uic");
        return tail(l, b);
    }
    for (b.keys[5..9]) |k| if (k != none) try l.diags.add(.no_legacy, a.at(k), "a key of ngspice's .pss form without tstab=");
    if (settle != none and o == none) return l.diags.add(.no_legacy, a.at(settle), "settle= without osc=");
    try l.put(".pss");
    if (o != none) try args.probe(l, o, .single);
    try args.num(l, freq0);
    // analyses.md `.pss`: "default 256 points".
    if (points != none) try args.num(l, points) else if (settle != none) try l.put(" 256");
    if (settle != none) try args.num(l, settle);
    try tail(l, b);
}

/// `.pac f0= freq=` is `.pac f0 <grid>`.
fn pac(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == none or b.keys[1] == none) return;
    try l.put(".pac");
    try args.num(l, b.keys[0]);
    try args.grid(l, b.keys[1], .with_list);
    try tail(l, b);
}

/// `.pxf [out=] f0= freq=` is `.pxf [v(o)] f0 <grid>`.
fn pxf(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[1] == none or b.keys[2] == none) return;
    try l.put(".pxf");
    if (b.keys[0] != none) try args.probe(l, b.keys[0], .single);
    try args.num(l, b.keys[1]);
    try args.grid(l, b.keys[2], .with_list);
    try tail(l, b);
}

/// `.pnoise out= src= freq= f0= [sidebands=]` is `.pnoise v(o) src <grid>
/// f0 [sidebands]`.
fn pnoise(l: *Lowerer, b: Bound) Allocator.Error!void {
    const o, const s, const f, const fund, const sidebands = b.keys[0..5].*;
    if (o == none or s == none or f == none or fund == none) return;
    try l.put(".pnoise");
    try args.probe(l, o, .v);
    try args.name(l, s);
    try args.grid(l, f, .with_list);
    try args.num(l, fund);
    if (sidebands != none) try args.num(l, sidebands);
    try tail(l, b);
}

/// `.ptdnoise out= time= [tdelta=] freq=` is `.ptdnoise v(o) time=t
/// [tdelta=d] <grid>`; `time` is one time or a range, written as a grid.
fn ptdnoise(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const o, const time, const tdelta, const f = b.keys[0..4].*;
    if (o == none or time == none or f == none) return;
    try l.put(".ptdnoise");
    try args.probe(l, o, .v);
    try l.put(" time=");
    const grids = std.StaticStringMap(void).initComptime(.{ .{"lin"}, .{"dec"}, .{"oct"} });
    if (a.tag(time) == .list or (a.tag(time) == .call and grids.has(a.callee(time)))) {
        // ` time= lin 5 0 1n`: the reader skips the lone `=`.
        try analyses.range(l, time, .frequency);
    } else {
        try check.value(l, .{ .key = "time", .ty = .quantity, .q = .time }, time);
        try args.bare(l, time);
    }
    if (tdelta != none) try args.pairs(l, &.{.{ .key = "tdelta", .ty = .quantity }}, &.{tdelta});
    try args.grid(l, f, .with_list);
    try tail(l, b);
}

/// `.qpss f1= f2= [nharms=[k1, k2]]` is `.qpss f1 f2 [k1 [k2]]`.
fn qpss(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const f1, const f2, const nharms = b.keys[0..3].*;
    if (f1 == none or f2 == none) return;
    try l.put(".qpss");
    try args.num(l, f1);
    try args.num(l, f2);
    if (nharms != none and a.tag(nharms) == .list) {
        const ks = a.children(nharms);
        if (ks.len == 0 or ks.len > 2) return l.diags.add(.arity, a.at(nharms), "nharms=[k1, k2]");
        for (ks) |k| try args.num(l, k);
    }
    try tail(l, b);
}

/// `.hb f0= [harmonics=] [osc=v(n)]` is `.hb [v(n)] f0 [harmonics]`;
/// `.hb tones=[f1, f2] nharms=[n1, n2] ...` is `.hb tones=f1 f2 nharms=n1
/// n2 ...`, which needs `nharms` or `intmodmax`.
fn hb(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const freq0, const h, const o, const tones, const nharms, const intmodmax = b.keys[0..6].*;
    try l.put(".hb");
    if (tones == none) {
        for (b.keys[4..]) |k| if (k != none) try l.diags.add(.no_legacy, a.at(k), "a multitone .hb key without tones=");
        if (freq0 == none) return l.diags.add(.missing_key, a.at(b.stmt), "f0");
        if (o != none) try args.probe(l, o, .single);
        try args.num(l, freq0);
        if (h != none) try args.num(l, h);
        return tail(l, b);
    }
    for (b.keys[0..3]) |k| if (k != none) try l.diags.add(.no_legacy, a.at(k), "f0=, harmonics= or osc= with tones=");
    if (nharms == none and intmodmax == none) return l.diags.add(.missing_key, a.at(b.stmt), "nharms");
    for ([_]Index{ tones, nharms }, [_][]const u8{ "tones", "nharms" }) |list, key| {
        if (list == none or a.tag(list) != .list) continue;
        if (a.children(list).len == 0) try l.diags.add(.arity, a.at(list), key);
        try l.print(" {s}=", .{key});
        for (a.children(list), 0..) |v, i| {
            if (i > 0) try l.put(" ");
            try args.bare(l, v);
        }
    }
    try args.pairs(l, hb_keys[5..], b.keys[5..]);
    try tail(l, b);
}

/// `.hbac freq= [f0= [harmonics=]]` is `.hbac <grid> [f0 [K]]`; `.hbxf
/// out=` and `.hbnoise out= [src=] ... [sidebands=]` lead with `v(o)
/// [src]` and `.hbnoise` ends `[f0 [K [M]]]`.
fn hbLptv(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const word = a.text(b.stmt);
    const hbac = std.mem.eql(u8, word, ".hbac");
    const noisy = std.mem.eql(u8, word, ".hbnoise");
    const k = b.keys;
    // Keys after the output (and `.hbnoise`'s source): freq, f0, harmonics[, sidebands].
    const at: usize = if (hbac) 0 else if (noisy) 2 else 1;
    const tones = k[at..];
    if (tones[0] == none or (!hbac and k[0] == none)) return;
    for (tones[2..], 1..) |x, i| if (x != none and tones[i] == none) return l.diags.add(.no_filler, a.at(x), if (i == 1) "harmonics= without f0=" else "sidebands= without harmonics=");
    try l.put(word);
    if (!hbac) try args.probe(l, k[0], if (noisy) .v else .single);
    if (noisy and k[1] != none) try args.name(l, k[1]);
    try args.grid(l, tones[0], .no_list);
    for (tones[1..]) |x| if (x != none) try args.num(l, x);
    try tail(l, b);
}

/// `.hblin freq= [noisecalc] [filename=] [dataformat=]` is `.hblin <grid>
/// noisecalc=1 filename=f dataformat=ri`.
fn hblin(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == none) return;
    try l.put(".hblin");
    try args.grid(l, b.keys[0], .with_list);
    try args.pairs(l, hblin_keys[1..], b.keys[1..]);
    try tail(l, b);
}

/// `.phasenoise out= freq= [f0= [harmonics=]] [method=] [carrierindex=]`
/// is `.phasenoise v(o) <grid> [f0 [K]] [method=0|1|2] [carrierindex=k]`.
fn phasenoise(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const o, const f, const freq0, const h, const method, const carrier = b.keys[0..6].*;
    if (o == none or f == none) return;
    if (h != none and freq0 == none) return l.diags.add(.no_filler, a.at(h), "harmonics= without f0=");
    try l.put(".phasenoise");
    try args.probe(l, o, .single);
    try args.grid(l, f, .no_list);
    if (freq0 != none) try args.num(l, freq0);
    if (h != none) try args.num(l, h);
    if (method != none) {
        const methods = std.StaticStringMap(u8).initComptime(.{ .{ "nlp", '0' }, .{ "pac", '1' }, .{ "bpn", '2' } });
        try l.print(" method={c}", .{methods.get(a.text(method)) orelse '?'});
    }
    if (carrier != none) try args.pairs(l, phasenoise_keys[5..], &.{carrier});
    try tail(l, b);
}
