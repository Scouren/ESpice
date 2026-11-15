//! Tests of the analyses package 1 lowers: `.tf` ... `.mc`, `.noise` ...
//! `.acxf`, `.four` ... `.matex`, `.pss` ... `.phasenoise`.
//! Oracles: the legacy card written by hand from each analysis's Legacy
//! entry in docs/using/language.md, checked against the card reader in
//! src/frontend/Jobs/analysis_{small,time,rf}.zig; the legacy reader,
//! which must read every lowered card (`Netlist.parse` of a deck holding
//! it, `Netlist.parseAnalyses` of the cards alone); and, for decks
//! without instances, the reader as reference implementation (a deck and
//! its hand-written legacy twin read to the same analyses). Codes pinned
//! for every refusal.
//!
//! Contents:
//! - `pub const AnyNode`: `node`
//! - `pub fn expectCards(body: []const u8, want: []const u8, extra: []const u8) !void`
//! - `pub fn expectDeck(body: []const u8, want: []const u8, extra: []const u8) ![]const u8`
//! - `pub fn expectLowered(body: []const u8, want: []const u8) ![]const u8`
//! - `pub fn expectRefused(stmt: []const u8, code: Code) !void`
//! - `pub fn expectTwins(new: []const u8, legacy: []const u8) !void`

const std = @import("std");
const testing = std.testing;
const lang = @import("../lang.zig");
const netlist = @import("../Netlist.zig");
const Code = lang.diag.Code;

/// Every net name resolves.
pub const AnyNode = struct {
    /// Net 1, whatever the name.
    pub fn node(_: AnyNode, _: []const u8) u32 {
        return 1;
    }
};

/// Lowers `.espice 1` + `body` as an include (no title line) and compares
/// it with `want`; then the legacy reader reads the result: as a deck
/// (`Netlist.parse`, after a title and `extra`, hand-written legacy
/// cards) and as appended analysis cards (`Netlist.parseAnalyses`).
pub fn expectCards(body: []const u8, want: []const u8, extra: []const u8) !void {
    const got = try expectDeck(body, want, extra);
    defer testing.allocator.free(got);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try netlist.parseAnalyses(arena.allocator(), got, AnyNode{});
}

/// `expectCards` for statements that are not analysis cards: the deck
/// read only. Returns the lowered text (owned by the caller).
pub fn expectDeck(body: []const u8, want: []const u8, extra: []const u8) ![]const u8 {
    const got = try expectLowered(body, want);
    errdefer testing.allocator.free(got);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    errdefer std.debug.print("the reader refuses:\n{s}{s}", .{ extra, got });
    _ = try netlist.parse(a, try std.mem.concat(a, u8, &.{ "t\n", extra, got }));
    return got;
}

/// Lowers `.espice 1` + `body` as an include and compares it with `want`;
/// returns the lowered text (owned by the caller).
pub fn expectLowered(body: []const u8, want: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", body, "\n" });
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .include);
    if (got.diags.len != 0) {
        for (got.diags) |d| std.debug.print("{t} at {any}: {s}\n", .{ d.code, lang.diag.lineCol(src, d.at), d.subject });
        return error.UnexpectedRows;
    }
    try testing.expectEqualStrings(want, got.text);
    return testing.allocator.dupe(u8, got.text);
}

/// The one statement `stmt` draws rows, every one `code`, and the
/// statement after it still lowers.
pub fn expectRefused(stmt: []const u8, code: Code) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ ".espice 1\n", stmt, "\n.param ok = 1\n" });
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), src, .top);
    errdefer std.debug.print("{s}: {any}\n", .{ stmt, got.diags });
    try testing.expect(got.diags.len >= 1);
    for (got.diags) |d| try testing.expectEqual(code, d.code);
    try testing.expect(std.mem.endsWith(u8, got.text, ".param ok=1\n"));
}

/// A deck in the language and its legacy twin read to the same analyses,
/// steps, data tables and title.
pub fn expectTwins(new: []const u8, legacy: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(try dump(a, &try netlist.parse(a, legacy)), try dump(a, &try netlist.parse(a, new)));
}

// ---- private ----

fn dump(a: std.mem.Allocator, nl: *const netlist.Netlist) ![]const u8 {
    var w: std.ArrayList(u8) = .empty;
    try w.print(a, "title {s}\n", .{nl.deck.title});
    for (nl.deck.analyses) |an| {
        try w.print(a, "analysis {t} {d} {d} {any} sweep {t}", .{ an.kind, an.pos, an.neg, an.ports, an.sweep });
        for (an.args) |v| try value(a, &w, v);
        try w.append(a, '\n');
    }
    for (nl.deck.steps) |s| try w.print(a, "step {any} {any}\n", .{ s.target, s.values });
    for (nl.deck.data) |d| try w.print(a, "data {s} {any} {any}\n", .{ d.name, d.columns, d.values });
    return w.items;
}

fn value(a: std.mem.Allocator, w: *std.ArrayList(u8), v: netlist.Value) !void {
    switch (v) {
        .num => |x| try w.print(a, " {e}", .{x}),
        .name => |s| try w.print(a, " '{s}'", .{s}),
        .expr => try w.appendSlice(a, " expr"),
        .group => |g| {
            try w.appendSlice(a, " (");
            for (g.items) |item| try value(a, w, item);
            try w.append(a, ')');
        },
    }
}

test "DC analyses: each form as its legacy card, which the reader reads" {
    try expectCards(
        \\.tf out=v(out) src=Vin
        \\.tf out=i(Vm) src=Iin
        \\.sens out=v(out, ref)
        \\.sens out=v(out) freq=dec(1Hz, 1kHz, n=10)
        \\.dcmatch out=v(out)
        \\.dcsens out=v(out) file="dc.sens" perturbation=1e-3 interval=2 threshold=0.1 groupbydevice=yes
        \\.dcxf out=v(out)
        \\.dcxf out=i(Vm) tf
        \\.dcinc
        \\.mc trials=1000 sigma=1%
        \\.mc trials=n
    ,
        \\.tf v(out) Vin
        \\.tf i(Vm) Iin
        \\.sens v(out,ref)
        \\.sens v(out) ac dec 10 1 1k
        \\.dcmatch v(out)
        \\.dcsens v(out) file=dc.sens perturbation=1e-3 interval=2 threshold=0.1 groupbydevice=yes
        \\.dcxf v(out)
        \\.dcxf i(Vm) tf
        \\.dcinc
        \\.mc 1000 1e-2
        \\.mc 'n'
        \\
    , ".param n=10\n");
}

test "small-signal analyses: each form as its legacy card, which the reader reads" {
    try expectCards(
        \\.noise out=v(out) src=Vin freq=dec(10Hz, 10MHz, n=10) contributions
        \\.noise out=v(out, ref) freq=[1kHz, 2kHz]
        \\.pz in=v(in, 0) out=v(out) drive=voltage find=both
        \\.pz in=v(a, b) out=v(c, d) drive=current find=zeros
        \\.pz
        \\.disto freq=dec(1kHz, 100kHz, n=10) f2overf1=0.9
        \\.sp freq=lin(1MHz, 1GHz, n=100) noise
        \\.lin sparcalc noisecalc gdcalc format=touchstone filename="amp.s2p" mixedmode2port=ss
        \\.lin
        \\.net out=v(out) src=Vin rin=50Ohm rout=75Ohm
        \\.net src=Vin rin=50
        \\.stb probe=Vp freq=dec(1Hz, 1GHz, n=10)
        \\.lstb mode=single vsource=Vprobe
        \\.lstb mode=diff vsource=[Vp, Vn] localgnd=g freq=oct(1kHz, 1MHz, n=3)
        \\.acmatch out=v(out) threshold=0.01 file="m.txt" interval=1 virtual_sensitivity=no sens_threshold=0.5
        \\.acxf out=v(out) freq=dec(1Hz, 1MHz, n=5) tf
    ,
        \\.noise v(out) Vin dec 10 10 10meg 1
        \\.noise v(out,ref) poi 2 1k 2k
        \\.pz in 0 out 0 vol pz
        \\.pz a b c d cur zer
        \\.pz
        \\.disto dec 10 1k 100k 0.9
        \\.sp lin 100 1meg 1g 1
        \\.lin sparcalc=1 noisecalc=1 gdcalc=1 format=touchstone filename=amp.s2p mixedmode2port=ss
        \\.lin
        \\.net v(out) Vin rin=50 rout=75
        \\.net Vin rin=50
        \\.stb Vp dec 10 1 1g
        \\.lstb mode=single vsource=Vprobe
        \\.lstb mode=diff vsource=Vp,Vn localgnd=g oct 3 1k 1meg
        \\.acmatch v(out) threshold=0.01 file=m.txt interval=1 virtual_sensitivity=no sens_threshold=0.5
        \\.acxf v(out) dec 5 1 1meg tf
        \\
    , "");
}

test "transient analyses: each form as its legacy card, which the reader reads" {
    try expectCards(
        \\.four v(out) v(in) f0=1kHz nharm=9
        \\.fft v(out) start=1ns stop=5ns np=1024 format=norm window=hann alfa=3 freq=1MHz fmin=0 fmax=1GHz
        \\.trannoise stop=1us step=1ns
        \\.trannoise out=v(out) method=sde seed=3 samples=1 fmin=1kHz fmax=1GHz scale=2 time=all
        \\.trannoise out=v(out) time=5ns
        \\.envelope period=1ms stop=5ms
        \\.matex stop=2ms step=1us
    ,
        \\.four 1k v(out) v(in) 9
        \\.fft v(out) start=1n stop=5n np=1024 format=norm window=hann alfa=3 freq=1meg fmin=0 fmax=1g
        \\.trannoise 1n 1u
        \\.trannoise v(out) method=sde seed=3 samples=1 fmin=1k fmax=1g scale=2 time=all
        \\.trannoise v(out) time=5n
        \\.envelope 1m 5m
        \\.matex 1u 2m
        \\
    , "");
}

test "periodic and harmonic-balance analyses: each form as its legacy card, which the reader reads" {
    try expectCards(
        \\.pss f0=1kHz points=256
        \\.pss f0=1kHz
        \\.pss f0=1GHz osc=v(osc) settle=20
        \\.pss f0=1GHz osc=v(osc) points=128 settle=20
        \\.pss f0=1MHz tstab=10us osc=v(o) points=100 harmonics=10 sciter=50 steadycoeff=1e-3 uic
        \\.pac f0=1kHz freq=dec(10Hz, 10kHz, n=4)
        \\.pxf f0=1kHz freq=[10Hz, 20Hz]
        \\.pxf out=v(out) f0=1kHz freq=dec(10Hz, 10kHz, n=4)
        \\.pnoise out=v(out) src=Vin freq=dec(10Hz, 10kHz, n=3) f0=1kHz sidebands=3
        \\.ptdnoise out=v(out) time=1ns tdelta=1ps freq=dec(1kHz, 1MHz, n=2)
        \\.ptdnoise out=v(out) time=lin(0, 1ns, n=5) freq=[1kHz]
        \\.qpss f1=1kHz f2=1.4142kHz nharms=[2, 2]
        \\.qpss f1=1kHz f2=1.5kHz nharms=[3]
        \\.hb f0=1kHz harmonics=8
        \\.hb f0=1GHz osc=v(t)
        \\.hb tones=[1kHz, 1.1kHz] nharms=[5, 5] intmodmax=7 subharms=2 ss_tone=2
        \\.hbac freq=dec(1Hz, 1kHz, n=10) f0=1MHz harmonics=4
        \\.hbxf out=v(out) freq=lin(1kHz, 2kHz, n=5)
        \\.hbnoise out=v(out) src=Vin freq=dec(1Hz, 1kHz, n=2) f0=1MHz harmonics=4 sidebands=3
        \\.hblin freq=dec(1MHz, 1GHz, n=10) noisecalc filename="hb.s2p" dataformat=ri
        \\.phasenoise out=v(t) freq=dec(1kHz, 1MHz, n=2)
        \\.phasenoise out=v(t) freq=dec(1kHz, 1MHz, n=2) f0=1GHz harmonics=6 method=bpn carrierindex=2
    ,
        \\.pss 1k 256
        \\.pss 1k
        \\.pss v(osc) 1g 256 20
        \\.pss v(osc) 1g 128 20
        \\.pss 1meg 10u o 100 10 50 1e-3 uic
        \\.pac 1k dec 4 10 10k
        \\.pxf 1k poi 2 10 20
        \\.pxf v(out) 1k dec 4 10 10k
        \\.pnoise v(out) Vin dec 3 10 10k 1k 3
        \\.ptdnoise v(out) time=1n tdelta=1p dec 2 1k 1meg
        \\.ptdnoise v(out) time= lin 5 0 1n poi 1 1k
        \\.qpss 1k 1.4142k 2 2
        \\.qpss 1k 1.5k 3
        \\.hb 1k 8
        \\.hb v(t) 1g
        \\.hb tones=1k 1.1k nharms=5 5 intmodmax=7 subharms=2 ss_tone=2
        \\.hbac dec 10 1 1k 1meg 4
        \\.hbxf v(out) lin 5 1k 2k
        \\.hbnoise v(out) Vin dec 2 1 1k 1meg 4 3
        \\.hblin dec 10 1meg 1g noisecalc=1 filename=hb.s2p dataformat=ri
        \\.phasenoise v(t) dec 2 1k 1meg
        \\.phasenoise v(t) dec 2 1k 1meg 1g 6 method=2 carrierindex=2
        \\
    , "");
}

test "the ngspice .pss form is the one the reader tells apart: seven or eight arguments, the first no v()" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try lang.lowerRows(testing.allocator, arena.allocator(), ".espice 1\n.pss f0=1MHz tstab=10us osc=v(o) points=100 harmonics=10 sciter=50 steadycoeff=1e-3\n.pss f0=1GHz osc=v(o) points=128 settle=20\n", .include);
    try testing.expectEqual(0, got.diags.len);
    const cards = try netlist.parseAnalyses(arena.allocator(), got.text, AnyNode{});
    try testing.expect(cards[0].ngspicePss() and !cards[1].ngspicePss());
}

test "analysis refusals, each with its code" {
    for ([_]struct { []const u8, Code }{
        .{ ".tf out=v(o)", .missing_key },
        .{ ".tf out=vdb(o) src=V1", .wrong_kind },
        .{ ".sens out=i(V1)", .wrong_kind },
        .{ ".sens out=v(o) freq=[1Hz]", .no_legacy },
        .{ ".mc trials=1.5", .fraction },
        .{ ".dcsens out=v(o) groupbydevice=maybe", .unknown_word },
        .{ ".noise out=v(o) freq=lin(1, 2, step=1)", .unknown_key },
        .{ ".pz in=v(a)", .missing_key },
        .{ ".pz in=v(a) out=v(b) drive=volt find=both", .unknown_word },
        .{ ".lstb mode=single vsource=[Vp, Vn]", .arity },
        .{ ".lstb mode=diff vsource=Vp", .arity },
        .{ ".net src=V1 rout=50", .no_legacy },
        .{ ".stb probe=Vp freq=[1Hz]", .no_legacy },
        .{ ".lin format=s2p", .unknown_word },
        .{ ".four f0=1kHz", .arity },
        .{ ".four i(V1) f0=1kHz", .wrong_kind },
        .{ ".fft v(o) window=hanning", .unknown_word },
        .{ ".trannoise stop=1us", .missing_key },
        .{ ".trannoise out=v(o) stop=1us", .no_legacy },
        .{ ".trannoise stop=1us step=1ns seed=2", .no_legacy },
        .{ ".trannoise out=v(o) time=1V", .wrong_unit },
        .{ ".pss f0=1kHz settle=3", .no_legacy },
        .{ ".pss f0=1kHz harmonics=3", .no_legacy },
        .{ ".pss f0=1kHz tstab=1us osc=v(o) points=10 harmonics=3 sciter=2", .missing_key },
        .{ ".pss f0=1kHz tstab=1us osc=v(o) points=10 harmonics=3 sciter=2 steadycoeff=1 settle=2", .no_legacy },
        .{ ".pss f0=1kHz osc=v(a, b)", .wrong_kind },
        .{ ".pnoise out=v(o) src=V1 freq=[1kHz]", .missing_key },
        .{ ".ptdnoise out=v(o) time=1V freq=[1kHz]", .wrong_unit },
        .{ ".qpss f1=1kHz f2=2kHz nharms=[1, 2, 3]", .arity },
        .{ ".hb", .missing_key },
        .{ ".hb tones=[1kHz]", .missing_key },
        .{ ".hb f0=1kHz tones=[1kHz] nharms=[3]", .no_legacy },
        .{ ".hb f0=1kHz nharms=[3]", .no_legacy },
        .{ ".hbac freq=dec(1, 10, n=1) harmonics=3", .no_filler },
        .{ ".hbnoise out=v(o) freq=dec(1, 10, n=1) f0=1k sidebands=3", .no_filler },
        .{ ".hbxf out=v(o) freq=[1Hz]", .no_legacy },
        .{ ".phasenoise out=v(t) freq=dec(1, 10, n=1) harmonics=3", .no_filler },
        .{ ".phasenoise out=v(t, u) freq=dec(1, 10, n=1)", .wrong_kind },
        .{ ".phasenoise out=v(t) freq=dec(1, 10, n=1) method=2", .wrong_kind },
    }) |c| try expectRefused(c[0], c[1]);
}

test "a deck of analyses without instances reads as its legacy twin" {
    try expectTwins(
        \\.espice 1
        \\.title "twin"
        \\.param fs = 1kHz
        \\.tf out=v(out) src=Vin
        \\.sens out=v(out) freq=dec(1Hz, fs, n=10)
        \\.noise out=v(out) src=Vin freq=[1kHz, 2kHz] contributions
        \\.pz in=v(in) out=v(out) drive=current find=poles
        \\.four v(out) f0=fs
        \\.pss f0=fs*2 osc=v(osc) settle=20
        \\.hb tones=[1kHz, 1.1kHz] nharms=[5, 5]
        \\.phasenoise out=v(t) freq=dec(1kHz, 1MHz, n=2) f0=1GHz method=pac
    ,
        \\twin
        \\.param fs=1k
        \\.tf v(out) Vin
        \\.sens v(out) ac dec 10 1 'fs'
        \\.noise v(out) Vin poi 2 1k 2k 1
        \\.pz in 0 out 0 cur pol
        \\.four 'fs' v(out)
        \\.pss v(osc) 'fs*2' 256 20
        \\.hb tones=1k 1.1k nharms=5 5
        \\.phasenoise v(t) dec 2 1k 1meg 1g method=1
        \\
    );
}
