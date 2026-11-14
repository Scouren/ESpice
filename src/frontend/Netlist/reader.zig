//! The netlist reader's state. In: an ngspice deck's logical lines.
//! Out: the `Reader`, nine groups of tables, one per owner: the stage that
//! writes a group is named on it, and every other stage reads it. The
//! stages are free functions over it in the reader_*.zig files;
//! reader_run.zig `run` is the spine that calls them in order and freezes
//! `nl`, `deck` and `live` into a `Netlist`.
//! Cites: ngspice inpcom.c, inp.c (recifeval), subckt.c; HSPICE [SA], [CR].
//!
//! Contents:
//! - `pub const Reader = struct`
//! - `pub const measureExpr = reader_measures.measureExpr`
//! - `pub const measureOption = reader_measures.measureOption`
//! - `pub const measureValue = reader_measures.measureValue`
//! - `pub fn init(arena: Allocator, ast: Ast) Allocator.Error!Reader`
//! - `pub const Diag = struct`
//! - `pub const Decls = struct`
//! - `pub const Tables = struct`
//! - `pub const Cards = struct`
//! - `pub const LiveState = struct`
//! - `pub const LocalModels = struct`
//! - `pub const Eval = struct`
//! - `pub const Compiled = struct`
//! - `pub const CardScratch = struct`
//! - `pub const Func = struct`
//! - `pub const Binding = struct`
//! - `pub const LocalReads`
//! - `pub const ParamKey`

const std = @import("std");
const Ast = @import("../Ast.zig");
const Allocator = std.mem.Allocator;
const expr = @import("../Parse/expr.zig");
const core = @import("core");
const InternPool = core.InternPool;
const card_rows = @import("card_rows.zig");
const reader_frame = @import("reader_frame.zig");
const reader_measures = @import("reader_measures.zig");
const reader_diag = @import("reader_diag.zig");
const VertexId = card_rows.VertexId;
const Value = card_rows.Value;
const Kv = card_rows.Kv;
const Hypergraph = card_rows.Hypergraph;
const Step = card_rows.Step;
const Optimize = card_rows.Optimize;
const Wcd = card_rows.Wcd;
const Data = card_rows.Data;
const Variation = card_rows.Variation;
const Analysis = card_rows.Analysis;
const Config = card_rows.Config;
const Foreign = card_rows.Foreign;
const Mosra = card_rows.Mosra;
const AppendModel = card_rows.AppendModel;
const Scope = reader_frame.Scope;
const Subckt = reader_frame.Subckt;
const ModelRow = reader_frame.ModelRow;
const LocalModel = reader_frame.LocalModel;

/// The netlist reader's state: every walk's tables. The walks are free
/// functions over it, in the reader_*.zig stage files.
pub const Reader = struct {
    arena: Allocator,
    ast: Ast,
    diag: Diag = .{},
    decl: Decls = .{},
    nl: Tables,
    deck: Cards = .{},
    live: LiveState = .{},
    local: LocalModels = .{},
    eval: Eval = .{},
    card: CardScratch = .{},

    // measure.zig's `ctx` interface: it calls these as methods.
    pub const measureExpr = reader_measures.measureExpr;
    pub const measureOption = reader_measures.measureOption;
    pub const measureValue = reader_measures.measureValue;

    /// A reader over `ast`'s cards; net 0 is ground.
    pub fn init(arena: Allocator, ast: Ast) Allocator.Error!Reader {
        var r: Reader = .{ .arena = arena, .ast = ast, .nl = .{ .hg = try .init(arena) } };
        const zero = try r.nl.pool.intern(arena, "0");
        _ = r.nl.hg.addVertex(arena, .{ .name = zero }) catch return error.OutOfMemory;
        try r.nl.net_of.append(arena, 0);
        return r;
    }
};

/// The diagnostics a read has met (reader_diag.zig), and the card a stage
/// is reading, which a refusal that has no line in hand names.
pub const Diag = struct {
    /// The card a walk is reading: a refusal no reader recorded names it (#144).
    card: []const u8 = "",
    /// Every diagnostic so far, in the order met; `reader_diag.render` logs them.
    rows: std.ArrayList(reader_diag.Row) = .empty,
    /// How many rows are refusals (`failed`, `unsupported`): a stage
    /// compares it before and after a call to see whether that call named
    /// its card.
    refusals: u32 = 0,
};

/// What the deck declares: walk 1 (reader_walk.zig) writes it, every later
/// stage reads it.
pub const Decls = struct {
    subckts: std.ArrayList(Subckt) = .empty,
    subckt_ids: std.StringHashMapUnmanaged(u16) = .empty,
    globals: Scope = .empty,
    /// The global `.param` names in deck order, for `foldGlobals`.
    global_keys: std.ArrayList([]const u8) = .empty,
    global_scopes: [1]*const Scope = undefined,
    /// `.func` and `.param f(x)=` definitions, by name.
    funcs: std.StringHashMapUnmanaged(Func) = .empty,
    /// `.data` and `.variation` blocks: first and one-past-last line.
    blocks: std.ArrayList([2]u32) = .empty,
    /// The top-level device cards' `lines` rows, from walk 1, so a
    /// swept name a card carries resolves to it (`stepTarget`).
    top_devices: []const u32 = &.{},
    foreign: std.ArrayList(Foreign) = .empty,
    /// Top-level `.if`/`.elseif` conditions evaluated in walk 1, in order.
    cond_texts: std.ArrayList([]const u8) = .empty,
};

/// The netlist's tables under construction; `run` freezes them into a
/// `Netlist`, field for field.
pub const Tables = struct {
    hg: Hypergraph.Builder,
    pool: InternPool = .{},
    /// The net of each name, `none` for a device name.
    net_of: std.ArrayList(u32) = .empty,
    /// A flattened name under construction.
    name_buf: std.ArrayList(u8) = .empty,
    /// `.global` names: one net at every subcircuit level.
    global_nets: std.StringHashMapUnmanaged(void) = .empty,
    values: std.ArrayList(Value) = .empty,
    kvs: std.ArrayList(Kv) = .empty,
    ops: std.ArrayList(expr.Op) = .empty,
    consts: std.ArrayList(f64) = .empty,
    models: std.ArrayList(ModelRow) = .empty,
    model_ids: std.StringHashMapUnmanaged(u32) = .empty,
    /// Subcircuit instances expanded so far; 0 is the top level.
    instances: u32 = 1,
};

/// The directive cards, as `Netlist.deck` publishes them, and the card
/// lines read after the device walk.
pub const Cards = struct {
    analyses: std.ArrayList(Analysis) = .empty,
    config: std.ArrayList(Config) = .empty,
    /// `.option scale` and `wnflag`, read before any device.
    scale: f64 = 1,
    wnflag: bool = false,
    ic_cards: std.ArrayList([]const Value) = .empty,
    nodeset_cards: std.ArrayList([]const Value) = .empty,
    meas_lines: std.ArrayList([]const u8) = .empty,
    /// The `.wcd` card, read once the `.meas` cards it names are.
    wcd_line: ?[]const u8 = null,
    saves: std.ArrayList([]const u8) = .empty,
    opvar_saves: std.ArrayList([]const u8) = .empty,
    save_all: bool = false,
    save_op: ?core.SaveOp = null,
    stims: std.ArrayList(core.Stim) = .empty,
    sample: ?core.query.NoiseSample = null,
    mosra: ?Mosra = null,
    appendmodels: std.ArrayList(AppendModel) = .empty,
    vpi_apps: std.ArrayList([]const u8) = .empty,
    soa_file: []const u8 = "",
    emir_file: ?[]const u8 = null,
    measures: std.ArrayList(core.Measure) = .empty,
    steps: std.ArrayList(Step) = .empty,
    data: std.ArrayList(Data) = .empty,
    variations: std.ArrayList(Variation) = .empty,
    optimize: ?Optimize = null,
    wcd: ?Wcd = null,
    /// `Deck.draw_seed`.
    draw_seed: bool = false,
};

/// What a variant re-evaluates, as `Netlist.live` publishes it: the swept
/// names, the distribution sites and the bins a swept geometry may take.
pub const LiveState = struct {
    /// Swept global parameters, registered before any device is read.
    names: std.StringArrayHashMapUnmanaged(void) = .empty,
    nominal: std.ArrayList(f64) = .empty,
    /// Some card runs Monte Carlo.
    monte: bool = false,
    site_ops: std.ArrayList(u32) = .empty,
    site_keys: std.ArrayList(u64) = .empty,
    /// `Live.bins`, column by column.
    bin_edges: std.ArrayList(u32) = .empty,
    bin_starts: std.ArrayList(u32) = .empty,
    bin_rows: std.ArrayList(u32) = .empty,
    bin_bounds: std.ArrayList([4]f64) = .empty,
    bin_per_finger: std.ArrayList(bool) = .empty,
};

/// Subcircuit-local `.model` cards and the rows each instance resolved
/// (reader_models.zig).
pub const LocalModels = struct {
    /// Every subcircuit's `.model` cards, in line order.
    models: std.ArrayList(LocalModel) = .empty,
    /// Names in `local_models`, for `isModel`.
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Per `local_models` row, the model rows read from its line, one per
    /// distinct set of values, so instances with equal parameters share
    /// a row. Sized on the first `localRow`, once `local_models` is whole.
    variants: []std.ArrayList(u32) = &.{},
    /// Per `local_models` row, the parameter names its line can read
    /// (`localReads`); null until first needed.
    reads: []?LocalReads = &.{},
    /// `localRow` results keyed by the row and every scope entry its
    /// line can reach (`localKey`): an instance whose parameters are the
    /// same text as an earlier one's skips re-reading the card.
    memo: std.StringHashMapUnmanaged(u32) = .empty,
    key: std.ArrayList(u8) = .empty,
    /// `(name, row)` of the instance models the open expansions resolved;
    /// `Frame.models_mark` splits it by instance.
    instance_models: std.ArrayList(struct { name: []const u8, row: u32 }) = .empty,
};

/// Expression scratch, and what kind of text is being read: the mode
/// `fold` and `subst` decide by (reader_values.zig, reader_subst.zig).
pub const Eval = struct {
    /// Key of the text whose distribution calls are being emitted, and
    /// the next call's ordinal within it.
    site_owner: u64 = 0,
    site_ordinal: u32 = 0,
    /// Open `name(` groups in the value being read.
    group_depth: u8 = 0,
    /// The formals of the user functions `subst` is inside, innermost last.
    bindings: std.ArrayList(Binding) = .empty,
    scratch: expr.Scratch = .{},
    /// Parameter and function texts compiled once each (`compiledText`).
    compiled_texts: std.StringHashMapUnmanaged(*const expr.Scratch) = .empty,
    /// Unbraced `key=expr` values of the deck's own text compiled once
    /// each, by the address of their first byte (`compiledAt`).
    compiled_at: std.AutoHashMapUnmanaged(usize, Compiled) = .empty,
    /// B, E and G expressions of the deck's own text that `unbraced`
    /// accepted, by their (address, length), and the text it returned.
    unbraced_at: std.AutoHashMapUnmanaged([2]usize, []const u8) = .empty,
    /// A subcircuit instance's text parameter folded to a number, by its
    /// scope and row there: a PDK's chained `.param`s read each other
    /// many times, and splicing every read re-expands the chain.
    param_memo: std.AutoHashMapUnmanaged(ParamKey, f64) = .empty,
    stack: std.ArrayList(expr.Val) = .empty,
};

/// An expression compiled from a deck byte on, and the byte after it.
pub const Compiled = struct { code: *const expr.Scratch, end: usize };

/// The device card being read: its parts until `commit` appends them
/// (reader_card.zig). Reused by every card.
pub const CardScratch = struct {
    nodes: std.ArrayList([]const u8) = .empty,
    pins: std.ArrayList(VertexId) = .empty,
    positional: std.ArrayList(Value) = .empty,
    kv: std.ArrayList(Kv) = .empty,
};

/// A user function: its formals and its body as written.
pub const Func = struct { formals: []const []const u8, body: []const u8 };

/// A formal of the function `subst` is expanding, bound to the
/// argument's final ops.
pub const Binding = struct { name: []const u8, ops: []const expr.Op };

pub const LocalReads = union(enum) { stochastic, names: []const []const u8 };

/// A scope (by address) and its row of one parameter: `Eval.param_memo`'s key.
pub const ParamKey = struct { scope: usize, row: usize };

// ---- private ----
