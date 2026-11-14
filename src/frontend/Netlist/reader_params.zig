//! Global `.param`s. In: the global scope's texts. Out: each folded to its
//! number in deck order, the live table's rows for the swept ones, and what
//! a swept name names (a card, `temp` or a parameter).
//! Cites: ngspice numparam (xpressn.c), dctrcurv.c:156-247; #63, #110.
//!
//! Contents:
//! - `pub fn liveParam(r: *Reader, name: []const u8) Error!?u32`
//! - `pub fn foldGlobals(r: *Reader) Error!void`
//! - `pub fn stepTarget(r: *Reader, name: []const u8) Error!StepTarget`

const std = @import("std");
const reader_values = @import("reader_values.zig");
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const reader_frame = @import("reader_frame.zig");
const reader_diag = @import("reader_diag.zig");
const Reader = reader.Reader;
const Error = card_rows.Error;
const Frame = reader_frame.Frame;
const Value = card_rows.Value;
const StepTarget = card_rows.StepTarget;

// Sweeps and variants.
/// The live-table row of global `.param` `name`, registering it (and
/// folding its nominal value) on first use; null for a name no
/// `.param` defines.
pub fn liveParam(r: *Reader, name: []const u8) Error!?u32 {
    if (r.live.names.getIndex(name)) |k| return @intCast(k);
    const entry = r.decl.globals.get(name) orelse return null;
    const top: Frame = .{ .scopes = &r.decl.global_scopes, .live_ok = true };
    const v = switch (entry) {
        .num => |n| n,
        .text => |text| switch (try reader_values.exprValue(r, text, &top, false)) {
            .num => |n| n,
            else => return error.ParseError,
        },
    };
    try r.live.names.put(r.arena, name, {});
    try r.live.nominal.append(r.arena, v);
    return @intCast(r.live.names.count() - 1);
}

/// Folds each global `.param` to its number in deck order, once every
/// live name is known, so each link of a chain reads its
/// predecessor's number and `subst` recurses one level per read, not
/// one per link (#110). A value that reads a live name, draws a
/// distribution or reads `temper` keeps its text, and an error stays
/// for the card that reads it, except a refusal `subst` logged (an
/// unknown function) and a read of a name nothing defines or of the
/// circuit, which fail the deck read or not, as ngspice's numparam
/// does.
pub fn foldGlobals(r: *Reader) Error!void {
    const top: Frame = .{ .scopes = &r.decl.global_scopes, .keep_live = true };
    // A refusal names the parameter's text.
    const card = r.diag.card;
    defer r.diag.card = card;
    for (r.decl.global_keys.items) |key| {
        const entry = r.decl.globals.getPtr(key).?;
        if (entry.* != .text) continue;
        const ops_mark = r.nl.ops.items.len;
        const consts_mark = r.nl.consts.items.len;
        const sites_mark = r.live.site_ops.items.len;
        r.diag.card = entry.text;
        const refusals = r.diag.refusals;
        const v: ?Value = reader_values.exprValue(r, entry.text, &top, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (r.diag.refusals > refusals) return err else null, // else: the reading card reports it
        };
        // numparam evaluates each .param where it stands and stops on
        // a name it does not define, read or not: ngspice-44.2 says
        // "Undefined parameter [hertz]", and so for time, temp, pi,
        // w and v(a). Only `temper` (final `.ident` 3) waits for its
        // reader: ngspice makes that .param a .func (inpcom.c
        // inp_fix_temper_in_param), which runs where the reading card
        // reads temper and stops elsewhere (temper_slots.zig).
        if (v) |x| if (x == .expr) for (r.nl.ops.items[x.expr.start..][0..x.expr.len]) |op| switch (op.code) {
            .ident => if (op.a != 3) return reader_diag.unsupported(r, entry.text, "a .param that reads a name no .param defines: ngspice-44.2 stops on it, read or not"),
            .vprobe, .iprobe => return reader_diag.unsupported(r, entry.text, "a .param that reads the circuit: ngspice-44.2 stops on it, read or not"),
            else => {}, // else: constants, operators, calls and live names
        };
        r.nl.ops.shrinkRetainingCapacity(ops_mark);
        r.nl.consts.shrinkRetainingCapacity(consts_mark);
        r.live.site_ops.shrinkRetainingCapacity(sites_mark);
        r.live.site_keys.shrinkRetainingCapacity(sites_mark);
        if (v) |x| if (x == .num) {
            entry.* = .{ .num = x.num };
        };
    }
}

/// A swept name: `temp`, a top-level card, or a global `.param`. A
/// card wins over a `.param` of its name, as in ngspice, whose `.dc`
/// looks a name up among the resistors, the V and the I sources,
/// then as `temp` and `@inst[param]`, never among the parameters
/// (dctrcurv.c:156-247). Every sweep that names its quantity (`.dc`,
/// `.step`, a SWEEP tail, a `.data` column) resolves here. Cards
/// match case-insensitively, as `analysis_time.dcTarget` finds them.
// ponytail: a scan of the top-level cards per swept name; index
// them when a deck sweeps many names over millions of cards.
pub fn stepTarget(r: *Reader, name: []const u8) Error!StepTarget {
    if (std.mem.eql(u8, name, "temp")) return .temp;
    for (r.decl.top_devices) |i| {
        var f = r.ast.cursor(i);
        const head = f.field() orelse continue;
        if (std.ascii.eqlIgnoreCase(head, name)) return .{ .card = name };
    }
    if (try liveParam(r, name)) |k| return .{ .param = k };
    return .{ .card = name };
}

// ---- private ----
