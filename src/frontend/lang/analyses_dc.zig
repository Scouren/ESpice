//! Rows and lowerings of the DC analyses beyond `.op` and `.dc`: `.tf
//! .sens .dcmatch .dcsens .dcxf .dcinc .mc`. In: a bound statement. Out:
//! its legacy card and SWEEP tail.
//! Cites: docs/using/language.md "DC"; docs/using/analyses.md `.tf`,
//! `.sens`, `.dcmatch`, `.dcsens`, `.dcxf`, `.mc`; src/frontend/Jobs/
//! analysis_small.zig (`tfJob`: `v(..)` or `i(Vx)` then a V or I source;
//! `sensJob`: `[dc | ac <grid>]`, the grid `frequencySweep`'s;
//! `acmatchJob`: keyword pairs; `xfOutput`: a trailing `tf`;
//! `dcincJob`), analysis_time.zig `mcJob`.
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
    .tf = Row{ .keys = &.{ out, src }, .sweeps = true, .lower = tf },
    .sens = Row{ .keys = &.{ out, .{ .key = "freq", .ty = .range } }, .sweeps = true, .lower = sens },
    .dcmatch = Row{ .keys = &.{out}, .sweeps = true, .lower = dcmatch },
    .dcsens = Row{ .keys = &dcsens_keys, .sweeps = true, .lower = dcsens },
    .dcxf = Row{ .keys = &.{ out, .{ .key = "tf", .ty = .flag } }, .sweeps = true, .lower = dcxf },
    .dcinc = Row{ .sweeps = true, .lower = dcinc },
    .mc = Row{ .keys = &.{ .{ .key = "trials", .ty = .integer, .need = .required }, .{ .key = "sigma", .ty = .real } }, .sweeps = true, .lower = mc },
};

const out: Slot = .{ .key = "out", .ty = .probe, .need = .required };
const src: Slot = .{ .key = "src", .ty = .reference, .need = .required };

const dcsens_keys = [_]Slot{
    out,
    .{ .key = "file", .ty = .string },
    .{ .key = "perturbation", .ty = .real },
    .{ .key = "interval", .ty = .integer },
    .{ .key = "threshold", .ty = .real },
    .{ .key = "groupbydevice", .ty = .word, .words = &.{ "yes", "no" } },
};

// ---- private ----

/// `.tf out=v(o) src=Vin` is `.tf v(o) Vin`.
fn tf(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none or b.keys[1] == ast.none) return;
    try l.put(".tf");
    try args.probe(l, b.keys[0], .vi);
    try args.name(l, b.keys[1]);
    try tail(l, b);
}

/// `.sens out=v(o) [freq=]` is `.sens v(o) [ac <grid>]`.
fn sens(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".sens");
    try args.probe(l, b.keys[0], .v);
    if (b.keys[1] != ast.none) {
        try l.put(" ac");
        try args.grid(l, b.keys[1], .no_list);
    }
    try tail(l, b);
}

/// `.dcmatch out=v(o)` is `.dcmatch v(o)`.
fn dcmatch(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".dcmatch");
    try args.probe(l, b.keys[0], .v);
    try tail(l, b);
}

/// `.dcsens out=v(o) file="f" ...` is `.dcsens v(o) file=f ...`.
fn dcsens(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".dcsens");
    try args.probe(l, b.keys[0], .v);
    try args.pairs(l, dcsens_keys[1..], b.keys[1..]);
    try tail(l, b);
}

/// `.dcxf out=v(o) [tf]` is `.dcxf v(o) [tf]`; the output may be `i(Vx)`.
fn dcxf(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".dcxf");
    try args.probe(l, b.keys[0], .vi);
    if (b.keys[1] != ast.none) try l.put(" tf");
    try tail(l, b);
}

fn dcinc(l: *Lowerer, b: Bound) Allocator.Error!void {
    try l.put(".dcinc");
    try tail(l, b);
}

/// `.mc trials=N [sigma=s]` is `.mc N [s]`.
fn mc(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none) return;
    try l.put(".mc");
    try args.num(l, b.keys[0]);
    if (b.keys[1] != ast.none) try args.num(l, b.keys[1]);
    try tail(l, b);
}
