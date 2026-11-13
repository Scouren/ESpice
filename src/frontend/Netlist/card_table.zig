//! The element-form tables and line predicates. In: a card's head word or line.
//! Out: which card or behavioural form it is, and the line predicates the
//! walks ask (a `seed=` option, an analysis card, a `key=`).
//! Cites: dev/research/{ngspice,hspice,spectre}-syntax.md (D1, X4, D4;
//! #121); ngspice inpcom.c (b_transformation_wanted, E/G keywords).
//!
//! Contents:
//! - `pub const Branches = struct`
//! - `pub const max = 32`
//! - `pub fn active(b: Branches) bool`
//! - `pub const Form`
//! - `pub const behavioural`
//! - `pub const data_file_keys`
//! - `pub fn seedOption(line: []const u8) bool`
//! - `pub fn setsKey(line: []const u8, key: []const u8) bool`
//! - `pub fn isDataElement(letter: u8, line: []const u8) bool`
//! - `pub fn bTransformationWanted(p: []const u8) bool`
//! - `pub fn kvIndex(kvs: []const Kv, key: []const u8) ?usize`
//! - `pub fn isBinOf(model: []const u8, base: []const u8) bool`
//! - `pub fn binBounds(kv: []const Kv) ?[4]f64`
//! - `pub fn readsLive(ops: []const expr.Op) bool`

const std = @import("std");
const expr = @import("../Parse/expr.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const Kv = card_rows.Kv;
const kvNumber = netlist_view.kvNumber;

/// Open `.if` chains, matching ngspice's recifeval (inp.c): each chain keeps
/// the lines of its first true branch and drops the rest.
pub const Branches = struct {
    open: [max]State = undefined,
    depth: u8 = 0,

    /// `live`: in the kept branch; `pending`: no branch held yet; `spent`:
    /// a branch already held, or the whole chain sits in a dropped region.
    const State = enum(u2) { live, pending, spent };
    pub const max = 32;

    pub fn active(b: Branches) bool {
        return b.depth == 0 or b.open[b.depth - 1] == .live;
    }
};

/// A behavioural E/F/G/H form, named by the word in the first control-node
/// slot (ngspice inpcom.c, HSPICE's E/G element keywords) unless a linear
/// card's tail follows it, where the word is a node, as ngspice-44.2 reads
/// it (reader_devices.zig). HSPICE's PWL, VCR and VCCAP are refused: plain
/// ngspice-44.2 stops on PWL(1) and VCR PWL(1) ("Bad real value"). A
/// `gate` (AND, NAND, OR, NOR) is refused by name: ngspice runs it on an E
/// card as XSPICE's multi_input_pwl, which is not ported.
pub const Form = enum { value, poly, table, laplace, pole, delay, kind, gate, refused };

pub const behavioural = std.StaticStringMap(Form).initComptime(.{
    .{ "poly", .poly },    .{ "value", .value },     .{ "vol", .value },   .{ "cur", .value },
    .{ "table", .table },  .{ "laplace", .laplace }, .{ "pole", .pole },   .{ "freq", .refused },
    .{ "vcr", .refused },  .{ "vccap", .refused },   .{ "delay", .delay }, .{ "opamp", .refused },
    .{ "npwl", .refused }, .{ "ppwl", .refused },    .{ "pwl", .refused }, .{ "and", .gate },
    .{ "nand", .gate },    .{ "or", .gate },         .{ "nor", .gate },    .{ "vcvs", .kind },
    .{ "vccs", .kind },    .{ "ccvs", .kind },       .{ "cccs", .kind },   .{ "transformer", .refused },
});

/// Keys whose value is a data file a `.model` card names: an RLGC table,
/// a Touchstone or a CITI file.
pub const data_file_keys = std.StaticStringMap(void).initComptime(.{
    .{ "rlgcfile", {} }, .{ "tstonefile", {} }, .{ "citifile", {} },
});

/// A `.option`/`.options` card (lowercased) that sets `seed=`.
pub fn seedOption(line: []const u8) bool {
    return std.mem.startsWith(u8, line, ".opt") and setsKey(line, "seed");
}

/// Whether `line` (lowercased) holds `key=` with `key` a whole word.
pub fn setsKey(line: []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, key)) |k| : (at = k + key.len) {
        if (k > 0 and (std.ascii.isAlphanumeric(line[k - 1]) or line[k - 1] == '_')) continue;
        const rest = std.mem.trimStart(u8, line[k + key.len ..], " \t");
        if (rest.len > 0 and rest[0] == '=') return true;
    }
    return false;
}

/// Whether the `letter` card `line` is ESPice's W RLGC line or S N-port
/// (HSPICE's spelling, [CR] W and S elements): a W or S card with any
/// `key=value` field (`rlgcmodel=`, `tablemodel=`, `n=`, `l=`, `mname=`,
/// `tstonefile=`, `fqmodel=`, `type=`, `zo=`, ...). ngspice's switches
/// (`S1 1 2 3 4 sw ON`, `W1 1 2 vc sw OFF`; inp2s.c, inp2w.c) carry none,
/// and refuse `m=` (net_card.zig), so the two readings never meet.
pub fn isDataElement(letter: u8, line: []const u8) bool {
    return (letter == 's' or letter == 'w') and std.mem.indexOfScalar(u8, line, '=') != null;
}

/// ngspice b_transformation_wanted (inpcom.c): `p` reads a node voltage,
/// a branch current, `time`, `temper` or `hertz`, so a passive card holding
/// it becomes a B source.
pub fn bTransformationWanted(p: []const u8) bool {
    for (p, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, "vith", c) == null) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(p[i - 1]) or p[i - 1] == '_')) continue;
        const tail = p[i..];
        if (std.mem.startsWith(u8, tail, "v(") or std.mem.startsWith(u8, tail, "i(")) return true;
        for ([_][]const u8{ "temper", "hertz", "time" }) |w| {
            if (!std.mem.startsWith(u8, tail, w)) continue;
            if (tail.len == w.len or !(std.ascii.isAlphanumeric(tail[w.len]) or tail[w.len] == '_')) return true;
        }
    }
    return false;
}

/// Row of `key` in `kvs`.
pub fn kvIndex(kvs: []const Kv, key: []const u8) ?usize {
    for (kvs, 0..) |kv, i| if (std.mem.eql(u8, kv.key, key)) return i;
    return null;
}

/// Whether `model` is a bin of `base`: `base.<n>`.
pub fn isBinOf(model: []const u8, base: []const u8) bool {
    if (model.len <= base.len + 1 or !std.mem.startsWith(u8, model, base) or model[base.len] != '.') return false;
    _ = std.fmt.parseInt(u32, model[base.len + 1 ..], 10) catch return false;
    return true;
}

/// A bin card's `{lmin, lmax, wmin, wmax}`, null unless all four are numbers.
pub fn binBounds(kv: []const Kv) ?[4]f64 {
    return .{
        kvNumber(kv, "lmin") orelse return null, kvNumber(kv, "lmax") orelse return null,
        kvNumber(kv, "wmin") orelse return null, kvNumber(kv, "wmax") orelse return null,
    };
}

/// Whether postfix `ops` reads a live name.
pub fn readsLive(ops: []const expr.Op) bool {
    for (ops) |op| if (op.code == .live) return true;
    return false;
}

// ---- private ----
