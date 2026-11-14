//! The reader spine: a deck's text through the three walks to a frozen
//! `Netlist`, and the `.ic`-style node values it publishes.
//! Cites: ngspice inp.c (walk order); #63, #65, #100, #164, #203.
//!
//! Contents:
//! - `pub const NetLookup = struct`
//! - `pub fn node(self: NetLookup, name: []const u8) u32`
//! - `pub fn run(arena: Allocator, deck: *const Ast, live_params: []const []const u8) (Error || error{UnknownParameter})!Netlist`
//! - `pub fn nodeValues(arena: Allocator, cards_args: []const []const Value, nets: NetLookup) Error![]const Ic`

const std = @import("std");
const Ast = @import("../Ast.zig");
const Token = @import("../tokenizer.zig").Token;
const Allocator = std.mem.Allocator;
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const temper_slots = @import("temper_slots.zig");
const reader_devices = @import("reader_devices.zig");
const reader_directives = @import("reader_directives.zig");
const reader_live = @import("reader_live.zig");
const reader_measures = @import("reader_measures.zig");
const reader_models = @import("reader_models.zig");
const reader_sweeps = @import("reader_sweeps.zig");
const reader_walk = @import("reader_walk.zig");
const reader_diag = @import("reader_diag.zig");
const reader_params = @import("reader_params.zig");
const reader_finish = @import("reader_finish.zig");
const core = @import("core");
const Reader = reader.Reader;
const EdgeId = card_rows.EdgeId;
const none = card_rows.none;
const Error = card_rows.Error;
const Value = card_rows.Value;
const Model = card_rows.Model;
const Ic = card_rows.Ic;
const Netlist = netlist_view.Netlist;
const nodeText = reader_frame.nodeText;
const resolve = reader_frame.resolve;
const Frame = reader_frame.Frame;
const ModelLine = reader_frame.ModelLine;
const top_level = reader_frame.top_level;
const seedOption = card_table.seedOption;
const setsKey = card_table.setsKey;
const InternPool = core.InternPool;
const isGroundName = netlist_view.isGroundName;

pub const NetLookup = struct {
    pool: *const InternPool,
    net_of: []const u32,
    /// The net `name` names, 0 for ground, `none` for no net.
    pub fn node(self: NetLookup, name: []const u8) u32 {
        if (isGroundName(name)) return 0;
        const n = self.pool.find(name) orelse return none;
        return self.net_of[n.index()];
    }
};

pub fn run(arena: Allocator, deck: *const Ast, live_params: []const []const u8) (Error || error{UnknownParameter})!Netlist {
    var state: Reader = try .init(arena, deck.*);
    const r = &state;
    // Logged once, at the end, success or not; the fallback below runs
    // first (errdefers unwind in reverse), so it is the last row.
    defer reader_diag.render(r);
    try reader_diag.reserve(r);
    errdefer if (r.diag.refusals == 0 and r.diag.card.len > 0)
        reader_diag.noteUnreadable(r, r.ast.written(r.diag.card));
    r.decl.global_scopes = .{&r.decl.globals};
    const ast = &r.ast;
    const tags = ast.cards.items(.tag);
    // Sized from the card count, so a flat deck never regrows them:
    // about one device name and one new net per card.
    const cards: usize = ast.len();
    try r.nl.hg.ensureTotalCapacity(arena, cards + 1, cards, 3 * cards);
    const names_hint: u32 = @intCast(@min(2 * cards, none - 1));
    try r.nl.pool.reserve(arena, names_hint);
    try r.nl.net_of.ensureTotalCapacity(arena, names_hint + 1);
    try r.nl.values.ensureTotalCapacity(arena, cards);
    // One `key=value` row per `=` token of a flat deck.
    try r.nl.kvs.ensureTotalCapacity(arena, std.mem.countScalar(Token.Tag, ast.tokens.items(.tag), .equal));

    var top_devices: std.ArrayList(u32) = .empty;
    try top_devices.ensureTotalCapacityPrecise(arena, ast.len());
    var model_lines: std.ArrayList(ModelLine) = .empty;
    var directive_lines: std.ArrayList(u32) = .empty;
    try reader_walk.declarations(r, &top_devices, &model_lines, &directive_lines);
    r.decl.top_devices = top_devices.items;
    const top: Frame = .{ .scopes = &r.decl.global_scopes };
    // Three kinds of card make the models read next (a PDK's shared
    // bins) keep their distribution sites. A MONTE sweep draws them
    // per trial; the analysis cards are read after the models
    // (#100). ngspice draws agauss/gauss/unif/aunif on every run, and
    // a seed makes that one reproducible sample. `.dcmatch`,
    // `.acmatch` and `.dcsens` without a `.variation` block read the
    // mismatch off the calls (`variants.Planner.siteVariations`), as
    // `.wcd` (#240) does.
    // ponytail: a top-level `.param` read in walk 1 stays nominal;
    // the PDK distributions sit in model cards and subcircuit params.
    var monte_card = false;
    var seed = false;
    var mismatch = false;
    for (directive_lines.items) |i| {
        const line = ast.line(i);
        seed = seed or seedOption(line);
        mismatch = mismatch or tags[i] == .wcd;
        if (tags[i] != .analysis) continue;
        const kind = tags[i].analysis;
        monte_card = monte_card or setsKey(line, "monte");
        mismatch = mismatch or kind == .dcmatch or kind == .acmatch or kind == .dcsens;
    }
    r.deck.draw_seed = seed and !monte_card;
    r.live.monte = monte_card or seed or mismatch;
    // The caller's live names, registered before any model,
    // directive or device reads them, so a card that cannot follow a
    // later value (an analysis, `.ic`, `.options`) is refused.
    const tunable = try arena.alloc(u32, live_params.len);
    for (live_params, tunable) |name, *k| {
        // The live table keeps the key; the caller's bytes may not outlive the call.
        const key = try std.ascii.allocLowerString(arena, name);
        k.* = try reader_params.liveParam(r, key) orelse {
            try reader_diag.note(r, .{ .code = .live_unknown, .text = name });
            return error.UnknownParameter;
        };
    }
    for (r.decl.blocks.items) |b| try reader_sweeps.readBlock(r, b);
    // `.step` cards first, so their swept names are live before any
    // other directive reads them, wherever they sit in the deck (#63).
    for (directive_lines.items) |i| if (tags[i] == .step) try reader_directives.readDirective(r, ast.cursor(i));
    for (directive_lines.items) |i| if (tags[i] != .step) try reader_directives.readDirective(r, ast.cursor(i));
    try reader_params.foldGlobals(r);
    // Global models in line order, then each subcircuit's own, kept
    // together: `models_lo..models_hi` is one range per subcircuit,
    // nested definitions included. They follow the directives, so a
    // `.step` or `.dc` swept name is live when a model value reads it
    // (#65).
    for (model_lines.items) |ml| if (ml.owner == top_level) try reader_models.readModel(r, ast.cursor(ml.line), &top, true);
    for (r.decl.subckts.items, 0..) |*sub, id| for (model_lines.items) |ml| {
        if (ml.owner != id) continue;
        try reader_models.readModel(r, ast.cursor(ml.line), &top, false);
        const row: u32 = @intCast(r.nl.models.items.len - 1);
        const name = r.nl.models.items[row].name;
        const shared = !ml.cond and !reader_models.unresolved(r, r.nl.models.items[row].kv) and !reader_models.namesParam(r, r.nl.models.items[row].kv, sub.*);
        if (sub.models_hi == 0) sub.models_lo = @intCast(r.local.models.items.len);
        try r.local.models.append(arena, .{ .name = name, .line = ml.line, .top = row, .shared = shared, .cond = ml.cond });
        sub.models_hi = @intCast(r.local.models.items.len);
        try r.local.names.put(arena, name, {});
    };
    try reader_directives.binOptions(r);

    for (top_devices.items) |i| try reader_devices.readDevice(r, ast.cursor(i), &top);
    // The passes below read no one card.
    r.diag.card = "";
    try reader_finish.shunts(r);
    try reader_measures.readMeasures(r);
    try reader_measures.compileFails(r);
    if (r.deck.wcd_line) |line| r.deck.wcd = try reader_measures.readWcd(r, line);
    var live = try reader_live.resolveLive(r);
    live.conds = try reader_live.liveConds(r);
    const scale = try r.arena.alloc(f64, live.slots.len);
    @memset(scale, 1);
    try reader_finish.modelBins(r, live.slots, scale);
    live.scale = scale;
    live.bins = .{ .edges = r.live.bin_edges.items, .starts = r.live.bin_starts.items, .rows = r.live.bin_rows.items, .bounds = r.live.bin_bounds.items, .per_finger = r.live.bin_per_finger.items };

    const graph = try r.nl.hg.finish(arena);
    const models = try arena.alloc(Model, r.nl.models.items.len);
    for (models, r.nl.models.items) |*m, row| m.* = .{ .name = row.name, .kind = row.kind, .kv = r.nl.kvs.items[row.kv.start..][0..row.kv.len] };
    // After `resolveLive`, which reads a live name inside a kept
    // value from a constant-pool row.
    const model_kvs = try arena.alloc(card_rows.Span, r.nl.models.items.len);
    for (model_kvs, r.nl.models.items) |*span, row| span.* = row.kv;
    const temper = try temper_slots.find(arena, &graph, model_kvs, r.nl.values.items, r.nl.kvs.items, r.nl.ops.items, r.nl.consts.items);

    // Stable counting sort of devices by card letter.
    const kinds = graph.edges.items(.kind);
    var starts: [27]u32 = @splat(0);
    for (kinds) |k| starts[k - 'a' + 1] += 1;
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const order = try arena.alloc(EdgeId, kinds.len);
    var next: [26]u32 = starts[0..26].*;
    for (kinds, 0..) |k, e| {
        order[next[k - 'a']] = .from(e);
        next[k - 'a'] += 1;
    }

    const nets: NetLookup = .{ .pool = &r.nl.pool, .net_of = r.nl.net_of.items };
    for (r.deck.analyses.items) |*a| resolve(a, nets);

    return .{
        .pool = r.nl.pool,
        .graph = graph,
        .order = order,
        .kind_starts = starts,
        .values = r.nl.values.items,
        .kvs = r.nl.kvs.items,
        .ops = r.nl.ops.items,
        .consts = r.nl.consts.items,
        .models = models,
        .model_ids = r.nl.model_ids,
        .live = live,
        .temper = temper,
        .tunable = tunable,
        .deck = .{
            .title = ast.title,
            .analyses = r.deck.analyses.items,
            .config = r.deck.config.items,
            .ic = try nodeValues(arena, r.deck.ic_cards.items, nets),
            .nodeset = try nodeValues(arena, r.deck.nodeset_cards.items, nets),
            .saves = if (r.deck.save_all) &.{} else r.deck.saves.items,
            .opvar_saves = r.deck.opvar_saves.items,
            .foreign = r.decl.foreign.items,
            .vpi_apps = r.deck.vpi_apps.items,
            .soa_file = r.deck.soa_file,
            .emir_file = r.deck.emir_file,
            .measures = r.deck.measures.items,
            .steps = r.deck.steps.items,
            .data = r.deck.data.items,
            .variations = r.deck.variations.items,
            .optimize = r.deck.optimize,
            .wcd = r.deck.wcd,
            .save_op = r.deck.save_op,
            .stims = r.deck.stims.items,
            .sample = r.deck.sample,
            .mosra = r.deck.mosra,
            .appendmodels = r.deck.appendmodels.items,
            .draw_seed = r.deck.draw_seed,
        },
    };
}

/// `v(net)=value` pairs of `.ic` and `.nodeset` cards; a net no card
/// names is dropped, and so is `.nodeset all=` (`readDirective`
/// refuses every other bare name).
pub fn nodeValues(arena: Allocator, cards_args: []const []const Value, nets: NetLookup) Error![]const Ic {
    var out: std.ArrayList(Ic) = .empty;
    for (cards_args) |args| {
        var buf: [24]u8 = undefined;
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 2) {
            const name = switch (args[i]) {
                .group => |g| if (std.ascii.eqlIgnoreCase(g.name(), "v") and g.args().len > 0) nodeText(g.args()[0], &buf) else null,
                else => null,
            } orelse continue;
            const value = switch (args[i + 1]) {
                .num => |n| n,
                else => continue,
            };
            const id = nets.node(name);
            if (id == none or id == 0) continue;
            try out.append(arena, .{ .net = .from(id), .value = value });
        }
    }
    return out.items;
}

// ---- private ----
