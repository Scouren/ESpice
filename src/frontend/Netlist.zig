//! Stage 4, device-free half, and the `netlist` module's root. In: a
//! parsed deck (`Ast`). Out: `Netlist`, a flat, subcircuit-expanded
//! nets-by-devices hypergraph plus models and deck cards, which
//! Circuit.zig binds to devices and Jobs.zig plans runs over (Zig's
//! AstGen, with `Netlist` its ZIR). Three walks over the cards: declarations
//! (subcircuit ranges, `.param`, `.model`, directives), devices (an `X` card
//! re-reads its subcircuit's lines under a frame), then analysis nets. Values
//! are rows of flat tables; an expression that does not fold stays postfix.
//!
//! Reads one dialect, ngspice's plus ESPice's own cards; every other
//! dialect arrives translated by SpiceRack (src/spicerack.zig).
//! Cites ngspice (inpcom.c, inp.c recifeval, subckt.c modtranslate,
//! INPgetModBin) for the cards, the HSPICE manuals ([SA], [CR]) for the
//! cards ESPice took from HSPICE, and dev/research/ngspice-syntax.md (§ and
//! rule ids) for the grammar; tests/frontend/grammar/ngspice.peg is its
//! oracle.
//!
//! Contents:
//! - `pub const Ast`
//! - `pub const tokenizer`
//! - `pub const spice_number`
//! - `pub const source`
//! - `pub const expr`
//! - `pub const temper_slots`
//! - `pub const VertexId = card_rows.VertexId`
//! - `pub const EdgeId = card_rows.EdgeId`
//! - `pub const Kind = card_rows.Kind`
//! - `pub const ground = card_rows.ground`
//! - `pub const none = card_rows.none`
//! - `pub const Error = card_rows.Error`
//! - `pub const Span = card_rows.Span`
//! - `pub const Value = card_rows.Value`
//! - `pub const Group = card_rows.Group`
//! - `pub const Kv = card_rows.Kv`
//! - `pub const Net = card_rows.Net`
//! - `pub const Device = card_rows.Device`
//! - `pub const Hypergraph = card_rows.Hypergraph`
//! - `pub const Model = card_rows.Model`
//! - `pub const StepTarget = card_rows.StepTarget`
//! - `pub const Step = card_rows.Step`
//! - `pub const Monte = card_rows.Monte`
//! - `pub const Fail = card_rows.Fail`
//! - `pub const Sweep = card_rows.Sweep`
//! - `pub const Optimize = card_rows.Optimize`
//! - `pub const Wcd = card_rows.Wcd`
//! - `pub const WcdSpec = card_rows.WcdSpec`
//! - `pub const Data = card_rows.Data`
//! - `pub const Variation = card_rows.Variation`
//! - `pub const Live = card_rows.Live`
//! - `pub const Analysis = card_rows.Analysis`
//! - `pub const Config = card_rows.Config`
//! - `pub const Ic = card_rows.Ic`
//! - `pub const ForeignKind = card_rows.ForeignKind`
//! - `pub const Foreign = card_rows.Foreign`
//! - `pub const DataFile = card_rows.DataFile`
//! - `pub const SoaRating = card_rows.SoaRating`
//! - `pub const Deck = card_rows.Deck`
//! - `pub const Mosra = card_rows.Mosra`
//! - `pub const AppendModel = card_rows.AppendModel`
//! - `pub const Netlist = netlist_view.Netlist`
//! - `pub const siteKey = netlist_view.siteKey`
//! - `pub const isGroundName = netlist_view.isGroundName`
//! - `pub const nameIndex = netlist_view.nameIndex`
//! - `pub const isOpVar = netlist_view.isOpVar`
//! - `pub fn elaborate(arena: Allocator, ast: *const Ast, live: []const []const u8) (Error || error{UnknownParameter})!Netlist`
//! - `pub fn parse(arena: Allocator, src: []const u8) Error!Netlist`
//! - `pub fn parseAnalyses(arena: Allocator, text: []const u8, lookup: anytype) (Error || error{UnsupportedDirectiveMutation})![]Analysis`

const std = @import("std");
/// A deck's cards and their tokens, re-exported for the tools.
pub const Ast = @import("Ast.zig");
const Allocator = std.mem.Allocator;
/// Logical lines and tokens, re-exported for the frontend tests.
pub const tokenizer = @import("tokenizer.zig");
/// Number literals, re-exported for the data-file readers.
pub const spice_number = @import("Parse/spice_number.zig");
/// Deck loading and include expansion, re-exported for the frontend tests.
pub const source = @import("source.zig");
const hypergraph = @import("Netlist/hypergraph.zig");
/// The postfix `Value.expr` spans index, re-exported for the builder.
pub const expr = @import("Parse/expr.zig");
/// The values that read `temper`, re-exported for `prepare`.
pub const temper_slots = @import("Netlist/temper_slots.zig");
const measure = @import("Parse/measure.zig");
const pattern = @import("Parse/pattern.zig");
const card_rows = @import("Netlist/card_rows.zig");
const netlist_view = @import("Netlist/netlist_view.zig");
const card_table = @import("Netlist/card_table.zig");
const reader_frame = @import("Netlist/reader_frame.zig");
const sweep_points = @import("Netlist/sweep_points.zig");
const reader = @import("Netlist/reader.zig");
const Reader = reader.Reader;
const reader_run = @import("Netlist/reader_run.zig");
const reader_walk = @import("Netlist/reader_walk.zig");
const reader_models = @import("Netlist/reader_models.zig");
const reader_directives = @import("Netlist/reader_directives.zig");
const reader_sweeps = @import("Netlist/reader_sweeps.zig");
const reader_live = @import("Netlist/reader_live.zig");
const reader_values = @import("Netlist/reader_values.zig");
const reader_subst = @import("Netlist/reader_subst.zig");
const reader_measures = @import("Netlist/reader_measures.zig");
const reader_nets = @import("Netlist/reader_nets.zig");
const reader_devices = @import("Netlist/reader_devices.zig");
const reader_behavioural = @import("Netlist/reader_behavioural.zig");
const reader_rcl = @import("Netlist/reader_rcl.zig");
const reader_diag = @import("Netlist/reader_diag.zig");
const appendAnalysis = reader_frame.appendAnalysis;
const resolve = reader_frame.resolve;

/// A net: a row of `Netlist.graph`'s vertex table.
pub const VertexId = card_rows.VertexId;

/// A device: a row of `Netlist.graph`'s edge table, in card order.
pub const EdgeId = card_rows.EdgeId;

/// Analysis kind, shared with the query layer.
pub const Kind = card_rows.Kind;

/// Net 0; `0`, `gnd` and `ground` all name it.
pub const ground = card_rows.ground;

/// Missing id in every u32 index space here.
pub const none = card_rows.none;

/// `ParseError`: malformed card; `ModelBinNotFound`: no `.model nm.N` bin (card_rows.zig).
pub const Error = card_rows.Error;

/// Rows `start..start+len` of a flat table.
pub const Span = card_rows.Span;

/// One card value after parameter substitution.
pub const Value = card_rows.Value;

/// `name(args)`, held as one slice: `items[0]` is the name (a `.name` (card_rows.zig).
pub const Group = card_rows.Group;

/// `key=value`; a positional model value has an empty key.
pub const Kv = card_rows.Kv;

/// Vertex payload: the net's flattened name in `Netlist.pool`.
pub const Net = card_rows.Net;

/// Hyperedge payload; `model` is a `.model` row or `none`.
pub const Device = card_rows.Device;

/// Nets by devices; a device's pins are its member list, in terminal order.
pub const Hypergraph = card_rows.Hypergraph;

/// A `.model` card: `kind` is the type word (`nmos`, `d`, a VA module name).
pub const Model = card_rows.Model;

/// What a `.step` card or an HSPICE `SWEEP` varies.
pub const StepTarget = card_rows.StepTarget;

/// One swept quantity and its points, in sweep order.
pub const Step = card_rows.Step;

/// HSPICE `MONTE=n [FIRSTRUN=k]`: trials `first..first + n - 1`; or (card_rows.zig).
pub const Monte = card_rows.Monte;

/// A SIGMA_SCALE run's `FAIL=` test over its analysis's `.meas` cards (card_rows.zig).
pub const Fail = card_rows.Fail;

/// An HSPICE sweep on one analysis card: the card runs once per point.
pub const Sweep = card_rows.Sweep;

/// HSPICE optimization [SA Ch.27]: `<card> SWEEP OPTIMIZE=name (card_rows.zig).
pub const Optimize = card_rows.Optimize;

/// ESPice `.wcd` (#240): worst-case distance specs over `.meas` cards (card_rows.zig).
pub const Wcd = card_rows.Wcd;

/// One `.wcd` spec: a `.meas` card and its bound (card_rows.zig).
pub const WcdSpec = card_rows.WcdSpec;

/// An inline `.data` table: one target per column, `values` row-major.
pub const Data = card_rows.Data;

/// One Monte Carlo variation of a model or element parameter: HSPICE (card_rows.zig).
pub const Variation = card_rows.Variation;

/// Values a variant re-evaluates: device and model values that read a swept (card_rows.zig).
pub const Live = card_rows.Live;

/// An analysis card. `pos`/`neg` are the output `v(a[,b])` nets, `ports` the (card_rows.zig).
pub const Analysis = card_rows.Analysis;

/// `.options` and `.temp` cards, in deck order.
pub const Config = card_rows.Config;

/// One `.ic v(net)=value` entry on a net some card names.
pub const Ic = card_rows.Ic;

/// What an include carries: OSDI, Verilog-A, digital Verilog or a data file.
pub const ForeignKind = card_rows.ForeignKind;

/// An HDL or OSDI include, path as written (relative to the deck).
pub const Foreign = card_rows.Foreign;

/// A `ForeignKind.data` file's contents, read by `prepare`.
pub const DataFile = card_rows.DataFile;

/// One limit of the `.options soalimits=` file (#238) (card_rows.zig).
pub const SoaRating = card_rows.SoaRating;

/// Deck data: everything that is not circuit topology.
pub const Deck = card_rows.Deck;

/// HSPICE `.mosra` options as read [SA Ch.29]; SimMode 0 or 2.
pub const Mosra = card_rows.Mosra;

/// `.appendmodel src MOSRA dst NMOS|PMOS`: MOSRA model `src` ages the (card_rows.zig).
pub const AppendModel = card_rows.AppendModel;

/// A parsed, flattened deck. Every slice lives in the parse arena.
pub const Netlist = netlist_view.Netlist;

/// A site key: `owner` mixed with `salt` (splitmix64 finalizer). Stable (netlist_view.zig).
pub const siteKey = netlist_view.siteKey;

/// True for `0`, `gnd` and `ground`, case-insensitively (netlist_view.zig).
pub const isGroundName = netlist_view.isGroundName;

/// Index of the first card name in `names` equal to `target`, byte for (netlist_view.zig).
pub const nameIndex = netlist_view.nameIndex;

/// Whether an output name is a device operating-point variable (#236) (netlist_view.zig).
pub const isOpVar = netlist_view.isOpVar;

/// Elaborates the deck `ast` holds into `arena`: parameters folded,
/// subcircuits flat. The global `.param` names in `live` stay live as a
/// swept name is (`Netlist.tunable`), so a later `setLive` can move them.
/// The result borrows `ast`, the text it was parsed from (paths and the
/// title keep their original case) and the arena, which should be an
/// arena: nothing is freed piecewise. Fails per `Error`, and with
/// `UnknownParameter` for a `live` name no global `.param` defines;
/// partial results stay in the arena.
pub fn elaborate(arena: Allocator, ast: *const Ast, live: []const []const u8) (Error || error{UnknownParameter})!Netlist {
    return reader_run.run(arena, ast, live);
}

/// `Ast.parse` then `elaborate` on the deck text `src`, no parameter live.
pub fn parse(arena: Allocator, src: []const u8) Error!Netlist {
    return elaborate(arena, &try Ast.parse(arena, src, .deck), &.{}) catch |err| switch (err) {
        error.UnknownParameter => unreachable,
        else => |e| return e,
    };
}

/// Parses analysis cards appended to a built circuit, resolving nets through
/// `lookup.node(name) u32`, which sees lowercased names. Any other line, and
/// a `.temp`, is refused with `UnsupportedDirectiveMutation`.
/// The cards and their strings live in `arena`.
pub fn parseAnalyses(arena: Allocator, text: []const u8, lookup: anytype) (Error || error{UnsupportedDirectiveMutation})![]Analysis {
    var state: Reader = try .init(arena, try Ast.parse(arena, text, .cards));
    const r = &state;
    defer reader_diag.render(r);
    r.decl.global_scopes = .{&r.decl.globals};
    var out: std.ArrayList(Analysis) = .empty;
    for (r.ast.lines(), r.ast.cards.items(.tag), 0..) |line, card, i| {
        if (card != .analysis) return error.UnsupportedDirectiveMutation;
        var f = r.ast.cursor(@intCast(i));
        _ = f.field();
        const args = try reader_directives.readArgs(r, &f);
        // A `.temp` is deck configuration, fixed at build.
        if (card.analysis == .temp) return error.UnsupportedDirectiveMutation;
        const first = out.items.len;
        // As readDirective reads a deck's card: its SWEEP tail and the line as written (#64).
        const swept = try reader_sweeps.readSweep(r, card.analysis, args, line);
        try appendAnalysis(arena, &out, .{ .kind = card.analysis, .args = swept.args, .sweep = swept.sweep, .line = r.ast.written(line) });
        for (out.items[first..]) |*a| resolve(a, lookup);
    }
    return out.items;
}

// ---- private ----

test "measure values: empty text is a ParseError, not an index past the end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: Reader = try .init(arena.allocator(), .{});
    const r = &state;
    r.decl.global_scopes = .{&r.decl.globals};
    try std.testing.expectError(error.ParseError, reader_measures.measureValue(r, ""));
    try std.testing.expectEqual(@as(f64, 2e-3), try reader_measures.measureValue(r, "2m"));
    try std.testing.expectEqual(@as(f64, 3), try reader_measures.measureValue(r, "{1+2}"));
}

test {
    _ = tokenizer;
    _ = spice_number;
    _ = source;
    _ = expr;
    _ = temper_slots;
    _ = hypergraph;
    _ = card_rows;
    _ = netlist_view;
    _ = card_table;
    _ = reader_frame;
    _ = sweep_points;
    _ = reader;
    _ = reader_run;
    _ = reader_walk;
    _ = reader_models;
    _ = reader_directives;
    _ = reader_sweeps;
    _ = reader_live;
    _ = reader_values;
    _ = reader_subst;
    _ = reader_measures;
    _ = reader_nets;
    _ = reader_devices;
    _ = reader_behavioural;
    _ = reader_rcl;
    _ = measure;
    _ = pattern;
    _ = @import("source/vec.zig");
    _ = @import("tests/netlist.zig");
    _ = @import("tests/fuzz.zig");
    _ = @import("tests/lines.zig");
    _ = @import("tests/cards.zig");
}
