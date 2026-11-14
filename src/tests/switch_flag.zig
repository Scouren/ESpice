//! An S or W card's ON/OFF initial-state word (SpiceRack P8-045). Oracles:
//! metamorphic relations inside one deck, whose switches share one model per
//! kind, so a memoised device row cannot carry one card's word to another.
//! Outside the band the word cannot matter: swload.c and cswload.c pick
//! REALLY_OFF below it and REALLY_ON above it from the control alone. Inside
//! a positive band an S card's ON gives the above-band (on) answer, and OFF
//! or no word the below-band one (swload.c:43-75). A W card's word never
//! reaches the .op (cswload.c:65-71 read CKTstate1), so all three give the
//! below-band answer. ngspice 44.2 refuses any other word as an unknown
//! parameter. tests/netlist/op/switch_{s,w}_{on,off,none}.sp pin the
//! numbers, the negative band and vh = 0 against ngspice 44.2.
const std = @import("std");
const api = @import("espice");
const decks = @import("deck.zig");
const t = std.testing;

const bands = [_][]const u8{ "lo", "mid", "hi" };
const flags = [_][]const u8{ "on", "off", "none" };

/// Per kind (`os` S, `ow` W), band and flag, one switch pulling node
/// `<kind>_<band>_<flag>` up to 1 V through 1k: ron=1 gives 1/1001 V (on),
/// roff=1meg 1meg/1.001meg V (off). The bands are 0.5 +- 0.2 (V, mA).
const deck = blk: {
    var s: []const u8 = "switch flags\nvs s 0 1\n";
    for (bands, [_][]const u8{ "0.1", "0.5", "0.9" }) |b, x| {
        s = s ++ "vc" ++ b ++ " c" ++ b ++ " 0 " ++ x ++ "\ni" ++ b ++ " 0 x" ++ b ++ " " ++ x ++ "m\nvx" ++ b ++ " x" ++ b ++ " 0 0\n";
        for (flags) |f| {
            const word: []const u8 = if (std.mem.eql(u8, f, "none")) "" else " " ++ f;
            const tag = "_" ++ b ++ "_" ++ f;
            s = s ++ "rs" ++ tag ++ " s os" ++ tag ++ " 1k\nss" ++ tag ++ " os" ++ tag ++ " 0 c" ++ b ++ " 0 swp" ++ word ++ "\n";
            s = s ++ "rw" ++ tag ++ " s ow" ++ tag ++ " 1k\nww" ++ tag ++ " ow" ++ tag ++ " 0 vx" ++ b ++ " cswp" ++ word ++ "\n";
        }
    }
    break :blk s ++ models ++ ".op\n.end\n";
};

const models = ".model swp sw(vt=0.5 vh=0.2 ron=1 roff=1meg)\n.model cswp csw(it=0.5m ih=0.2m ron=1 roff=1meg)\n";

test "outside the band an S or W card's ON, OFF or no word give the same .op" {
    const p = try decks.solve(deck);
    defer p.deinit();
    const r = try decks.resultOf(p, .op);
    inline for (.{ "os", "ow" }) |k| {
        inline for (.{ "_lo_", "_hi_" }) |b| {
            const want = try decks.at(r, 0, "v(" ++ k ++ b ++ "none)");
            try t.expectApproxEqRel(want, try decks.at(r, 0, "v(" ++ k ++ b ++ "on)"), 1e-12);
            try t.expectApproxEqRel(want, try decks.at(r, 0, "v(" ++ k ++ b ++ "off)"), 1e-12);
        }
        // Not vacuous: below the band is off and above it on, 1000x apart.
        try t.expect(try decks.at(r, 0, "v(" ++ k ++ "_lo_none)") > 900 * try decks.at(r, 0, "v(" ++ k ++ "_hi_none)"));
    }
}

test "inside a positive band ON turns an S card on, and no word reaches a W card" {
    // Red before the fix: S's ON was dropped, so v(os_mid_on) was off.
    const p = try decks.solve(deck);
    defer p.deinit();
    const r = try decks.resultOf(p, .op);
    const on = try decks.at(r, 0, "v(os_hi_none)");
    const off = try decks.at(r, 0, "v(os_lo_none)");
    try t.expectApproxEqRel(on, try decks.at(r, 0, "v(os_mid_on)"), 1e-12);
    try t.expectApproxEqRel(off, try decks.at(r, 0, "v(os_mid_off)"), 1e-12);
    try t.expectApproxEqRel(off, try decks.at(r, 0, "v(os_mid_none)"), 1e-12);
    inline for (flags) |f| try t.expectApproxEqRel(off, try decks.at(r, 0, "v(ow_mid_" ++ f ++ ")"), 1e-12);
}

test "a word other than ON or OFF after a switch model is refused" {
    // ngspice 44.2: "unknown parameter (foo)", and nothing runs. Both cards
    // ran with the word dropped before the fix.
    inline for (.{ "s1 o 0 c 0 swp foo\n", "w1 o 0 vx cswp foo\n" }) |card| {
        const text = "bad switch word\nvs s 0 1\nvc c 0 0.5\nix 0 x 0.5m\nvx x 0 0\nr1 s o 1k\n" ++ card ++ models ++ ".op\n.end\n";
        try t.expectError(error.UnknownParameter, api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = text, .origin = "switch_flag.cir" } } }));
    }
}
