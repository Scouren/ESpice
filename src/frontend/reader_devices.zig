//! Device cards: the element line read into one hyperedge with its
//! positional and `key=value` rows; shunts and model bins after the walk.
//! Cites: ngspice inpcom.c, INPgetModBin; HSPICE [CR] .OPTION GSHUNT.
//!
//! Contents:
//! - `pub fn Methods(comptime S: type) type`
//! - `pub fn readDevice(r: *R, line: []const u8, frame: *const Frame, row: ?usize) Error!void`
//! - `pub fn isModel(r: *const R, name: []const u8) bool`
//! - `pub fn splitTerminals(r: *R) Error!void`
//! - `pub fn commit(r: *R, head: []const u8, letter: u8, frame: *const Frame) Error!void`
//! - `pub fn shunts(r: *R) Error!void`
//! - `pub fn option(r: *const R, name: []const u8) ?f64`
//! - `pub fn binOptions(r: *R) Error!void`
//! - `pub fn modelBins(r: *R, slots: []const Live.Slot, slot_scale: []f64) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const lines = @import("lines.zig");
const source = @import("source.zig");
const hypergraph = @import("hypergraph.zig");
const expr = @import("expr.zig");
const measure = @import("measure.zig");
const pattern = @import("pattern.zig");
const core = @import("core");
const Name = core.Name;
const InternPool = core.InternPool;
const assert = std.debug.assert;
const reader = @import("reader.zig");
const card_rows = @import("card_rows.zig");
const netlist_view = @import("netlist_view.zig");
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const VertexId = card_rows.VertexId;
const ground = card_rows.ground;
const none = card_rows.none;
const Error = card_rows.Error;
const Value = card_rows.Value;
const Kv = card_rows.Kv;
const Live = card_rows.Live;
const nameKey = netlist_view.nameKey;
const behavioural = card_table.behavioural;
const Frame = reader_frame.Frame;
const Replay = reader_frame.Replay;
const ReplayField = reader_frame.ReplayField;
const binBounds = card_table.binBounds;
const binHolds = netlist_view.binHolds;
const kvNumber = netlist_view.kvNumber;
const appendSpan = reader_frame.appendSpan;

/// The stage's `Reader` methods over dialect syntax `S`; `Reader(S)`
/// aliases each one as its own decl.
pub fn Methods(comptime S: type) type {
    const F = S.Split;
    return struct {
        const R = reader.Reader(S);
        const fixedPins = R.fixedPins;

        /// Reads device card `line`. `row` is its `lines` row when it is a
        /// subcircuit body card (the first read keeps a `Replay` there and
        /// later instances read it) or a top-level card `scanCards` scanned
        /// (it reads that `Replay`).
        pub fn readDevice(r: *R, line: []const u8, frame: *const Frame, row: ?usize) Error!void {
            r.card = line;
            const arena = r.arena;
            var f = F.init(line);
            const head = f.next() orelse return error.ParseError;
            const was_in_card = r.in_card;
            r.in_card = true;
            defer r.in_card = was_in_card;
            if (r.monte) r.site_owner = nameKey(nameKey(0, frame.path orelse ""), head);
            r.site_ordinal = 0;
            if (!F.isWord(head) or !std.ascii.isAlphabetic(head[0])) return error.ParseError;
            const letter = std.ascii.toLower(head[0]);
            if (row) |i| if (r.replays[i]) |rp| return r.replay(rp, line, head, letter, frame);
            if (card_table.isDataElement(letter, line)) return readDataElement(r, head, letter, &f, frame);
            if (try r.behaviouralPassive(line, letter, frame)) return;
            if (std.mem.indexOfScalar(u8, "efgh", letter) != null) {
                // E and G name two controls, F and H one source.
                const controls: u8 = if (letter == 'f' or letter == 'h') 1 else 2;
                var probe = f;
                _ = probe.next();
                _ = probe.next();
                var buf: [16]u8 = undefined;
                const at = probe.pos;
                const fourth = probe;
                if (probe.next()) |t| if (t.len <= buf.len) if (behavioural.get(std.ascii.lowerString(&buf, t))) |form| keyword: {
                    if (form == .kind) {
                        // A word for another letter (`E1 o 0 CCCS ...`) is
                        // refused, as ngspice does, not read as this one (#75).
                        const kinds = std.StaticStringMap(u8).initComptime(.{ .{ "vcvs", 'e' }, .{ "vccs", 'g' }, .{ "ccvs", 'h' }, .{ "cccs", 'f' } });
                        if (kinds.get(std.ascii.lowerString(&buf, t)) != letter) return r.unsupported(line, "a controlled-source type word for another letter");
                        // `E1 a b VCVS c d 2`: ngspice drops the word only
                        // from a whole linear card (inpcom.c replace_token,
                        // 7 fields on E and G, 6 on F and H), so the re-read
                        // keeps its next word as a node and stops there.
                        if (linearTail(probe, controls, false))
                            return r.readDevice(try std.mem.concat(r.arena, u8, &.{ line[0..at], " ", probe.line[probe.pos..] }), frame, null);
                    }
                    // A form word followed by a linear card's tail is a node
                    // (a source on F and H): ngspice-44.2 reads `E1 o 0 vcr 0
                    // 2` as v(vcr) times 2, and `vol 0 2` too. `value` and
                    // `table` are keywords wherever they stand (inpcom.c
                    // search_plain_identifier).
                    const anywhere = std.ascii.eqlIgnoreCase(t, "value") or std.ascii.eqlIgnoreCase(t, "table");
                    if (!anywhere and linearTail(probe, controls - 1, true)) break :keyword;
                    if (form == .kind) return r.unsupported(line, "a controlled-source type word on a card ngspice does not read as linear");
                    return r.behaviouralCard(line, head, letter, f, frame, form);
                };
                // SPICE 2G6 lets a one-dimensional POLY drop its `POLY(1)`:
                // ngspice inserts it when a linear card's gain is followed
                // by more (inpcom.c inp_poly_2g6_compat), so `E1 o 0 a 0 2
                // 3` is 2 + 3·v(a).
                switch (polyTail(fourth, controls)) {
                    .linear => {},
                    .poly => return r.readDevice(try std.mem.concat(r.arena, u8, &.{ line[0..at], " poly(1)", line[at..] }), frame, null),
                    .dropped => return r.unsupported(line, "a number after a linear E, F, G or H card's m=, or after its gain when its first control starts with poly, value, vol, table, laplace, cur, vccs, vcvs, ccvs or cccs: ngspice reads no POLY(1) there and stops on it (\"unknown parameter\")"),
                }
            }
            r.nodes.clearRetainingCapacity();
            r.positional.clearRetainingCapacity();
            r.card_kv.clearRetainingCapacity();
            var kv_text: std.ArrayList([]const u8) = .empty;
            // An X card expands and a top-level card is read once: neither
            // replays.
            // ponytail: a positional literal (`R1 a b 1k`) is re-read too.
            const slot: ?usize = if (letter == 'x' or frame.sub == null) null else row;
            var fields: std.ArrayList(ReplayField) = .empty;

            const model_word = try R.cardNodes(arena, &f, letter, &r.nodes);
            if (model_word) |model| {
                if (letter != 'x') try r.refuseOperatorField(line, model);
                try r.positional.append(arena, try r.nameValue(model, frame, false));
            } else if (letter == 'b') {
                const out = f.next() orelse return error.ParseError;
                const eq = f.next() orelse return error.ParseError;
                if (!F.isWord(out) or eq[0] != '=') return error.ParseError;
                // ngspice's B card has v= and i= alone: q= is "unknown
                // parameter (q)" there, a charge being a C card's q=.
                if (!std.mem.eql(u8, out, "v") and !std.mem.eql(u8, out, "i"))
                    return r.unsupported(line, "a B source output other than v= or i=: ngspice reads q= as an unknown parameter; a charge is a C card's q={...}");
                const value = v: {
                    r.bsource = true;
                    defer r.bsource = false;
                    break :v try r.exprValue(try r.exprRest(&f, frame), frame, false);
                };
                try r.card_kv.append(arena, .{ .key = out, .value = value });
                // A braced expression may be followed by instance
                // parameters (`i={...} tc1=1m reciproctc=1`).
                while (f.next()) |t| {
                    if (!F.isWord(t) or !f.takeEq()) return error.ParseError;
                    try r.card_kv.append(arena, .{ .key = t, .value = try r.kvValue(&f, frame, false) });
                }
                return r.commit(head, letter, frame);
            }

            try R.readFields(false, r, arena, line, letter, &f, frame, if (slot != null) &fields else null, &kv_text);
            if (letter == 'x') return r.expand(head, frame, kv_text.items);
            if (slot) |i| {
                const rp = try arena.create(Replay);
                rp.* = .{ .nodes = try arena.dupe([]const u8, r.nodes.items), .model = model_word, .fields = fields.items };
                r.replays[i] = rp;
            }
            // A D card's third node is its thermal node `tj` when a model
            // name follows it (ngspice-syntax.md §3.2, #121).
            if (letter == 'q' or letter == 'm' or letter == 'd') try r.splitTerminals();
            return r.commit(head, letter, frame);
        }

        pub fn isModel(r: *const R, name: []const u8) bool {
            return r.model_ids.contains(name) or r.local_names.contains(name);
        }

        /// Q cards carry 3-5 terminals and M cards 3-7 against the fixed 3
        /// and 4 read, so the model name can land on either side of the
        /// node/positional split. Moves it to positional[0].
        pub fn splitTerminals(r: *R) Error!void {
            const nodes = &r.nodes;
            const pos = &r.positional;
            // Too few terminals: the model name was read as the last node.
            if (nodes.items.len > 0 and (pos.items.len == 0 or switch (pos.items[0]) {
                .name => |n| !r.isModel(n),
                else => true,
            })) {
                const last = nodes.items[nodes.items.len - 1];
                if (r.isModel(last)) {
                    _ = nodes.pop();
                    pos.shrinkRetainingCapacity(@min(pos.items.len, 3));
                    try pos.insert(r.arena, 0, .{ .name = last });
                    return;
                }
            }
            // Too many: extra terminals spilled into positional before the model.
            var model_at: ?usize = null;
            for (pos.items, 0..) |p, i| switch (p) {
                .name => |n| if (r.isModel(n)) {
                    model_at = i;
                },
                else => {},
            };
            const mi = model_at orelse return;
            if (mi == 0 or nodes.items.len + mi > 8 or pos.items.len - mi > 4) return;
            for (pos.items[0..mi]) |p| switch (p) {
                .name, .num => {},
                else => return,
            };
            for (pos.items[0..mi]) |p| try nodes.append(r.arena, switch (p) {
                .name => |n| n,
                .num => |v| try r.arena.print("{d}", .{v}),
                else => unreachable,
            });
            try pos.replaceRange(r.arena, 0, mi, &.{});
        }

        pub fn commit(r: *R, head: []const u8, letter: u8, frame: *const Frame) Error!void {
            const arena = r.arena;
            try r.pins.resize(arena, r.nodes.items.len);
            for (r.nodes.items, r.pins.items) |n, *pin| pin.* = try r.netOf(frame, n);
            // A behavioural E/F/G/H is built as a B card but keeps its own
            // letter in a flattened name, which is what its i() probes use.
            const name_letter = if (letter == 'b') std.ascii.toLower(head[0]) else letter;
            // An enclosing X card's m (`Frame.mult`) multiplies the card's
            // own, as HSPICE does; ngspice overwrites it there outside its
            // HSPICE mode (inpcom.c:4272-4300). The letters and the v= B
            // ngspice gives no m are left alone (inpcom.c:4253-4271).
            if (frame.mult != 1) multiply: {
                if (std.mem.indexOfScalar(u8, "rclgfibdqjzm", name_letter) == null) break :multiply;
                var v_out = false;
                if (letter == 'b') for (r.card_kv.items) |item| {
                    if (item.key.len == 1 and std.mem.indexOfScalar(u8, "viq", item.key[0]) != null) v_out = item.key[0] == 'v';
                };
                if (v_out) break :multiply;
                for (r.card_kv.items) |*item| if (std.mem.eql(u8, item.key, "m")) {
                    const own = item.value.number() orelse return r.unsupported(r.card, "m= that is not a number inside an X card with m=");
                    item.value = .{ .num = own * frame.mult };
                    break :multiply;
                };
                try r.card_kv.append(arena, .{ .key = "m", .value = .{ .num = frame.mult } });
            }
            // F, H and W name a V card, K two L cards: inside a subcircuit,
            // the instance's own, flattened as those cards' names are
            // (subckt.c:1422-1436, 1475-1486).
            if (frame.path) |path| if (std.mem.indexOfScalar(u8, "fhwk", letter) != null) {
                const refs: usize = if (letter == 'k') 2 else 1;
                const target: []const u8 = if (letter == 'k') "l" else "v";
                // In the arena: the card keeps the name, and `joined`'s
                // scratch is the next name's.
                for (r.positional.items[0..@min(refs, r.positional.items.len)]) |*p| if (p.* == .name) {
                    p.* = .{ .name = try std.mem.concat(r.arena, u8, &.{ target, ".", path, ".", p.name }) };
                };
            };
            const positional = try appendSpan(Value, arena, &r.values, r.positional.items);
            const kv = try appendSpan(Kv, arena, &r.kvs, r.card_kv.items);
            // After the spans: reading an instance model reuses the card scratch.
            // An R, C or L card may name its model after its value
            // (`R1 a b 1k rmod`, ngspice INP2R/INP2C/INP2L).
            const pv = r.positional.items;
            const model_at: ?usize = if (pv.len > 0 and pv[0] == .name) 0 else if (std.mem.indexOfScalar(u8, "rcl", letter) != null and pv.len > 1 and pv[0] == .num and pv[1] == .name) 1 else null;
            const model: u32 = if (model_at) |k| try r.modelRow(letter, pv[k].name, positional.start, frame) else none;
            const name = try r.internName(if (frame.path) |path| try r.joined(&[_][]const u8{ &.{name_letter}, ".", path, ".", head }) else head);
            _ = r.hg.addEdge(arena, .{
                .kind = letter,
                .name = name,
                .model = model,
                .positional = positional,
                .kv = kv,
                .subckt_instance = frame.instance,
            }, r.pins.items) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CircuitTooLarge,
            };
        }

        /// `.options gshunt=G cshunt=C` [CR Ch.3] and ngspice's `rshunt=R`:
        /// a conductance, capacitance or resistance from every net to
        /// ground, added as R and C cards named `r.gshunt.<net>`,
        /// `c.cshunt.<net>` and `r.rshunt.<net>`.
        pub fn shunts(r: *R) Error!void {
            const nets = r.hg.vertices.len;
            inline for (.{ .{ "gshunt", 'r' }, .{ "cshunt", 'c' }, .{ "rshunt", 'r' } }) |s| if (r.option(s[0])) |v| if (v > 0) {
                for (1..nets) |net| {
                    const value: Value = .{ .num = if (comptime std.mem.eql(u8, s[0], "gshunt")) 1 / v else v };
                    const pins = [2]VertexId{ .from(net), ground };
                    const net_name = r.pool.str(r.hg.vertices.items(.name)[net]);
                    const name = try r.internName(try r.arena.print("{c}.{s}.{s}", .{ s[1], s[0], net_name }));
                    _ = r.hg.addEdge(r.arena, .{
                        .kind = s[1],
                        .name = name,
                        .model = none,
                        .positional = try appendSpan(Value, r.arena, &r.values, &.{value}),
                        .kv = .{},
                        .subckt_instance = 0,
                    }, &pins) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.CircuitTooLarge,
                    };
                }
            };
        }

        /// The last `.options name=value` number in the deck, null when none
        /// sets it.
        pub fn option(r: *const R, name: []const u8) ?f64 {
            var out: ?f64 = null;
            for (r.config.items) |c| if (!c.temp) for (c.args, 0..) |a, i| {
                if (a == .name and std.ascii.eqlIgnoreCase(a.name, name) and i + 1 < c.args.len and c.args[i + 1] == .num) out = c.args[i + 1].num;
            };
            return out;
        }

        /// `.option scale` and `wnflag`, which bin selection reads.
        pub fn binOptions(r: *R) Error!void {
            r.wnflag = false;
            for (r.config.items) |c| {
                if (c.temp) continue;
                for (c.args, 0..) |arg, i| {
                    if (arg != .name) continue;
                    const is_scale = std.mem.eql(u8, arg.name, "scale");
                    if (!is_scale and !std.mem.eql(u8, arg.name, "wnflag")) continue;
                    if (i + 1 == c.args.len or c.args[i + 1] != .num) return error.ParseError;
                    if (is_scale) r.scale = c.args[i + 1].num else r.wnflag = c.args[i + 1].num != 0;
                }
            }
            if (!(r.scale > 0) or !std.math.isFinite(r.scale)) return error.ParseError;
        }

        /// `.option scale` and ngspice model binning (INPgetModBin): an M card
        /// naming `nm` takes the last-declared global `nm.<n>` whose L/W
        /// bounds hold it, within 1 nm. `modelRow` already binned the cards
        /// that name a subcircuit's own bins. Writes the factor each live
        /// slot of `slots` takes into `slot_scale`, parallel to it.
        pub fn modelBins(r: *R, slots: []const Live.Slot, slot_scale: []f64) Error!void {
            std.debug.assert(slots.len == slot_scale.len);
            const scale = r.scale;
            const wnflag = r.wnflag;
            const arena = r.arena;
            // Slot of each `kvs` row, `none` where it holds none, for the
            // scale and the bin check; empty when the deck has no slot.
            const slot_of = try arena.alloc(u32, if (slots.len == 0) 0 else r.kvs.items.len);
            @memset(slot_of, none);
            for (slots, 0..) |slot, k| if (slot.table == .kvs) {
                slot_of[slot.row] = @intCast(k);
            };
            const models = r.models.items;
            const kvs = r.kvs.items;
            var names: std.StringHashMapUnmanaged(u32) = .empty;
            const next = try arena.alloc(u32, models.len);
            @memset(next, none);
            const bounds = try arena.alloc([4]f64, models.len);
            // Global rows only: a subcircuit's models are its own.
            for (models, 0..) |m, i| if (r.model_ids.contains(m.name)) try names.put(arena, m.name, @intCast(i));
            for (models, 0..) |m, mi| {
                if (!r.model_ids.contains(m.name)) continue;
                const dot = std.mem.lastIndexOfScalar(u8, m.name, '.') orelse continue;
                _ = std.fmt.parseInt(u32, m.name[dot + 1 ..], 10) catch continue;
                bounds[mi] = binBounds(kvs[m.kv.start..][0..m.kv.len]) orelse continue;
                const entry = try names.getOrPut(arena, m.name[0..dot]);
                if (entry.found_existing) {
                    if (std.mem.eql(u8, models[entry.value_ptr.*].name, m.name[0..dot])) continue;
                    next[mi] = entry.value_ptr.*;
                }
                entry.value_ptr.* = @intCast(mi);
            }
            const lengths = std.StaticStringMap(u2).initComptime(.{
                .{ "l", 1 },  .{ "w", 1 },  .{ "pd", 1 }, .{ "ps", 1 }, .{ "sa", 1 }, .{ "sb", 1 }, .{ "sd", 1 },
                .{ "ad", 2 }, .{ "as", 2 },
            });
            const edges = r.hg.edges.slice();
            for (edges.items(.kind), edges.items(.positional), edges.items(.kv), edges.items(.model), 0..) |kind, ps, ks, *model, ei| {
                if (kind != 'm') continue;
                const kv = r.kvs.items[ks.start..][0..ks.len];
                var swept_geometry = false;
                for (kv, @as(usize, ks.start)..) |*item, row| {
                    const power = lengths.get(item.key) orelse continue;
                    if (item.value != .num) return error.ParseError;
                    const factor = if (power == 2) scale * scale else scale;
                    if (slot_of.len != 0 and slot_of[row] != none) {
                        const k = slot_of[row];
                        slot_scale[k] = factor;
                        swept_geometry = swept_geometry or std.mem.eql(u8, item.key, "l") or std.mem.eql(u8, item.key, "w");
                    }
                    if (scale != 1) item.value.num *= factor;
                }
                if (ps.len == 0) continue;
                const first = &r.values.items[ps.start];
                if (first.* != .name) continue;
                var bin = names.get(first.name) orelse continue;
                if (std.mem.eql(u8, first.name, models[bin].name)) continue;
                const l = kvNumber(kv, "l") orelse return error.ParseError;
                const use_nf = if (kvNumber(kv, "wnflag")) |flag| flag != 0 else wnflag;
                const nf = if (use_nf) kvNumber(kv, "nf") orelse 1 else 1;
                const w = (kvNumber(kv, "w") orelse return error.ParseError) / nf;
                // A swept or sampled l/w: every bin is a candidate a point
                // may pick (`Live.bins`).
                if (swept_geometry) {
                    var c = bin;
                    while (c != none) : (c = next[c]) {
                        try r.bin_rows.append(arena, r.model_ids.get(models[c].name) orelse none);
                        try r.bin_bounds.append(arena, bounds[c]);
                    }
                    try r.closeBins(@intCast(ei), use_nf);
                }
                while (bin != none) : (bin = next[bin]) {
                    if (binHolds(bounds[bin], l, w)) {
                        first.* = .{ .name = models[bin].name };
                        model.* = r.model_ids.get(models[bin].name) orelse none;
                        break;
                    }
                }
                if (bin == none) return error.ModelBinNotFound;
            }
        }

        // ---- private ----

        /// A W RLGC line or S N-port card (`card_table.isDataElement`):
        /// nodes and `key=value` pairs in any order (`W1 N=3 1 3 5 0 2 4 6
        /// 0 RLGCMODEL=m L=0.97`). A file key's value is the raw path in
        /// the deck's own case.
        fn readDataElement(r: *R, head: []const u8, letter: u8, f: *F, frame: *const Frame) Error!void {
            r.nodes.clearRetainingCapacity();
            r.positional.clearRetainingCapacity();
            r.card_kv.clearRetainingCapacity();
            while (f.next()) |t| {
                if (t[0] == ',') continue;
                if (!F.isWord(t)) return error.ParseError;
                if (!f.takeEq()) {
                    try r.nodes.append(r.arena, t);
                } else if (card_table.data_file_keys.has(t)) {
                    try r.card_kv.append(r.arena, .{ .key = t, .value = .{ .name = try r.dataPath(f) } });
                } else {
                    try r.card_kv.append(r.arena, .{ .key = t, .value = try r.kvValue(f, frame, false) });
                }
            }
            return r.commit(head, letter, frame);
        }

        /// True when `f` holds `names` words, a gain and nothing more, or
        /// only `m=` pairs more when `m_ok`: a linear E, F, G or H card's
        /// tail. ngspice-44.2 reads `G1 0 o vcr 0 2m m=2` as linear, and
        /// `E1 o 0 delay a 0 td=1n` as no linear card.
        fn linearTail(f: F, names: u8, m_ok: bool) bool {
            var g = f;
            for (0..names) |_| {
                const n = g.next() orelse return false;
                if (!F.isWord(n) or g.nextByte() == '=') return false;
            }
            const gain = g.next() orelse return false;
            if (std.mem.indexOfScalar(u8, "=(),", gain[0]) != null or g.nextByte() == '=') return false;
            while (g.next()) |k| {
                if (!m_ok or !std.mem.eql(u8, k, "m") or !g.takeEq()) return false;
                const v = g.next() orelse return false;
                if (std.mem.indexOfScalar(u8, "=(),", v[0]) != null) return false;
            }
            return true;
        }

        /// What ngspice-44.2 reads after the gain of a linear E, F, G or H
        /// card, `f` at its first control (inpcom.c inp_poly_2g6_compat):
        /// nothing, or `m=` or `ic=` and more pairs, is `.linear`; anything
        /// else makes the numbers from the gain on SPICE 2G6 POLY(1)
        /// coefficients (`.poly`), unless the first control starts like a
        /// form word (ciprefix): there, and after `m=`, a number is one
        /// ngspice stops on (`.dropped`). `(`, `)` and `,` separate, as
        /// ngspice reads them in POLY.
        fn polyTail(f: F, controls: u8) enum { linear, poly, dropped } {
            const poly_free = [_][]const u8{ "poly", "value", "vol", "table", "laplace", "cur", "vccs", "vcvs", "ccvs", "cccs" };
            var g = f;
            const first = R.word(&g) catch return .linear;
            for (1..controls) |_| _ = R.word(&g) catch return .linear;
            const plain = for (poly_free) |p| {
                if (std.ascii.startsWithIgnoreCase(first, p)) break false;
            } else true;
            var gain = false;
            var pairs = false;
            while (g.next()) |k| {
                if (k[0] == ',' or k[0] == '(' or k[0] == ')') continue;
                const pair = F.isWord(k) and g.takeEq();
                if (pair) _ = g.next();
                if (!gain) {
                    if (pair) return .linear;
                    gain = true;
                    continue;
                }
                const linear_key = pair and (std.ascii.eqlIgnoreCase(k, "m") or std.ascii.eqlIgnoreCase(k, "ic"));
                if (!pairs and plain and !linear_key) return .poly;
                if (!pair) return .dropped;
                pairs = true;
            }
            return .linear;
        }
    };
}
