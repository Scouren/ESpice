//! Mismatch and sensitivity requests: the variation groups a mismatch or
//! sensitivity analysis sums over, and the `.dcmatch`, `.acmatch`,
//! `.dcsens` and `.sens` cards. Plain data, filled by the frontend from the
//! deck's `.variation` block and read by the drivers.
//! Cites: HSPICE [CR .DCMATCH, .ACMATCH, .DCSENS]; ngspice `.sens`.
//!
//! Contents:
//! - `pub const Variations = struct`
//! - `pub const Dcmatch = struct`
//! - `pub const Acmatch = struct`
//! - `pub const Dcsens = struct`
//! - `pub const Sens = struct`, `Sens.AcSource = struct`

const Tolerances = @import("../numerics.zig").Tolerances;
const FreqSweep = @import("../freq_sweep.zig").FreqSweep;
const CardNames = @import("card_names.zig").CardNames;

/// Parameter variations a mismatch or sensitivity analysis sums over, from
/// the deck's `.variation` block and `DEV`/`LOT` specs. Group g moves
/// `params[starts[g]..starts[g + 1]]` (ordinals in `Circuit.collectParams`
/// order) together, each by its own one-sigma step in `sigmas`: a
/// per-device row is one group per device, a per-model row one group over
/// every device of the model. Empty: every parameter alone at its Pelgrom
/// sigma.
pub const Variations = struct {
    /// Per group: `<card>@<param>` or `<model>@<param>`.
    labels: []const []const u8 = &.{},
    starts: []const u32 = &.{},
    params: []const u32 = &.{},
    sigmas: []const f64 = &.{},
};

/// 1-sigma spread of a DC output from device mismatch (`.dcmatch`).
pub const Dcmatch = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    variations: Variations = .{},
    /// The deck's card names: without a variation block, an internal add
    /// (`CardNames.internal`, such as a portnum V's z0 resistor) has no row.
    card_names: CardNames = .empty,
};

/// HSPICE `.acmatch`: the 1-sigma spread of an AC output over the `.ac`
/// sweep from the same variations as `Dcmatch`.
pub const Acmatch = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    variations: Variations = .{},
    /// The deck's card names: without a variation block, an internal add
    /// (`CardNames.internal`, such as a portnum V's z0 resistor) has no row.
    card_names: CardNames = .empty,
};

/// HSPICE `.dcsens`: the DC output's change per one-sigma step of each
/// variation group.
pub const Dcsens = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    variations: Variations = .{},
    /// The deck's card names: without a variation block, an internal add
    /// (`CardNames.internal`, such as a portnum V's z0 resistor) has no row.
    card_names: CardNames = .empty,
};

/// Sensitivity of one output to every device parameter (`.sens`): DC, or
/// over an AC sweep (`.sens <out> ac <sweep>`, ngspice inp2dot.c:481-570).
pub const Sens = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    /// Card names for the result columns, so they match ngspice's. An
    /// unnamed instance falls back to `<type>#<ordinal>`.
    card_names: CardNames = .empty,
    /// The AC form's sweep; null is the DC sensitivity.
    ac: ?FreqSweep = null,
    /// Every V and I card, `AC` spec or not, for their `<card>_acmag`
    /// and `<card>_acphase` columns (ngspice vsrc.c, isrc.c).
    ac_sources: []const AcSource = &.{},

    /// One source's share of `Deck.ac_drive`: its phasor is subtracted at
    /// row `pos` and added at row `neg` (GROUND, branch for a V card).
    pub const AcSource = struct {
        name: []const u8,
        pos: u32,
        neg: u32,
        re: f64,
        im: f64,
        /// d(re, im)/d(acmag): e^(j phase), times `m` on an I card.
        unit: [2]f64,
    };
};
