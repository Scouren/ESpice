//! Writers the analysis lowerings share: a number, a name, a probe, a
//! frequency grid and keyed settings, each as a legacy analysis card
//! reads it. In: bound nodes. Out: ` value` text, or a coded row for a
//! value the card cannot take.
//! Cites: src/frontend/Netlist/reader_directives.zig `readArgs` (an
//! analysis card's fields are read with `subst_names` off: a bare
//! parameter name stays a name, so a computed value is quoted);
//! src/frontend/Jobs/analysis_args.zig (`frequencySweep` reads no `poi`
//! grid, `acGrid` reads one); reader_frame.zig `groupNode` (an output is
//! `v(a[,b])`).
//!
//! Contents:
//! - `pub const Grid`
//! - `pub const Probe`
//! - `pub fn num(l: *Lowerer, v: Index) Allocator.Error!void`
//! - `pub fn name(l: *Lowerer, v: Index) Allocator.Error!void`
//! - `pub fn probe(l: *Lowerer, v: Index, kind: Probe) Allocator.Error!void`
//! - `pub fn nodes(l: *Lowerer, v: Index) Allocator.Error!void`
//! - `pub fn grid(l: *Lowerer, v: Index, g: Grid) Allocator.Error!void`
//! - `pub fn pairs(l: *Lowerer, slots: []const Slot, keys: []const Index) Allocator.Error!void`
//! - `pub fn bare(l: *Lowerer, v: Index) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const expr = @import("expr.zig");
const analyses = @import("analyses.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Slot = schema.Slot;
const Index = ast.Index;

/// Whether a card reads its grid as `.ac` does, `poi` included
/// (`acGrid`), or only `dec|oct|lin N f1 f2` (`frequencySweep`).
pub const Grid = enum(u1) { with_list, no_list };

/// The probes an output slot takes: `v(a[,b])`, also `i(Vx)`, or a
/// single-ended `v(a)`.
pub const Probe = enum(u2) { v, vi, single };

/// Writes ` value`: a literal bare, anything else (a parameter's name
/// included) as numparam's `'...'`, which the card folds.
pub fn num(l: *Lowerer, v: Index) Allocator.Error!void {
    try l.put(" ");
    try bare(l, v);
}

/// Writes ` name` as written, a quoted name's body bare.
pub fn name(l: *Lowerer, v: Index) Allocator.Error!void {
    try l.put(" ");
    try l.putName(v);
}

/// Writes ` v(a)`, ` v(a,b)` or ` i(x)`; a probe `kind` does not take is
/// `wrong_kind`.
pub fn probe(l: *Lowerer, v: Index, kind: Probe) Allocator.Error!void {
    const a = l.a;
    if (a.tag(v) != .call) return l.diags.add(.wrong_kind, a.at(v), a.text(v));
    const f = a.callee(v);
    const n = a.children(v).len;
    const ok = switch (kind) {
        .v => std.mem.eql(u8, f, "v") and (n == 1 or n == 2),
        .vi => (std.mem.eql(u8, f, "v") and (n == 1 or n == 2)) or (std.mem.eql(u8, f, "i") and n == 1),
        .single => std.mem.eql(u8, f, "v") and n == 1,
    };
    if (!ok) return l.diags.add(.wrong_kind, a.at(v), a.text(v));
    try l.put(" ");
    try l.putProbe(v);
}

/// Writes the two nodes of `v(a,b)` as ` a b`, of `v(a)` as ` a 0`.
pub fn nodes(l: *Lowerer, v: Index) Allocator.Error!void {
    const a = l.a;
    const n = if (a.tag(v) == .call) a.children(v).len else 0;
    if (n == 0 or n > 2 or !std.mem.eql(u8, a.callee(v), "v")) return l.diags.add(.wrong_kind, a.at(v), a.text(v));
    for (a.children(v)) |c| try name(l, c);
    if (n == 1) try l.put(" 0");
}

/// Writes ` <grid>` for the frequency range `v`; a list where the card
/// reads no `poi` grid is `no_legacy`.
pub fn grid(l: *Lowerer, v: Index, g: Grid) Allocator.Error!void {
    if (g == .no_list and l.a.tag(v) == .list) return l.diags.add(.no_legacy, l.a.at(v), "a frequency list on a card that reads only dec, oct or lin");
    try analyses.range(l, v, .frequency);
}

/// Writes ` key=value` for each given slot, in slot order: a flag as
/// `key=1`, a word as written, a string's body bare (one that would not
/// read as one field is `wrong_kind`), a name as written, anything else
/// as `num` writes it.
pub fn pairs(l: *Lowerer, slots: []const Slot, keys: []const Index) Allocator.Error!void {
    assert(slots.len == keys.len);
    const a = l.a;
    for (slots, keys) |s, v| {
        if (v == ast.none) continue;
        try l.print(" {s}=", .{s.key});
        switch (s.ty) {
            .flag => try l.put("1"),
            .word => try l.put(a.text(v)),
            .reference, .node => try l.putName(v),
            .string => {
                const body = a.name(v);
                if (body.len == 0 or std.mem.indexOfAny(u8, body, " \t(),='\"{}") != null) try l.diags.add(.wrong_kind, a.at(v), a.text(v));
                try l.put(body);
            },
            else => try bare(l, v),
        }
    }
}

/// `num` without its leading blank: the value after a `key=`.
pub fn bare(l: *Lowerer, v: Index) Allocator.Error!void {
    if (expr.isLiteral(l.a, v)) return expr.write(l, v, .param);
    try l.put("'");
    try expr.write(l, v, .param);
    try l.put("'");
}
