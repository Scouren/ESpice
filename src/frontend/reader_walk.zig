//! Walk 1, declarations: subcircuit ranges, `.if` chains, `.func`, `.param`, `.model`
//! and directive lines, read before any device.
//! Cites: ngspice inp.c recifeval (`.if`), dev/research/ngspice-syntax.md §2.5, §4.1.
//!
//! Contents:
//! - `pub fn Methods(comptime S: type) type`
//! - `pub fn declarations(r: *R, top: *std.ArrayList(u32), models: *std.ArrayList(ModelLine), directives: *std.ArrayList(u32)) Error!void`
//! - `pub fn branch(r: *R, b: *Branches, card: CondCard, f: *F, frame: *const Frame) Error!void`
//! - `pub fn condition(r: *R, f: *F, frame: *const Frame) Error!bool`
//! - `pub fn pathOf(r: *R, f: *F) Error![]const u8`
//! - `pub fn readFunc(r: *R, f: *F, eq: bool) Error!void`
//! - `pub fn paramText(r: *R, f: *F) Error![]const u8`

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
const card_table = @import("card_table.zig");
const reader_frame = @import("reader_frame.zig");
const Error = card_rows.Error;
const ForeignKind = card_rows.ForeignKind;
const Card = card_table.Card;
const CondCard = card_table.CondCard;
const Branches = card_table.Branches;
const cardOf = card_table.cardOf;
const Frame = reader_frame.Frame;
const Scope = reader_frame.Scope;
const PortIndex = reader_frame.PortIndex;
const port_scan_max = reader_frame.port_scan_max;
const subckt_depth_max = reader_frame.subckt_depth_max;
const Subckt = reader_frame.Subckt;
const ModelLine = reader_frame.ModelLine;
const top_level = reader_frame.top_level;

/// The stage's `Reader` methods over dialect syntax `S`; `Reader(S)`
/// aliases each one as its own decl.
pub fn Methods(comptime S: type) type {
    const F = S.Split;
    return struct {
        const R = reader.Reader(S);

        pub fn declarations(r: *R, top: *std.ArrayList(u32), models: *std.ArrayList(ModelLine), directives: *std.ArrayList(u32)) Error!void {
            const arena = r.arena;
            // Open `.subckt` definitions, innermost last (§2.5, D1: they nest),
            // each with the defaults its header and `.param` lines give.
            const Open = struct { id: u16, defaults: std.ArrayList(Default) = .empty, ifs: u8 = 0 };
            var opens: [subckt_depth_max]Open = undefined;
            var depth: usize = 0;
            // A top-level `.if` condition reads each parameter at its last
            // definition outside a conditional block, even one below it, as
            // ngspice-45 does (measured with `ngspice -n -b`, the oracle in
            // tests/netlist.zig). So an `.alter` block's `.param` (ESPice's
            // `.alter`) moves a branch. `globals` holds
            // that last text from the start and at each such card; a
            // block's `.param` writes its own.
            const last = try lastParams(r);
            for (last.keys(), last.values()) |key, entry| try r.globals.put(arena, key, entry);
            // Conditions inside a subcircuit are left to `expand`, per instance;
            // `sub_ifs` counts the open ones so a `.model` there is marked.
            // ponytail: a `.param` under a subcircuit's `.if` applies
            // unconditionally; scope it when a PDK needs it.
            var branches: Branches = .{};
            const global: Frame = .{ .scopes = &r.global_scopes };
            // An open `.data` or `.variation` block: its closing card and first line.
            var block: ?struct { close: Card, first: u32 } = null;
            // Inside `.control`/`.endc`: ngspice's interpreter. Only the
            // model loads matter to a batch run; the rest is skipped aloud.
            var control = false;
            for (r.lines.items, 0..) |line, index| {
                const i: u32 = @intCast(index);
                r.card = line;
                if (control) {
                    var cf = F.init(line);
                    const head = cf.next().?;
                    if (std.ascii.eqlIgnoreCase(head, ".endc")) {
                        control = false;
                    } else if (std.ascii.eqlIgnoreCase(head, "pre_osdi") or std.ascii.eqlIgnoreCase(head, "osdi")) {
                        if (branches.active()) try r.foreign.append(arena, .{ .kind = .pre_osdi, .path = try r.pathOf(&cf) });
                    } else if (!@import("builtin").is_test) std.log.warn("netlist: .control command '{s}' ignored", .{head});
                    continue;
                }
                if (block) |b| {
                    if (line[0] != '.') continue;
                    var bf = F.init(line);
                    const c = cardOf(bf.next().?[1..]) orelse continue;
                    if (std.meta.activeTag(c) != std.meta.activeTag(b.close)) continue;
                    if (depth == 0 and branches.active()) try r.blocks.append(arena, .{ b.first, i });
                    block = null;
                    continue;
                }
                const live = depth > 0 or branches.active();
                if (line[0] != '.') {
                    if (depth == 0 and live) try top.append(arena, i);
                    continue;
                }
                var f = F.init(line);
                const head = f.next().?;
                if (head.len < 2) return error.ParseError;
                const card = cardOf(head[1..]) orelse {
                    if (live) try directives.append(arena, i);
                    continue;
                };
                if (card == .cond) {
                    if (depth > 0) {
                        const o = &opens[depth - 1];
                        r.subckts.items[o.id].has_cond = true;
                        switch (card.cond) {
                            .@"if" => o.ifs +|= 1,
                            .endif => o.ifs -|= 1,
                            else => {},
                        }
                    } else try r.branch(&branches, card.cond, &f, &global);
                    continue;
                }
                if (card == .control) {
                    control = true;
                    continue;
                }
                if (card == .data or card == .variation) {
                    block = .{ .close = if (card == .data) .enddata else .end_variation, .first = i };
                    continue;
                }
                if (!live) continue;
                switch (card) {
                    // ngspice turns `.end` into a comment and reads on, so a
                    // card after it still counts (ngspice-syntax.md §1.7).
                    .end => {},
                    .ends => {
                        if (depth == 0) return error.ParseError;
                        depth -= 1;
                        const o = opens[depth];
                        r.subckts.items[o.id].end = i;
                        r.subckts.items[o.id].defaults = o.defaults.items;
                    },
                    .subckt => {
                        if (depth == subckt_depth_max) return error.ParseError;
                        const name = f.next() orelse return error.ParseError;
                        var ports: std.ArrayList([]const u8) = .empty;
                        var defaults: @FieldType(Open, "defaults") = .empty;
                        while (f.next()) |t| {
                            if (t[0] == '(' or t[0] == ')') continue;
                            if (!F.isWord(t)) return error.ParseError;
                            if (std.mem.eql(u8, t, "params:")) continue;
                            if (f.takeEq())
                                try defaults.append(arena, .{ .key = t, .text = try r.paramText(&f) })
                            else
                                try ports.append(arena, t);
                        }
                        if (!F.isWord(name)) return error.ParseError;
                        if (r.subckts.items.len == top_level) return error.CircuitTooLarge;
                        if (depth > 0) r.subckts.items[opens[depth - 1].id].has_nested = true;
                        const id: u16 = @intCast(r.subckts.items.len);
                        opens[depth] = .{ .id = id, .defaults = defaults };
                        depth += 1;
                        var port_index: ?*const PortIndex = null;
                        if (ports.items.len > port_scan_max) {
                            const by_name = try arena.create(PortIndex);
                            by_name.* = .empty;
                            try by_name.ensureTotalCapacity(arena, @intCast(ports.items.len));
                            // A repeated port keeps its first position, as the scan finds it.
                            for (ports.items, 0..) |port, k| {
                                const got = by_name.getOrPutAssumeCapacity(port);
                                if (!got.found_existing) got.value_ptr.* = @intCast(k);
                            }
                            port_index = by_name;
                        }
                        try r.subckts.append(arena, .{ .name = name, .ports = ports.items, .defaults = &.{}, .first = i + 1, .end = i + 1, .port_index = port_index });
                        try r.subckt_ids.put(arena, name, id);
                    },
                    // A block's close outside its block closes nothing (#162).
                    .enddata, .end_variation => return r.failed(line, error.ParseError),
                    // A subcircuit holds devices, models and parameters; an
                    // analysis there is no part of it (§2.4.3) (#165).
                    .analysis => if (depth > 0) return r.unsupported(line, "analysis card inside a subcircuit") else try directives.append(arena, i),
                    .func => try r.readFunc(&f, false),
                    .param => while (try nextParam(r, &f)) |p| {
                        if (depth > 0) {
                            try opens[depth - 1].defaults.append(arena, p);
                            continue;
                        }
                        const kept = if (branches.depth == 0) last.get(p.key) else null;
                        try r.globals.put(arena, p.key, kept orelse .{ .text = p.text });
                        try r.global_keys.append(arena, p.key);
                    },
                    .model => try models.append(arena, if (depth > 0)
                        .{ .line = i, .cond = opens[depth - 1].ifs > 0, .owner = opens[depth - 1].id }
                    else
                        .{ .line = i, .cond = false }),
                    .include, .osdi_include, .pre_osdi, .verilog => {
                        const path = try r.pathOf(&f);
                        const kind: ForeignKind = switch (card) {
                            .osdi_include => .osdi_include,
                            .pre_osdi => .pre_osdi,
                            .verilog => .verilog,
                            else => source.foreignKindForPath(path) orelse continue,
                        };
                        try r.foreign.append(arena, .{ .kind = kind, .path = path });
                    },
                    else => try directives.append(arena, i),
                }
            }
            if (depth != 0 or branches.depth != 0 or block != null or control) return error.ParseError;
        }

        /// Applies one `.if`/`.elseif`/`.else`/`.endif` card to `b`. A
        /// condition is the rest of the line, evaluated under `frame` only
        /// when its branch could still be taken; nonzero is true.
        pub fn branch(r: *R, b: *Branches, card: CondCard, f: *F, frame: *const Frame) Error!void {
            if (card == .@"if") {
                if (b.depth == Branches.max) return error.ParseError;
                b.open[b.depth] = if (!b.active()) .spent else if (try r.condition(f, frame)) .live else .pending;
                b.depth += 1;
                return;
            }
            if (b.depth == 0) return error.ParseError;
            const top = &b.open[b.depth - 1];
            switch (card) {
                .@"if" => unreachable,
                .elseif => top.* = if (top.* != .pending) .spent else if (try r.condition(f, frame)) .live else .pending,
                .@"else" => top.* = if (top.* == .pending) .live else .spent,
                .endif => b.depth -= 1,
            }
        }

        pub fn condition(r: *R, f: *F, frame: *const Frame) Error!bool {
            const was_in_card = r.in_card;
            r.in_card = false;
            defer r.in_card = was_in_card;
            if (frame.sub == null) try r.cond_texts.append(r.arena, f.rest());
            const text = try loneEqualsDoubled(r.arena, f.rest());
            return switch (try r.exprValue(text, frame, false)) {
                .num => |n| n != 0,
                else => error.ParseError,
            };
        }

        /// A quoted or bare path; its original case survives case folding.
        pub fn pathOf(r: *R, f: *F) Error![]const u8 {
            const t = f.next() orelse return error.ParseError;
            var path = t;
            if (F.isQuote(t[0])) {
                path = F.body(t);
            } else if (!F.isWord(t)) {
                return error.ParseError;
            } else if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) {
                path = t[1 .. t.len - 1];
            }
            return r.written(path);
        }

        /// `name(a, b) [=] body`: a user function, from `.func` or from
        /// `.param` (`eq` set: its `=` is required). ngspice expands it as
        /// a textual macro wherever it is called (ngspice-syntax.md §2.4).
        // ponytail: functions are global even when defined in a subcircuit;
        // scope them when a deck reuses a name per subcircuit.
        pub fn readFunc(r: *R, f: *F, eq: bool) Error!void {
            const name = f.next() orelse return error.ParseError;
            if (!F.isWord(name)) return error.ParseError;
            if ((f.next() orelse return error.ParseError)[0] != '(') return error.ParseError;
            var formals: std.ArrayList([]const u8) = .empty;
            while (true) {
                const t = f.next() orelse return error.ParseError;
                if (t[0] == ')') break;
                if (t[0] == ',') continue;
                if (!F.isWord(t)) return error.ParseError;
                try formals.append(r.arena, t);
            }
            if (f.takeEq()) {} else if (eq) return error.ParseError;
            try r.funcs.put(r.arena, name, .{ .formals = formals.items, .body = try r.paramText(f) });
        }

        /// The text a parameter definition is re-read from on every use.
        pub fn paramText(r: *R, f: *F) Error![]const u8 {
            const rest = f.rest();
            if (rest.len == 0) return error.ParseError;
            if ((rest[0] == '{' and !F.isWord(rest)) or rest[0] == '\'') {
                const t = f.next().?;
                return if (!F.isWord(t)) F.body(t) else t;
            }
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            const start = f.pos;
            f.pos = try expr.compile(S, r.arena, &r.scratch, f.line, f.pos);
            return f.line[start..f.pos];
        }

        // ---- private ----

        /// One `key=text` definition of a `.param` card.
        const Default = @typeInfo(@FieldType(Subckt, "defaults")).pointer.child;

        /// The next definition on `.param` card `f`, reading each
        /// `f(x)=body` before it as a function (§2.3, X4); null at its end.
        fn nextParam(r: *R, f: *F) Error!?Default {
            while (true) {
                const at = f.pos;
                const key = f.next() orelse return null;
                if (!F.isWord(key)) return error.ParseError;
                if (f.nextByte() == '(') {
                    f.pos = at;
                    try r.readFunc(f, true);
                    continue;
                }
                const eq = f.next() orelse return error.ParseError;
                if (eq[0] != '=') return error.ParseError;
                return .{ .key = key, .text = try r.paramText(f) };
            }
        }

        /// The last definition of each top-level `.param` outside an
        /// `.if` block, as `declarations` walks the lines: past `.data`,
        /// `.variation` and `.control` bodies.
        fn lastParams(r: *R) Error!Scope {
            var last: Scope = .empty;
            var subs: usize = 0;
            var ifs: usize = 0;
            var body = false;
            var control = false;
            for (r.lines.items) |line| {
                if (line[0] != '.') continue;
                r.card = line;
                var f = F.init(line);
                const head = f.next().?;
                if (control) {
                    control = !std.ascii.eqlIgnoreCase(head, ".endc");
                    continue;
                }
                if (head.len < 2) continue;
                switch (cardOf(head[1..]) orelse continue) {
                    .subckt => subs += 1,
                    .ends => subs -|= 1,
                    .cond => |c| switch (c) {
                        .@"if" => ifs += 1,
                        .endif => ifs -|= 1,
                        .elseif, .@"else" => {},
                    },
                    .data, .variation => body = true,
                    .enddata, .end_variation => body = false,
                    .control => control = true,
                    .param => if (subs == 0 and ifs == 0 and !body) while (try nextParam(r, &f)) |p| {
                        try last.put(r.arena, p.key, .{ .text = p.text });
                    },
                    else => {},
                }
            }
            return last;
        }
    };
}

// ---- private ----

/// `text` with each lone `=` doubled: numparam reads `=` and `==` as one
/// equality operator (xpressn.c:709-710, 728-730, 819), and `.if
/// (select2 = 2)` is an ngspice condition.
fn loneEqualsDoubled(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '=') == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(arena, 2 * text.len);
    for (text, 0..) |c, i| {
        out.appendAssumeCapacity(c);
        const paired = (i > 0 and std.mem.indexOfScalar(u8, "=<>!", text[i - 1]) != null) or
            (i + 1 < text.len and text[i + 1] == '=');
        if (c == '=' and !paired) out.appendAssumeCapacity('=');
    }
    return out.items;
}
