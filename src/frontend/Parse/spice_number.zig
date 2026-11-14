//! SPICE number literals. In: one field's text. Out: its value, as ngspice
//! reads it: scale suffixes through ngspice's INPevaluate arithmetic (not
//! the correctly rounded value), and plain decimal numbers for data files.
//! Cites: ngspice inpeval.c INPevaluate; glibc's pow(10, e) for the scale
//! (#36); Touchstone 2.0 rule 6.
//!
//! Contents:
//! - `pub fn plainNumber(t: []const u8) ?f64`
//! - `pub inline fn spiceNumber(text: []const u8) ?f64`

const std = @import("std");
const assert = std.debug.assert;

/// A plain number: decimal or scientific notation (Touchstone 2.0 rule 6;
/// an HSPICE RLGC or vector file's too), and nothing parseFloat also takes
/// (`inf`, `nan`, hex, `_`). Null for anything else.
pub fn plainNumber(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    const int_start = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    const int_digits = i > int_start;
    var frac_digits = false;
    if (i < t.len and t[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        frac_digits = i > frac_start;
    }
    if (!int_digits and !frac_digits) return null;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const exp_start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == exp_start) return null;
    }
    if (i != t.len) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// A number with a SPICE scale suffix (`10meg`, `2.5u`). An unknown
/// suffix scales by 1. Null when `text` starts with no number.
pub inline fn spiceNumber(text: []const u8) ?f64 {
    const end = numberEnd(text) orelse return null;
    const s = text[end..];
    const scale_exp: i32 = if (s.len == 0)
        0
    else if (std.mem.startsWith(u8, s, "meg"))
        6
    else if (std.mem.startsWith(u8, s, "mil"))
        -6
    else switch (s[0]) {
        't' => 12,
        'g' => 9,
        'k' => 3,
        'm' => -3,
        'u' => -6,
        'n' => -9,
        'p' => -12,
        'f' => -15,
        'a' => -18,
        else => 0,
    };
    return inpEvaluate(text[0..end], scale_exp, std.mem.startsWith(u8, s, "mil"));
}

// ---- private ----

/// Length of the leading decimal literal of `text`: sign, digits, point
/// and exponent, as SPICE delimits a number before its scale suffix. Null
/// when `text` starts with no digit, or with a malformed exponent (`1e+`,
/// `1e+k`). `d` is an exponent letter like `e` (`1d3`), as ngspice reads
/// it (inpeval.c INPevaluate).
fn numberEnd(text: []const u8) ?usize {
    var end: usize = 0;
    var seen_digit = false;
    var seen_dot = false;
    var seen_exp = false;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (c >= '0' and c <= '9') {
            seen_digit = true;
        } else if (c == '.' and !seen_dot and !seen_exp) {
            seen_dot = true;
        } else if ((c == 'e' or c == 'E' or c == 'd' or c == 'D') and !seen_exp and seen_digit and end + 1 < text.len and
            (std.ascii.isDigit(text[end + 1]) or text[end + 1] == '-' or text[end + 1] == '+'))
        {
            seen_exp = true;
            end += 1;
            if (!std.ascii.isDigit(text[end])) {
                if (end + 1 >= text.len or !std.ascii.isDigit(text[end + 1])) return null;
            }
        } else if ((c == '+' or c == '-') and end == 0) {
            // leading sign
        } else {
            break;
        }
    }
    return if (seen_digit) end else null;
}

/// The value of the literal `lit` (as `numberEnd` delimits it) with scale
/// exponent `scale_exp`, computed as ngspice's INPevaluate does (inpeval.c):
/// every digit accumulates into one f64 mantissa, then `sign * mantissa *
/// pow(10, exponent)`. That is not the correctly rounded value: `0.1n` reads
/// 1e-10 here and in ngspice, where parseFloat("0.1") * 1e-9 is
/// 1.0000000000000002e-10, and a time grid built from it drifts off
/// ngspice's by an ulp per step.
fn inpEvaluate(lit: []const u8, scale_exp: i32, mil: bool) f64 {
    assert(lit.len > 0);
    var i: usize = 0;
    var sign: f64 = 1;
    if (lit[0] == '+' or lit[0] == '-') {
        if (lit[0] == '-') sign = -1;
        i = 1;
    }
    var mantis: f64 = 0;
    var e: i32 = scale_exp;
    while (i < lit.len and std.ascii.isDigit(lit[i])) : (i += 1)
        mantis = 10 * mantis + @as(f64, @floatFromInt(lit[i] - '0'));
    if (i < lit.len and lit[i] == '.') {
        i += 1;
        while (i < lit.len and std.ascii.isDigit(lit[i])) : (i += 1) {
            mantis = 10 * mantis + @as(f64, @floatFromInt(lit[i] - '0'));
            e -= 1;
        }
    }
    if (i < lit.len) { // `numberEnd` admits only an exponent here
        i += 1;
        var esign: i32 = 1;
        if (lit[i] == '+' or lit[i] == '-') {
            if (lit[i] == '-') esign = -1;
            i += 1;
        }
        var x: i32 = 0;
        while (i < lit.len) : (i += 1) x = @min(10 * x + (lit[i] - '0'), 100_000);
        e += esign * x;
    }
    if (mil) mantis *= 25.4;
    // ngspice returns 0 * inf = NaN for `0e400`; zero is zero at any scale.
    if (mantis == 0) return sign * 0;
    return sign * mantis * pow10(e);
}

/// 10^e as glibc's pow(10.0, e) returns it: the correctly rounded power for
/// every e but 23 and 210, 0 below 1e-330 and inf past 1e308 (#36).
fn pow10(e: i32) f64 {
    const lo = -330;
    const hi = 308;
    const table = comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var t: [hi - lo + 1]f64 = undefined;
        for (&t, 0..) |*p, k| p.* = std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{@as(i32, k) + lo})) catch unreachable;
        // glibc rounds these two up.
        t[23 - lo] = 1.0000000000000001e23;
        t[210 - lo] = 1.0000000000000001e210;
        break :blk t;
    };
    if (e < lo) return 0;
    if (e > hi) return std.math.inf(f64);
    return table[@intCast(e - lo)];
}

test plainNumber {
    // Hand-listed from Touchstone 2.0 rule 6: digits with an optional sign,
    // point and exponent, and nothing else parseFloat would also take.
    for ([_][]const u8{ "1", "-2.5", "+.5", "5.", "1e3", "1.5E-3", "-0e+0" }) |text|
        try std.testing.expect(plainNumber(text) != null);
    for ([_][]const u8{ "", ".", "+", "-.", ".e5", "1e", "1e+", "1k", "inf", "nan", "0x10", "1_0", " 1" }) |text|
        try std.testing.expect(plainNumber(text) == null);
    try std.testing.expectEqual(@as(?f64, -1.5e-3), plainNumber("-1.5e-3"));
}

test "number literals read as ngspice's INPevaluate" {
    const n = spiceNumber;
    try std.testing.expectEqual(1e7, n("10meg").?);
    try std.testing.expectEqual(1e-10, n("0.1n").?); // not parseFloat("0.1") * 1e-9
    try std.testing.expectEqual(1e-3, n("1m").?);
    try std.testing.expectEqual(1e-3, n("1ms").?);
    try std.testing.expectEqual(1000, n("1k").?);
    try std.testing.expectEqual(1000, n("1e3").?);
    try std.testing.expectEqual(1, n("1e-3k").?);
    try std.testing.expectEqual(0.5, n("+.5").?);
    try std.testing.expectEqual(-3, n("-3").?);
    try std.testing.expectEqual(5, n("5v").?); // an unknown suffix scales by 1
    try std.testing.expectEqual(2e-18, n("2a").?); // atto (#121)
    try std.testing.expectEqual(1000, n("1d3").?); // `d` exponent (#121)
    try std.testing.expectEqual(1, n("1x").?);
    try std.testing.expectApproxEqRel(25.4e-6, n("1mil").?, 1e-15);
    try std.testing.expectEqual(1.0000000000000001e23, n("1e23").?); // glibc's pow(10, 23)
    try std.testing.expect(1.0000000000000001e23 != 1e23);
    // Past +-40 the exponent reads exactly too, as glibc's pow does (#36).
    try std.testing.expectEqual(1e-300, n("1e-300").?);
    try std.testing.expectEqual(1e300, n("1e300").?);
    try std.testing.expectEqual(@as(f64, 3) * @as(f64, 1e45), n("3e45").?); // 3 * pow(10, 45), as inpeval.c
    try std.testing.expectEqual(1.0000000000000001e210, n("1e210").?);
    try std.testing.expectEqual(0, n("1e-331").?);
    try std.testing.expectEqual(0, n("0e400").?);
    try std.testing.expect(std.math.isInf(n("1e400").?));
    for ([_][]const u8{ "", "-", ".", "abc", "e5", "1e+" }) |bad| try std.testing.expectEqual(null, n(bad));
}
