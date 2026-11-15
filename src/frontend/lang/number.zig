//! Number literals of the ESPice language. In: one number token's text.
//! Out: `Number` (mantissa text, prefix, unit, its value) or the code of
//! the rule it breaks, and the legacy spelling of a number that reads.
//! Cites: docs/using/language.md "Numbers and units" (the prefix and unit
//! tables and the three safety rules); contract item 4.
//!
//! Contents:
//! - `pub const Prefix`
//! - `pub const Unit`
//! - `pub const Quantity`
//! - `pub const Number`
//! - `pub const Read`
//! - `pub fn read(text: []const u8) Read`
//! - `pub fn quantityOf(u: Unit) Quantity`
//! - `pub fn writeLegacy(n: Number, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Code = @import("diag.zig").Code;

/// A scale prefix; the value is the power of ten.
pub const Prefix = enum(i8) { a = -18, f = -15, p = -12, n = -9, u = -6, m = -3, k = 3, M = 6, G = 9, T = 12 };

/// A unit, by its spelling (`pct` is `%`).
pub const Unit = enum(u8) { V, A, s, Hz, Ohm, S, F, H, m, C, deg, pct };

/// What a unit measures; a slot's type is one of these (or `none`).
pub const Quantity = enum(u8) { none, voltage, current, time, frequency, resistance, conductance, capacitance, inductance, length, temperature, angle, ratio };

/// A number that reads: `mantissa` is the digits as written (fraction and
/// exponent included); `value` is the mantissa times the prefix's factor
/// (times 0.01 for `%`).
pub const Number = struct { mantissa: []const u8, prefix: ?Prefix, unit: ?Unit, value: f64 };

/// `read`'s result: the number, and a code when a rule refuses it (an
/// error) or warns about it (`farad_warning`, number still set).
pub const Read = struct { number: ?Number, code: ?Code };

/// Reads one number token's text.
pub fn read(text: []const u8) Read {
    assert(text.len > 0 and std.ascii.isDigit(text[0]));
    var i: usize = 0;
    while (i < text.len and !std.ascii.isAlphabetic(text[i]) and text[i] != '%') : (i += 1) {}
    // An `e` that is no exponent starts the suffix run, never the mantissa.
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        if (j < text.len and std.ascii.isDigit(text[j])) {
            i = j;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        }
    }
    const mantissa = text[0..i];
    const pct = text[text.len - 1] == '%';
    const run = text[i .. text.len - @intFromBool(pct)];
    const base = std.fmt.parseFloat(f64, mantissa) catch return .{ .number = null, .code = .bad_number };
    if (pct) {
        if (run.len != 0) return .{ .number = null, .code = .percent_prefix };
        return .{ .number = .{ .mantissa = mantissa, .prefix = null, .unit = .pct, .value = base * 0.01 }, .code = null };
    }
    const prefix: ?Prefix, const unit: ?Unit = blk: {
        if (run.len == 0) break :blk .{ null, null };
        if (startsWithIgnoreCase(run, "meg") or startsWithIgnoreCase(run, "mil") or std.mem.indexOfScalar(u8, "xKUNP", run[0]) != null)
            return .{ .number = null, .code = .spice_suffix };
        if (run.len == 1) if (prefixOf(run[0])) |p| {
            if (p == .M) return .{ .number = null, .code = .bare_mega };
            break :blk .{ p, null };
        };
        if (std.meta.stringToEnum(Unit, run)) |u| if (u != .pct) break :blk .{ null, u };
        const p = prefixOf(run[0]) orelse return .{ .number = null, .code = .unknown_unit };
        const u = std.meta.stringToEnum(Unit, run[1..]) orelse return .{ .number = null, .code = .unknown_unit };
        if (u == .pct) return .{ .number = null, .code = .unknown_unit };
        break :blk .{ p, u };
    };
    const scale = if (prefix) |p| std.math.pow(f64, 10, @floatFromInt(@backingInt(p))) else 1;
    const value = base * scale;
    if (!std.math.isFinite(value)) return .{ .number = null, .code = .bad_number };
    const n: Number = .{ .mantissa = mantissa, .prefix = prefix, .unit = unit, .value = value };
    return .{ .number = n, .code = if (prefix == null and unit == .F) .farad_warning else null };
}

/// The quantity unit `u` measures.
pub fn quantityOf(u: Unit) Quantity {
    return switch (u) {
        .V => .voltage,
        .A => .current,
        .s => .time,
        .Hz => .frequency,
        .Ohm => .resistance,
        .S => .conductance,
        .F => .capacitance,
        .H => .inductance,
        .m => .length,
        .C => .temperature,
        .deg => .angle,
        .pct => .ratio,
    };
}

/// Writes `n` as the legacy reader spells it: the mantissa as written,
/// the prefix as its legacy suffix (`M` is `meg`), the unit dropped, and
/// `%` as two more negative powers of ten.
pub fn writeLegacy(n: Number, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (n.unit == .pct) {
        const e = std.mem.indexOfAny(u8, n.mantissa, "eE") orelse return w.print("{s}e-2", .{n.mantissa});
        const exp = std.fmt.parseInt(i32, n.mantissa[e + 1 ..], 10) catch unreachable;
        return w.print("{s}e{d}", .{ n.mantissa[0..e], exp - 2 });
    }
    try w.writeAll(n.mantissa);
    if (n.prefix) |p| try w.writeAll(switch (p) {
        .M => "meg",
        .G => "g",
        .T => "t",
        else => @tagName(p),
    });
}

// ---- private ----

fn prefixOf(c: u8) ?Prefix {
    return switch (c) {
        'a' => .a,
        'f' => .f,
        'p' => .p,
        'n' => .n,
        'u' => .u,
        'm' => .m,
        'k' => .k,
        'M' => .M,
        'G' => .G,
        'T' => .T,
        else => null,
    };
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}
