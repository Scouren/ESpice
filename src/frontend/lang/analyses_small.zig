//! Rows and lowerings of the small-signal analyses beyond `.ac`: `.noise
//! .pz .disto .sp .lin .net .stb .lstb .acmatch .acxf`. In: a bound
//! statement. Out: its legacy card and SWEEP tail.
//! Cites: docs/using/language.md "Small signal"; docs/using/analyses.md
//! `.noise` ... `.lstb`; src/frontend/Jobs/analysis_small.zig
//! (`noiseJob`: `v(o) [src] <ac grid> [pts]`; `pzJob`: four nodes, `vol
//! |cur`, `pol|zer|pz`; `distoJob`, `stbJob`, `xfOutput`: `frequencySweep`
//! grids; `lstbJob`; `acmatchJob`), analysis_rf.zig (`spJob`: `<grid>
//! [1]`; `net`: `[out] src [r] [RIN=] [ROUT=]`, ROUT with an output only;
//! `lin`: `sparcalc noisecalc gdcalc` 0 or 1, `mixedmode2port` two of
//! `s d c`).
//!
//! Contents:
//! - `pub const rows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const args = @import("analysis_args.zig");
const tail = @import("sweeps.zig").tail;
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;

/// This area's rows of the directive table.
pub const rows = .{
    .noise = Row{ .keys = &noise_keys, .sweeps = true, .lower = noise },
    .pz = Row{ .keys = &pz_keys, .sweeps = true, .lower = pz },
    .disto = Row{ .keys = &.{ freq, .{ .key = "f2overf1", .ty = .real } }, .sweeps = true, .lower = disto },
    .sp = Row{ .keys = &.{ freq, .{ .key = "noise", .ty = .flag } }, .sweeps = true, .lower = sp },
    .lin = Row{ .keys = &lin_keys, .sweeps = true, .lower = lin },
    .net = Row{ .keys = &net_keys, .sweeps = true, .lower = net },
    .stb = Row{ .keys = &.{ .{ .key = "probe", .ty = .reference, .need = .required }, freq }, .sweeps = true, .lower = stb },
    .lstb = Row{ .keys = &lstb_keys, .sweeps = true, .lower = lstb },
    .acmatch = Row{ .keys = &acmatch_keys, .sweeps = true, .lower = acmatch },
    .acxf = Row{ .keys = &.{ out, freq, .{ .key = "tf", .ty = .flag } }, .sweeps = true, .lower = acxf },
};

const out: Slot = .{ .key = "out", .ty = .probe, .need = .required };
const freq: Slot = .{ .key = "freq", .ty = .range, .need = .required };

const noise_keys = [_]Slot{ out, .{ .key = "src", .ty = .reference }, freq, .{ .key = "contributions", .ty = .flag } };

const pz_keys = [_]Slot{
    .{ .key = "in", .ty = .probe },
    .{ .key = "out", .ty = .probe },
    .{ .key = "drive", .ty = .word, .words = &.{ "voltage", "current" } },
    .{ .key = "find", .ty = .word, .words = &.{ "poles", "zeros", "both" } },
};

const lin_keys = [_]Slot{
    .{ .key = "sparcalc", .ty = .flag },
    .{ .key = "noisecalc", .ty = .flag },
    .{ .key = "gdcalc", .ty = .flag },
    .{ .key = "format", .ty = .word, .words = &.{ "touchstone", "touchstone2", "citi", "selem" } },
    .{ .key = "filename", .ty = .string },
    .{ .key = "mixedmode2port", .ty = .word, .words = &.{ "ss", "sd", "sc", "ds", "dd", "dc", "cs", "cd", "cc" } },
};

const net_keys = [_]Slot{
    .{ .key = "out", .ty = .probe },
    .{ .key = "src", .ty = .reference, .need = .required },
    .{ .key = "rin", .ty = .quantity, .q = .resistance },
    .{ .key = "rout", .ty = .quantity, .q = .resistance },
};

const lstb_keys = [_]Slot{
    .{ .key = "mode", .ty = .word, .words = &.{ "single", "diff", "comm" }, .need = .required },
    .{ .key = "vsource", .ty = .any, .need = .required },
    .{ .key = "localgnd", .ty = .node },
    .{ .key = "freq", .ty = .range },
};

const acmatch_keys = [_]Slot{
    out,
    .{ .key = "threshold", .ty = .real },
    .{ .key = "file", .ty = .string },
    .{ .key = "interval", .ty = .integer },
    .{ .key = "virtual_sensitivity", .ty = .word, .words = &.{ "yes", "no" } },
    .{ .key = "sens_threshold", .ty = .real },
};

// ---- private ----

/// `.noise out=v(o) [src=V] freq= [contributions]` is `.noise v(o) [V]
/// <grid> [1]`.
fn noise(l: *Lowerer, b: Bound) Allocator.Error!void {
    const o, const s, const f, const contributions = b.keys[0..4].*;
    if (o == ast.none or f == ast.none) return;
    try l.put(".noise");
    try args.probe(l, o, .v);
    if (s != ast.none) try args.name(l, s);
    try args.grid(l, f, .with_list);
    if (contributions != ast.none) try l.put(" 1");
    try tail(l, b);
}

/// `.pz in=v(a,b) out=v(c,d) drive=voltage find=both` is `.pz a b c d vol
/// pz`; bare `.pz` finds the natural poles. The four keys come together.
fn pz(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const given = for (b.keys) |k| {
        if (k != ast.none) break true;
    } else false;
    if (given) for (pz_keys, b.keys) |s, k| if (k == ast.none) try l.diags.add(.missing_key, a.at(b.stmt), s.key);
    try l.put(".pz");
    if (given and std.mem.indexOfScalar(ast.Index, b.keys, ast.none) == null) {
        try args.nodes(l, b.keys[0]);
        try args.nodes(l, b.keys[1]);
        const drive = std.StaticStringMap([]const u8).initComptime(.{ .{ "voltage", "vol" }, .{ "current", "cur" } });
        const find = std.StaticStringMap([]const u8).initComptime(.{ .{ "poles", "pol" }, .{ "zeros", "zer" }, .{ "both", "pz" } });
        try l.print(" {s} {s}", .{ drive.get(a.text(b.keys[2])) orelse "?", find.get(a.text(b.keys[3])) orelse "?" });
    }
    try tail(l, b);
}

/// `.disto freq= [f2overf1=]` is `.disto <grid> [ratio]`.
fn disto(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".disto");
    try args.grid(l, b.keys[0], .no_list);
    if (b.keys[1] != ast.none) try args.num(l, b.keys[1]);
    try tail(l, b);
}

/// `.sp freq= [noise]` is `.sp <grid> [1]`.
fn sp(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".sp");
    try args.grid(l, b.keys[0], .no_list);
    if (b.keys[1] != ast.none) try l.put(" 1");
    try tail(l, b);
}

/// `.lin [sparcalc] ... [format=touchstone]` is `.lin sparcalc=1 ...
/// format=touchstone`.
fn lin(l: *Lowerer, b: Bound) Allocator.Error!void {
    try l.put(".lin");
    try args.pairs(l, &lin_keys, b.keys);
    try tail(l, b);
}

/// `.net [out=] src= [rin=] [rout=]` is `.net [out] src [rin=r] [rout=r]`;
/// the legacy card takes ROUT only with an output.
fn net(l: *Lowerer, b: Bound) Allocator.Error!void {
    const o, const s = b.keys[0..2].*;
    if (s == ast.none) return;
    if (o == ast.none and b.keys[3] != ast.none) return l.diags.add(.no_legacy, l.a.at(b.keys[3]), "rout= without out=");
    try l.put(".net");
    if (o != ast.none) try args.probe(l, o, .vi);
    try args.name(l, s);
    try args.pairs(l, net_keys[2..], b.keys[2..]);
    try tail(l, b);
}

/// `.stb probe=Vp freq=` is `.stb Vp <grid>`.
fn stb(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none or b.keys[1] == ast.none) return;
    try l.put(".stb");
    try args.name(l, b.keys[0]);
    try args.grid(l, b.keys[1], .no_list);
    try tail(l, b);
}

/// `.lstb mode=diff vsource=[Vp, Vn] [localgnd=n] [freq=]` is `.lstb
/// mode=diff vsource=Vp,Vn [localgnd=n] [<grid>]`: one source for
/// `single`, two for `diff` and `comm`.
fn lstb(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const mode, const vs, const gnd, const f = b.keys[0..4].*;
    if (mode == ast.none or vs == ast.none) return;
    const one = [1]ast.Index{vs};
    const sources: []const ast.Index = if (a.tag(vs) == .list) a.children(vs) else &one;
    const want: usize = if (std.mem.eql(u8, a.text(mode), "single")) 1 else 2;
    if (sources.len != want) return l.diags.add(.arity, a.at(vs), if (want == 1) "one vsource for mode=single" else "vsource=[Vp, Vn] for mode=diff or comm");
    try l.print(".lstb mode={s} vsource=", .{a.text(mode)});
    for (sources, 0..) |v, i| {
        if (a.tag(v) != .word and a.tag(v) != .string) try l.diags.add(.wrong_kind, a.at(v), a.text(v));
        if (i > 0) try l.put(",");
        try l.putName(v);
    }
    if (gnd != ast.none) try args.pairs(l, lstb_keys[2..3], &.{gnd});
    if (f != ast.none) try args.grid(l, f, .no_list);
    try tail(l, b);
}

/// `.acmatch out=v(o) threshold= ...` is `.acmatch v(o) threshold= ...`.
fn acmatch(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".acmatch");
    try args.probe(l, b.keys[0], .v);
    try args.pairs(l, acmatch_keys[1..], b.keys[1..]);
    try tail(l, b);
}

/// `.acxf out= freq= [tf]` is `.acxf v(o) <grid> [tf]`; the output may be `i(Vx)`.
fn acxf(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none or b.keys[1] == ast.none) return;
    try l.put(".acxf");
    try args.probe(l, b.keys[0], .vi);
    try args.grid(l, b.keys[1], .no_list);
    if (b.keys[2] != ast.none) try l.put(" tf");
    try tail(l, b);
}
