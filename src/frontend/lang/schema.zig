//! The directive table of the ESPice language: one row per directive (its
//! subjects, keys and their types, whether it owns a block, and its
//! lowering), merged at compile time from one file per area. A directive
//! with no row, or with two, fails to compile, and every row lowers. To
//! add a directive: give it a row and its lowering in its area's file (or
//! a new area file, one line in `rows` below), and extend
//! tests/lang_lower.zig and a twin test.
//! Cites: docs/using/language.md (every statement's signature);
//! compiler-construction rule 4.
//!
//! Contents:
//! - `pub const Directive`
//! - `pub const Ty`
//! - `pub const Need`
//! - `pub const Slot`
//! - `pub const Bound`: `get`
//! - `pub const Lower`
//! - `pub const Row`
//! - `pub const rows`
//! - `pub fn directive(name: []const u8) ?Directive`

const std = @import("std");
const number = @import("number.zig");
const ast = @import("ast.zig");
const Lowerer = @import("lower.zig").Lowerer;
const Quantity = number.Quantity;

/// Every directive the language has, the header's `.espice` aside.
pub const Directive = enum(u8) {
    title,
    param,
    func,
    model,
    subckt,
    global,
    connect,
    @"if",
    elseif,
    @"else",
    include,
    lib,
    hdl,
    verilog,
    vec,
    load,
    save,
    alter,
    option,
    ic,
    nodeset,
    probe,
    op,
    dc,
    tf,
    sens,
    dcmatch,
    dcsens,
    dcxf,
    dcinc,
    mc,
    ac,
    noise,
    pz,
    disto,
    sp,
    lin,
    net,
    stb,
    lstb,
    acmatch,
    acxf,
    tran,
    four,
    fft,
    trannoise,
    envelope,
    matex,
    pss,
    pac,
    pxf,
    pnoise,
    ptdnoise,
    qpss,
    hb,
    hbac,
    hbxf,
    hbnoise,
    hblin,
    phasenoise,
    step,
    data,
    wcd,
    variation,
    meas,
    check,
    dout,
    biaschk,
    stim,
    mosra,
    appendmodel,
    sample,
};

/// A slot's type (language.md "Types").
pub const Ty = enum(u8) {
    /// Any expression.
    expr,
    /// A number whose unit, if any, is `Slot.q`'s, or an expression.
    quantity,
    /// A number with no unit (or `%`), or an expression.
    real,
    /// As `real`, and a literal has no fraction.
    integer,
    /// The bare key.
    flag,
    /// One of `Slot.words`.
    word,
    /// `"text"`.
    string,
    /// A name or a number.
    node,
    /// `v(n)`, `v(a,b)`, `i(name)`, and the `.ac` forms.
    probe,
    /// A name: an instance, model, subcircuit, parameter or measurement.
    reference,
    /// `lin(...)`, `dec(...)`, `oct(...)` or a list.
    range,
    /// `pulse(...)` and the other waves.
    wave,
    /// `[a, b]`, each element of type `Slot.elem`.
    list,
    /// `(a, b)`.
    pair,
    /// `( ... )`: a port list.
    ports,
    /// Anything; the row's lowering checks it.
    any,
};

/// Whether a slot must be given.
pub const Need = enum(u1) { optional, required };

/// One subject or key of a statement.
pub const Slot = struct {
    /// The key; for a subject, the name messages use.
    key: []const u8,
    ty: Ty,
    /// The quantity of a `quantity` slot, or of a list's elements.
    q: Quantity = .none,
    /// The words of a `word` slot.
    words: []const []const u8 = &.{},
    /// The element type of a `list` slot.
    elem: Ty = .expr,
    need: Need = .optional,
};

/// A statement checked against its row: the node of each subject, of
/// each key slot (`ast.none` when absent; the word node for a flag), and
/// every setting no slot names (rows with `open` keys).
pub const Bound = struct {
    stmt: ast.Index,
    /// The `sweep` clause's expression, or `ast.none` (rows with `sweeps`).
    sweep: ast.Index,
    subjects: []const ast.Index,
    keys: []const ast.Index,
    open: []const ast.Index,

    /// The node of key slot `key` of `row`, or `ast.none`.
    pub fn get(b: Bound, row: Row, key: []const u8) ast.Index {
        for (row.keys, b.keys) |s, n| if (std.mem.eql(u8, s.key, key)) return n;
        unreachable; // a lowering asks only for its own row's keys
    }
};

/// Writes one checked statement as legacy cards.
pub const Lower = *const fn (l: *Lowerer, b: Bound) std.mem.Allocator.Error!void;

/// What the table knows about one directive.
pub const Row = struct {
    subjects: []const Slot = &.{},
    /// More subjects of the last subject slot's type may follow.
    variadic: bool = false,
    keys: []const Slot = &.{},
    /// Any other `key=value` is accepted (model, subcircuit and
    /// parameter settings, `.ic` nodes) and left to the deck build.
    open: bool = false,
    /// Owns a `{ }` block of statements.
    block: bool = false,
    /// Takes a `sweep` clause, which its lowering writes from
    /// `Bound.sweep`; on any other row the clause is refused.
    sweeps: bool = false,
    /// Null only on rows built to bind an instance's settings; every
    /// directive's row has one (checked when the table is merged).
    lower: ?Lower = null,
};

/// The merged table: one line per area file.
pub const rows: std.EnumArray(Directive, Row) = merge(.{
    @import("structure.zig").rows,
    @import("analyses.zig").rows,
    @import("meas.zig").rows,
    @import("checks.zig").rows,
    @import("stats.zig").rows,
    @import("analyses_dc.zig").rows,
    @import("analyses_small.zig").rows,
    @import("analyses_time.zig").rows,
    @import("analyses_periodic.zig").rows,
    @import("sweeps.zig").rows,
});

/// The directive `name` (without its dot) names.
pub fn directive(name: []const u8) ?Directive {
    return std.meta.stringToEnum(Directive, name);
}

// ---- private ----

fn merge(comptime areas: anytype) std.EnumArray(Directive, Row) {
    comptime {
        @setEvalBranchQuota(20_000);
        var out: std.EnumArray(Directive, Row) = .initUndefined();
        var seen: std.EnumSet(Directive) = .empty;
        for (areas) |area| for (@typeInfo(@TypeOf(area)).@"struct".field_names) |name| {
            const d = @field(Directive, name);
            if (seen.contains(d)) @compileError("two rows for ." ++ name);
            if (@field(area, name).lower == null) @compileError("no lowering for ." ++ name);
            seen.insert(d);
            out.set(d, @field(area, name));
        };
        for (std.enums.values(Directive)) |d| if (!seen.contains(d)) @compileError("no row for ." ++ @tagName(d));
        return out;
    }
}
