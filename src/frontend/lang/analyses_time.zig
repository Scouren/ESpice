//! Rows and lowerings of the transient analyses beyond `.tran`: `.four
//! .fft .trannoise .envelope .matex`. In: a bound statement. Out: its
//! legacy card and SWEEP tail.
//! Cites: docs/using/language.md "Transient"; docs/using/analyses.md
//! `.four` ... `.matex`; src/frontend/Jobs/analysis_time.zig (`fourJob`:
//! `f0 v(..)... [nharm]`; `fft`: keyword pairs; `tranJob`: `tstep tstop`
//! for `.trannoise` and `.matex`; `hspiceTranNoise`: `v(o)` then keyword
//! pairs, TIME a time or `all`; `envelopeJob`).
//!
//! Contents:
//! - `pub const rows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const check = @import("check.zig");
const args = @import("analysis_args.zig");
const tail = @import("sweeps.zig").tail;
const Lowerer = @import("lower.zig").Lowerer;
const Row = schema.Row;
const Slot = schema.Slot;
const Bound = schema.Bound;

/// This area's rows of the directive table.
pub const rows = .{
    .four = Row{
        .subjects = &.{.{ .key = "out", .ty = .probe, .need = .required }},
        .variadic = true,
        .keys = &.{ .{ .key = "f0", .ty = .quantity, .q = .frequency, .need = .required }, .{ .key = "nharm", .ty = .integer } },
        .sweeps = true,
        .lower = four,
    },
    .fft = Row{ .subjects = &.{.{ .key = "out", .ty = .probe, .need = .required }}, .keys = &fft_keys, .sweeps = true, .lower = fft },
    .trannoise = Row{ .keys = &trannoise_keys, .sweeps = true, .lower = trannoise },
    .envelope = Row{ .keys = &.{ .{ .key = "period", .ty = .quantity, .q = .time, .need = .required }, stop }, .sweeps = true, .lower = envelope },
    .matex = Row{ .keys = &.{ stop, step }, .sweeps = true, .lower = matex },
};

const stop: Slot = .{ .key = "stop", .ty = .quantity, .q = .time, .need = .required };
const step: Slot = .{ .key = "step", .ty = .quantity, .q = .time, .need = .required };

const fft_keys = [_]Slot{
    .{ .key = "start", .ty = .quantity, .q = .time },
    .{ .key = "stop", .ty = .quantity, .q = .time },
    .{ .key = "np", .ty = .integer },
    .{ .key = "format", .ty = .word, .words = &.{ "norm", "unorm" } },
    .{ .key = "window", .ty = .word, .words = &.{ "rect", "bart", "hann", "hamm", "black", "harris", "gauss", "kaiser" } },
    .{ .key = "alfa", .ty = .real },
    .{ .key = "freq", .ty = .quantity, .q = .frequency },
    .{ .key = "fmin", .ty = .quantity, .q = .frequency },
    .{ .key = "fmax", .ty = .quantity, .q = .frequency },
};

/// `stop step`, the ngspice form; the rest, the HSPICE form.
const trannoise_keys = [_]Slot{
    .{ .key = "stop", .ty = .quantity, .q = .time },
    .{ .key = "step", .ty = .quantity, .q = .time },
    .{ .key = "out", .ty = .probe },
    .{ .key = "method", .ty = .word, .words = &.{ "mc", "sde" } },
    .{ .key = "seed", .ty = .integer },
    .{ .key = "samples", .ty = .integer },
    .{ .key = "fmin", .ty = .quantity, .q = .frequency },
    .{ .key = "fmax", .ty = .quantity, .q = .frequency },
    .{ .key = "scale", .ty = .real },
    .{ .key = "time", .ty = .any },
};

// ---- private ----

/// `.four v(a) v(b) f0= [nharm=]` is `.four f0 v(a) v(b) [nharm]`.
fn four(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none or b.subjects.len == 0) return;
    try l.put(".four");
    try args.num(l, b.keys[0]);
    for (b.subjects) |o| try args.probe(l, o, .v);
    if (b.keys[1] != ast.none) try args.num(l, b.keys[1]);
    try tail(l, b);
}

/// `.fft v(o) np=1024 window=hann` is `.fft v(o) np=1024 window=hann`.
fn fft(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.subjects.len != 1) return;
    try l.put(".fft");
    try args.probe(l, b.subjects[0], .v);
    try args.pairs(l, &fft_keys, b.keys);
    try tail(l, b);
}

/// `.trannoise stop= step=` is `.trannoise tstep tstop`; `.trannoise
/// out=v(o) [method= ...]` is `.trannoise v(o) method= ...`, on the deck's
/// `.tran`. `time` is a time or `all`.
fn trannoise(l: *Lowerer, b: Bound) Allocator.Error!void {
    const a = l.a;
    const t_stop, const t_step, const o = b.keys[0..3].*;
    try l.put(".trannoise");
    if (o == ast.none) {
        for ([_]ast.Index{ t_stop, t_step }, [_][]const u8{ "stop", "step" }) |k, key| if (k == ast.none) try l.diags.add(.missing_key, a.at(b.stmt), key);
        for (b.keys[3..]) |k| if (k != ast.none) try l.diags.add(.no_legacy, a.at(k), "an HSPICE .trannoise key without out=");
        if (t_stop == ast.none or t_step == ast.none) return;
        try args.num(l, t_step);
        try args.num(l, t_stop);
        return tail(l, b);
    }
    for ([_]ast.Index{ t_stop, t_step }) |k| if (k != ast.none) try l.diags.add(.no_legacy, a.at(k), "stop= or step= with out=: the out= form runs on the deck's .tran");
    const time = b.keys[9];
    if (time != ast.none and !(a.tag(time) == .word and std.mem.eql(u8, a.text(time), "all")))
        try check.value(l, .{ .key = "time", .ty = .quantity, .q = .time }, time);
    try args.probe(l, o, .v);
    try args.pairs(l, trannoise_keys[3..9], b.keys[3..9]);
    if (time != ast.none) {
        try l.put(" time=");
        if (a.tag(time) == .word and std.mem.eql(u8, a.text(time), "all")) try l.put("all") else try args.bare(l, time);
    }
    try tail(l, b);
}

/// `.envelope period= stop=` is `.envelope tcarrier tstop`.
fn envelope(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none or b.keys[1] == ast.none) return;
    try l.put(".envelope");
    try args.num(l, b.keys[0]);
    try args.num(l, b.keys[1]);
    try tail(l, b);
}

/// `.matex stop= step=` is `.matex tstep tstop`.
fn matex(l: *Lowerer, b: Bound) Allocator.Error!void {
    if (b.keys[0] == ast.none or b.keys[1] == ast.none) return;
    try l.put(".matex");
    try args.num(l, b.keys[1]);
    try args.num(l, b.keys[0]);
    try tail(l, b);
}
