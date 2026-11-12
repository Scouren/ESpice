//! Directive cards: analyses, `.options`, `.ic`, `.save`, `.probe`, `.step`,
//! `.wcd`, `.mosra`, `.sample`, and the global `.param` fold.
//! Cites: ngspice inp.c, inpc_probe.c; HSPICE [CR] .SAMPLE, .MOSRA, [SA]
//! Ch.29; #236-#240.
//!
//! Contents:
//! - `pub fn Methods(comptime S: type) type`
//! - `pub fn readArgs(r: *R, f: *F) Error![]const Value`
//! - `pub fn cutFail(r: *R, line: []const u8, f: *F) Error![]const u8`
//! - `pub fn readFileOptions(r: *R, line: []const u8) Error!void`
//! - `pub fn isStep(line: []const u8) bool`
//! - `pub fn isWcd(line: []const u8) bool`
//! - `pub fn readDirective(r: *R, line: []const u8) Error!void`
//! - `pub fn readMosra(r: *R, line: []const u8, args: []const Value) Error!Mosra`
//! - `pub fn readSample(args: []const Value) Error!core.query.NoiseSample`
//! - `pub fn written(r: *const R, line: []const u8) []const u8`
//! - `pub fn failed(r: *R, line: []const u8, err: Error) Error`
//! - `pub fn liveParam(r: *R, name: []const u8) Error!?u32`
//! - `pub fn foldGlobals(r: *R) Error!void`
//! - `pub fn stepTarget(r: *R, name: []const u8) Error!StepTarget`
//! - `pub fn readStep(r: *R, args: []const Value) Error!Step`

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
const sweep_points = @import("sweep_points.zig");
const Error = card_rows.Error;
const Value = card_rows.Value;
const StepTarget = card_rows.StepTarget;
const Step = card_rows.Step;
const appendAnalysis = reader_frame.appendAnalysis;
const Mosra = card_rows.Mosra;
const cardOf = card_table.cardOf;
const isSn = card_table.isSn;
const nodeText = reader_frame.nodeText;
const isOpVar = netlist_view.isOpVar;
const Frame = reader_frame.Frame;
const setsKey = card_table.setsKey;
const Grid = sweep_points.Grid;
const grids = sweep_points.grids;
const points = sweep_points.points;

/// The stage's `Reader` methods over dialect syntax `S`; `Reader(S)`
/// aliases each one as its own decl.
pub fn Methods(comptime S: type) type {
    const F = S.Split;
    return struct {
        const R = reader.Reader(S);
        const max_trials = R.max_trials;

        pub fn readArgs(r: *R, f: *F) Error![]const Value {
            const top: Frame = .{ .scopes = &r.global_scopes };
            var args: std.ArrayList(Value) = .empty;
            while (f.next()) |t| {
                if (t[0] == ',' or t[0] == '=') continue;
                const last = if (args.items.len != 0) args.items[args.items.len - 1] else Value{ .num = 0 };
                if (last == .name and std.mem.eql(u8, last.name, "monte") and std.ascii.eqlIgnoreCase(t, "list")) {
                    // `MONTE=list(10 20:30)`, parentheses optional: the trial
                    // numbers follow `list`, each `a:b` range expanded.
                    try args.append(r.arena, .{ .name = "list" });
                    var trials: f64 = 0;
                    while (f.next()) |n| {
                        if (n[0] == ')') break;
                        if (n[0] == '(' or n[0] == ',') continue;
                        const colon = std.mem.indexOfScalar(u8, n, ':') orelse n.len;
                        const lo = S.parseNum(n[0..colon]) orelse return error.ParseError;
                        const hi = if (colon == n.len) lo else S.parseNum(n[colon + 1 ..]) orelse return error.ParseError;
                        if (!(lo >= 1 and hi >= lo and hi <= std.math.maxInt(u32)) or lo != @trunc(lo) or hi != @trunc(hi)) return error.ParseError;
                        trials += hi - lo + 1;
                        if (trials > max_trials) return error.ParseError;
                        var k = lo;
                        while (k <= hi) : (k += 1) try args.append(r.arena, .{ .num = k });
                    }
                    continue;
                }
                try args.append(r.arena, try r.valueAt(t, f, &top, false, false));
            }
            return args.items;
        }

        /// Cuts `fail='expr'` (quoted or braced) out of analysis card
        /// `line` and points `f`, past the card, at what is left; returns
        /// the expression's text, "" when no field is `fail=`.
        pub fn cutFail(r: *R, line: []const u8, f: *F) Error![]const u8 {
            var g = f.*;
            while (g.next()) |t| {
                if (!std.mem.eql(u8, t, "fail") or !g.takeEq()) continue;
                const v = g.next() orelse return r.failed(line, error.ParseError);
                if (!F.isQuote(v[0]) and !(v[0] == '{' and v[v.len - 1] == '}')) return r.failed(line, error.ParseError);
                const start = @intFromPtr(t.ptr) - @intFromPtr(line.ptr);
                const end = @intFromPtr(v.ptr) - @intFromPtr(line.ptr) + v.len;
                f.* = F.init(try std.mem.concat(r.arena, u8, &.{ line[0..start], " ", line[end..] }));
                _ = f.next(); // the card
                return F.body(v);
            }
            return "";
        }

        /// A `.options` card that names a file, path case kept: each
        /// `vpi="app.so"` (ESPice's, #197) a VPI application (LRM 12.33) for
        /// `vpi_apps`, `soalimits="file.json"` (#238) the SOA limits for
        /// `soa_file`, `emirfile="f"` (#237) the `--emir` file. The card's
        /// other options read as any `.options`.
        pub fn readFileOptions(r: *R, line: []const u8) Error!void {
            var f = F.init(line);
            _ = f.next(); // the card
            var rest: std.ArrayList(u8) = .empty;
            try rest.appendSlice(r.arena, ".options");
            while (f.next()) |t| {
                if (std.mem.eql(u8, t, "vpi") or std.mem.eql(u8, t, "soalimits") or std.mem.eql(u8, t, "emirfile")) {
                    const eq = f.next() orelse return r.failed(line, error.ParseError);
                    if (eq[0] != '=') return r.failed(line, error.ParseError);
                    const path = r.pathOf(&f) catch |err| return r.failed(line, err);
                    switch (t[0]) {
                        'v' => try r.vpi_apps.append(r.arena, path),
                        's' => r.soa_file = path,
                        else => r.emir_file = path,
                    }
                    continue;
                }
                try rest.append(r.arena, ' ');
                try rest.appendSlice(r.arena, t);
            }
            var g = F.init(rest.items);
            _ = g.next();
            const args = r.readArgs(&g) catch |err| return r.failed(line, err);
            try r.config.append(r.arena, .{ .temp = false, .args = args, .line = r.written(line) });
        }

        /// True for a `.step` directive line.
        pub fn isStep(line: []const u8) bool {
            var f = F.init(line);
            const c = cardOf(f.next().?[1..]) orelse return false;
            return c == .step;
        }

        /// True for a `.wcd` directive line.
        pub fn isWcd(line: []const u8) bool {
            var f = F.init(line);
            const c = cardOf(f.next().?[1..]) orelse return false;
            return c == .wcd;
        }

        pub fn readDirective(r: *R, line: []const u8) Error!void {
            r.card = line;
            var f = F.init(line);
            const card = cardOf(f.next().?[1..]);
            // Read after the walk (`readMeasures`).
            if (card != null and card.? == .meas) return r.meas_lines.append(r.arena, line);
            const c = card orelse return r.unsupported(line, "unsupported card");
            if (c == .wcd) {
                if (r.wcd_line != null) return r.unsupported(line, "a second .wcd card");
                r.wcd_line = line;
                return;
            }
            if (c == .ignored) {
                if (!std.ascii.startsWithIgnoreCase(line, ".probe")) return;
                return ngspiceProbe(r, line);
            }
            if (c == .save and isSaveOp(line)) return readSaveOp(r, line, &f);
            // HSPICE `.store` checkpoints the process on a wall-clock
            // schedule for an OS-level restore [CR .STORE]; the results do not
            // depend on it.
            if (c == .store) return std.log.warn("netlist: .store: checkpoints are not written; the run is not restartable", .{});
            if (c == .options and (setsKey(line, "vpi") or setsKey(line, "soalimits") or setsKey(line, "emirfile"))) return r.readFileOptions(line);
            // `FAIL='expr'` keeps its text: `readArgs` would fold it before
            // the `.meas` cards it names are read.
            const fail = if (c == .analysis and setsKey(line, "fail")) try r.cutFail(line, &f) else "";
            const args = r.readArgs(&f) catch |err| return r.failed(line, err);
            switch (c) {
                .step => try r.steps.append(r.arena, r.readStep(args) catch |err| return r.failed(line, err)),
                .analysis => |kind| {
                    // Every `.temp` card is configuration, never an analysis:
                    // analysis_options.zig folds the last one as ngspice 44.2
                    // does (measured). A temperature sweep is `.dc temp`.
                    if (kind == .temp) return r.config.append(r.arena, .{ .temp = true, .args = args, .line = r.written(line) });
                    var swept = r.readSweep(kind, args) catch |err| return r.failed(line, err);
                    const scaled = swept.sweep == .monte and swept.sweep.monte.scales.len != 0;
                    if (scaled != (fail.len != 0)) return r.unsupported(line, "SIGMA_SCALE= without FAIL=, or FAIL= without SIGMA_SCALE=");
                    if (scaled) {
                        if (kind != .tran and kind != .ac and kind != .dc) return r.unsupported(line, "SIGMA_SCALE on a card other than .tran, .ac or .dc");
                        // The lane ensemble (`.dc MONTE=n`) measures no trial.
                        if (kind == .dc and swept.args.len == 0) return r.unsupported(line, "SIGMA_SCALE on a .dc with no sweep of its own");
                        swept.sweep.monte.fail.text = fail;
                    }
                    try appendAnalysis(r.arena, &r.analyses, .{ .kind = kind, .args = swept.args, .sweep = swept.sweep, .line = r.written(line), .sn = isSn(line) });
                },
                .options => try r.config.append(r.arena, .{ .temp = false, .args = args, .line = r.written(line) }),
                .ic, .nodeset => {
                    // ngspice 44.2 reads `v(net)=value` pairs and `.nodeset
                    // all=value`; HSPICE's bare `net value` is its `.ic syntax
                    // error` (measured).
                    var i: usize = 0;
                    while (i < args.len) : (i += 2) if (args[i] != .group and !(c == .nodeset and std.ascii.eqlIgnoreCase(Value.nameAt(args, i) orelse "", "all")))
                        return r.failed(line, error.ParseError);
                    try (if (c == .ic) &r.ic_cards else &r.nodeset_cards).append(r.arena, args);
                },
                .sample => r.sample = readSample(args) catch |err| return r.failed(line, err),
                .mosra => r.mosra = try r.readMosra(line, args),
                .appendmodel => {
                    // `.appendmodel src mosra dst nmos`; HSPICE's other
                    // appended kinds (a second model card) are not modeled.
                    if (args.len != 4 or args[0] != .name or args[2] != .name or args[1] != .name or !std.mem.eql(u8, args[1].name, "mosra"))
                        return r.unsupported(line, ".appendmodel other than `src mosra dst type`");
                    try r.appendmodels.append(r.arena, .{ .src = args[0].name, .dst = args[2].name });
                },
                .global => for (args) |a| {
                    var buf: [24]u8 = undefined;
                    const name = nodeText(a, &buf) orelse return error.ParseError;
                    try r.global_nets.put(r.arena, try r.arena.dupe(u8, name), {});
                },
                .connect => {
                    if (args.len != 2) return error.ParseError;
                    // ponytail: top level only; a subcircuit's `.connect` needs
                    // per-instance aliases.
                    for (r.subckts.items) |s| for (r.lines.items[s.first..s.end]) |l| if (l.ptr == line.ptr)
                        return r.unsupported(line, ".connect inside a subcircuit");
                    var bufs: [2][24]u8 = undefined;
                    try r.connect(nodeText(args[0], &bufs[0]) orelse return error.ParseError, nodeText(args[1], &bufs[1]) orelse return error.ParseError);
                },
                .save => for (args) |a| try saveItem(r, line, a),
                else => {},
            }
        }

        /// HSPICE `.mosra k=v ...` [SA Ch.29]. Keys outside `Key` (DEC, LIN,
        /// AgingPeriod, AgingInst, ...) and SimMode 1 or 3 are refused.
        pub fn readMosra(r: *R, line: []const u8, args: []const Value) Error!Mosra {
            var m: Mosra = .{ .line = r.written(line) };
            var i: usize = 0;
            while (i + 1 < args.len) : (i += 2) {
                if (args[i] != .name or args[i + 1] != .num) return r.failed(line, error.ParseError);
                const v = args[i + 1].num;
                const Key = enum { reltotaltime, relstarttime, relstep, simmode, relmode, agingstart, agingstop, hcithreshold, nbtithreshold, degf };
                switch (std.meta.stringToEnum(Key, args[i].name) orelse return r.unsupported(line, ".mosra key other than RelTotalTime, RelStartTime, RelStep, SimMode, RelMode, AgingStart, AgingStop, HciThreshold, NbtiThreshold, DegF")) {
                    .reltotaltime => m.rel_total_time = v,
                    .relstarttime => m.rel_start_time = v,
                    .relstep => m.rel_step = v,
                    .simmode => m.aged_runs = if (v == 2) true else if (v == 0) false else return r.unsupported(line, ".mosra SimMode other than 0 or 2"),
                    .relmode => m.rel_mode = if (v == 0 or v == 1 or v == 2) @intFromFloat(v) else return r.failed(line, error.ParseError),
                    .agingstart => m.aging_start = v,
                    .agingstop => m.aging_stop = v,
                    .hcithreshold => m.hci_threshold = v,
                    .nbtithreshold => m.nbti_threshold = v,
                    .degf => m.deg_f = v,
                }
            }
            if (i != args.len or !(m.rel_total_time > 0) or !(m.rel_step >= 0) or !(m.rel_start_time >= 0) or !(m.aging_stop > m.aging_start))
                return r.failed(line, error.ParseError);
            return m;
        }

        /// HSPICE `.sample FS= [TOL=] [NUMF=] [MAXFLD=] [BETA=]` [CR .SAMPLE].
        /// TOL and NUMF size HSPICE's adaptive fold count; MAXFLD bounds it
        /// here, so they are checked and unused.
        pub fn readSample(args: []const Value) Error!core.query.NoiseSample {
            var s: core.query.NoiseSample = .{ .fs = 0 };
            var i: usize = 0;
            while (i + 1 < args.len) : (i += 2) {
                if (args[i] != .name or args[i + 1] != .num) return error.ParseError;
                const v = args[i + 1].num;
                const Key = enum { fs, tol, numf, maxfld, beta };
                switch (std.meta.stringToEnum(Key, args[i].name) orelse return error.ParseError) {
                    .fs => s.fs = v,
                    .maxfld => s.max_fold = v,
                    .beta => s.beta = v,
                    .tol, .numf => {},
                }
            }
            if (i != args.len or !(s.fs > 0) or !(s.max_fold >= 1) or !(s.beta >= 0 and s.beta <= 1)) return error.ParseError;
            return s;
        }

        /// `line` as the deck spells it: the original case when `line` is a
        /// slice of the parsed text, else the joined continuation as read.
        pub fn written(r: *const R, line: []const u8) []const u8 {
            const at = @intFromPtr(line.ptr);
            const base = @intFromPtr(r.text.ptr);
            return if (at >= base and at + line.len <= base + r.text.len) r.orig[at - base ..][0..line.len] else line;
        }

        /// Logs `line` with `err` and returns `err`; `ParseError` for a
        /// malformed card, `UnsupportedCard` for a form ESPice cannot run.
        pub fn failed(r: *R, line: []const u8, err: Error) Error {
            r.logged = true;
            if (!@import("builtin").is_test) std.log.err("netlist: {s}: {s}", .{ @errorName(err), r.written(line) });
            return err;
        }

        // Sweeps and variants.

        /// The live-table row of global `.param` `name`, registering it (and
        /// folding its nominal value) on first use; null for a name no
        /// `.param` defines.
        pub fn liveParam(r: *R, name: []const u8) Error!?u32 {
            if (r.live_names.getIndex(name)) |k| return @intCast(k);
            const entry = r.globals.get(name) orelse return null;
            const top: Frame = .{ .scopes = &r.global_scopes };
            r.live_ok = true;
            defer r.live_ok = false;
            const v = switch (entry) {
                .num => |n| n,
                .text => |text| switch (try r.exprValue(text, &top, false)) {
                    .num => |n| n,
                    else => return error.ParseError,
                },
            };
            try r.live_names.put(r.arena, name, {});
            try r.live_nominal.append(r.arena, v);
            return @intCast(r.live_names.count() - 1);
        }

        /// Folds each global `.param` to its number in deck order, once every
        /// live name is known, so each link of a chain reads its
        /// predecessor's number and `subst` recurses one level per read, not
        /// one per link (#110). A value that reads a live name, draws a
        /// distribution or reads `temper` keeps its text, and an error stays
        /// for the card that reads it, except a refusal `subst` logged (an
        /// unknown function) and a read of a name nothing defines or of the
        /// circuit, which fail the deck read or not, as ngspice's numparam
        /// does.
        pub fn foldGlobals(r: *R) Error!void {
            const top: Frame = .{ .scopes = &r.global_scopes };
            const was_in_card = r.in_card;
            r.in_card = true;
            defer r.in_card = was_in_card;
            // A refusal names the parameter's text.
            const card = r.card;
            defer r.card = card;
            for (r.global_keys.items) |key| {
                const entry = r.globals.getPtr(key).?;
                if (entry.* != .text) continue;
                const ops_mark = r.ops.items.len;
                const consts_mark = r.consts.items.len;
                const sites_mark = r.site_ops.items.len;
                r.card = entry.text;
                const logged = r.logged;
                const v: ?Value = r.exprValue(entry.text, &top, false) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => if (r.logged and !logged) return err else null, // else: the reading card reports it
                };
                // numparam evaluates each .param where it stands and stops on
                // a name it does not define, read or not: ngspice-44.2 says
                // "Undefined parameter [hertz]", and so for time, temp, pi,
                // w and v(a). Only `temper` (final `.ident` 3) waits for its
                // reader: ngspice makes that .param a .func (inpcom.c
                // inp_fix_temper_in_param), which runs where the reading card
                // reads temper and stops elsewhere (temper_slots.zig).
                if (v) |x| if (x == .expr) for (r.ops.items[x.expr.start..][0..x.expr.len]) |op| switch (op.code) {
                    .ident => if (op.a != 3) return r.unsupported(entry.text, "a .param that reads a name no .param defines: ngspice-44.2 stops on it, read or not"),
                    .vprobe, .iprobe => return r.unsupported(entry.text, "a .param that reads the circuit: ngspice-44.2 stops on it, read or not"),
                    else => {}, // else: constants, operators, calls and live names
                };
                r.ops.shrinkRetainingCapacity(ops_mark);
                r.consts.shrinkRetainingCapacity(consts_mark);
                r.site_ops.shrinkRetainingCapacity(sites_mark);
                r.site_keys.shrinkRetainingCapacity(sites_mark);
                if (v) |x| if (x == .num) {
                    entry.* = .{ .num = x.num };
                };
            }
        }

        /// A swept name: `temp`, a top-level card, or a global `.param`. A
        /// card wins over a `.param` of its name, as in ngspice, whose `.dc`
        /// looks a name up among the resistors, the V and the I sources,
        /// then as `temp` and `@inst[param]`, never among the parameters
        /// (dctrcurv.c:156-247). Every sweep that names its quantity (`.dc`,
        /// `.step`, a SWEEP tail, a `.data` column) resolves here. Cards
        /// match case-insensitively, as `analysis_time.dcTarget` finds them.
        // ponytail: a scan of the top-level cards per swept name; index
        // them when a deck sweeps many names over millions of cards.
        pub fn stepTarget(r: *R, name: []const u8) Error!StepTarget {
            if (std.mem.eql(u8, name, "temp")) return .temp;
            for (r.top_devices) |i| {
                var f = F.init(r.lines.items[i]);
                const head = f.next() orelse continue;
                if (std.ascii.eqlIgnoreCase(head, name)) return .{ .card = name };
            }
            if (try r.liveParam(name)) |k| return .{ .param = k };
            return .{ .card = name };
        }

        /// `.step [lin|dec|oct] [param] name start stop incr`, `.step
        /// [param] name list v...`, with `temp` or a source for the name
        /// (ngspice/LTspice form). `dec`/`oct` take points per decade or
        /// octave.
        pub fn readStep(r: *R, args: []const Value) Error!Step {
            var i: usize = 0;
            var grid: Grid = .lin;
            if (i < args.len and args[i] == .name) if (grids.get(args[i].name)) |g| {
                grid = g;
                i += 1;
            };
            const param = i < args.len and args[i] == .name and std.mem.eql(u8, args[i].name, "param");
            i += @intFromBool(param);
            if (i >= args.len or args[i] != .name) return error.ParseError;
            const target: StepTarget = if (param)
                .{ .param = try r.liveParam(args[i].name) orelse return error.ParseError }
            else
                try r.stepTarget(args[i].name);
            i += 1;
            if (i < args.len and args[i] == .name and std.mem.eql(u8, args[i].name, "list")) {
                // An empty list would plan no runs at all (#66).
                if (i + 1 == args.len) return error.ParseError;
                return .{ .target = target, .values = try r.numbers(args[i + 1 ..]) };
            }
            if (grid == .poi) return error.ParseError;
            const n = try r.numbers(args[i..]);
            if (n.len != 3) return error.ParseError;
            return .{ .target = target, .values = try points(r.arena, grid, n[0], n[1], n[2], .per_unit) };
        }

        // ---- private ----

        /// One item of an ngspice `.save`, as ngspice 44.2 saves it (manual
        /// 11.6.1; measured with `-b -r`): `all` and `allv` save everything,
        /// a node `n`, `v(n)`, `v(a, b)` and `vm`, `vp`, `vr`, `vdb` of nodes
        /// each node, `i(x)` and `x#branch` the branch current, `@dev[p]`
        /// the operating-point variable (#236), which `prepare` resolves or
        /// refuses. `.save` narrows the output, so an item it cannot read
        /// (`alli`, `vi(n)`, a quoted expression) refuses the card rather
        /// than drop a vector. Two skips are ngspice's: the operator tail of
        /// `v(a)/10`, which saves v(a), and a name nothing publishes, which
        /// `prepare` drops (`keepSaved`) where ngspice saves nothing.
        fn saveItem(r: *R, line: []const u8, a: Value) Error!void {
            var buf: [24]u8 = undefined;
            switch (a) {
                .name => |n| if (std.ascii.eqlIgnoreCase(n, "all") or std.ascii.eqlIgnoreCase(n, "allv")) {
                    r.save_all = true;
                } else if (n[0] == '@') {
                    const label = try r.arena.dupe(u8, n);
                    try r.opvar_saves.append(r.arena, std.ascii.lowerString(label, label));
                    // Holds `saves` non-empty, so the probes narrow.
                    try r.saves.append(r.arena, label);
                } else if (std.ascii.endsWithIgnoreCase(n, "#branch")) {
                    try save(r, 'i', n[0 .. n.len - "#branch".len]);
                } else if (std.ascii.eqlIgnoreCase(n, "alli")) {
                    return r.unsupported(line, ".save alli: device terminal currents are not written");
                } else if (!R.operatorLed(n)) try save(r, 'v', n),
                .num => try save(r, 'v', nodeText(a, &buf) orelse return r.unsupported(line, "a .save number that names no node")),
                .group => |g| {
                    const voltage = std.StaticStringMap(void).initComptime(.{ .{"v"}, .{"vm"}, .{"vp"}, .{"vr"}, .{"vdb"} });
                    var name_buf: [4]u8 = undefined;
                    const fun = if (g.name().len <= name_buf.len) std.ascii.lowerString(&name_buf, g.name()) else "";
                    const current = std.mem.eql(u8, fun, "i") and g.args().len == 1;
                    if (!current and !voltage.has(fun)) return r.unsupported(line, "a .save function other than v, vm, vp, vr, vdb or i");
                    for (g.args()) |arg| try save(r, if (current) 'i' else 'v', nodeText(arg, &buf) orelse return r.unsupported(line, "a .save argument that names no node or device"));
                },
                else => return r.unsupported(line, "a .save item other than a node, v(), i(), x#branch, @dev[p], all or allv"),
            }
        }

        /// Appends the output label `kind(name)`, lowercased, to the saves.
        fn save(r: *R, kind: u8, name: []const u8) Error!void {
            const label = try r.arena.print("{c}({s})", .{ kind, name });
            try r.saves.append(r.arena, std.ascii.lowerString(label, label));
        }

        /// ngspice's `.probe` (inpc_probe.c). `v(node)` saves the node as
        /// `.save v(node)` does (:375-378); with no `.save` in the deck
        /// ngspice adds `.save all` (:66-95), which every output already is.
        /// `i()`, `vd()`, `p()`, `alli` and a bare `.probe` insert measuring
        /// sources ESPice does not build, so they refuse the card by name
        /// rather than lose its vectors. An item led by none of these is
        /// skipped with a warning, as ngspice skips it (:118-128, :921-924).
        fn ngspiceProbe(r: *R, line: []const u8) Error!void {
            var rest = std.mem.trim(u8, line[".probe".len..], " \t");
            var words = std.mem.tokenizeAny(u8, rest, " \t,()");
            while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, "alli")) return r.unsupported(line, "ngspice .probe alli");
            if (rest.len == 0) return r.unsupported(line, "a bare ngspice .probe, which is .probe alli");
            const narrowed = for (r.lines.items) |l| {
                if (std.ascii.startsWithIgnoreCase(l, ".save") and !isSaveOp(l)) break true;
            } else false;
            // Items end at their `)`, as ngspice cuts them (gettok_char).
            while (rest.len != 0) {
                const close = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len - 1;
                const item = std.mem.trim(u8, rest[0 .. close + 1], " \t");
                rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
                if (std.ascii.startsWithIgnoreCase(item, "vd(") or std.ascii.startsWithIgnoreCase(item, "i(") or std.ascii.startsWithIgnoreCase(item, "p("))
                    return r.unsupported(line, "an ngspice .probe of i(), vd() or p(): its measuring sources are not built");
                if (!std.ascii.startsWithIgnoreCase(item, "v(") or item[item.len - 1] != ')') {
                    if (!@import("builtin").is_test) std.log.warn("netlist: .probe item '{s}' skipped, as ngspice skips it (inpc_probe.c:118-128): {s}", .{ item, r.written(line) });
                    continue;
                }
                var nodes = std.mem.tokenizeAny(u8, item[2 .. item.len - 1], " \t,");
                if (narrowed) while (nodes.next()) |node| try save(r, 'v', node);
            }
        }

        /// ESPice's operating-point `.save` (HSPICE's [CR .SAVE] spelling):
        /// `.save [TYPE=NODESET|IC] [FILE=] [LEVEL=ALL|TOP|SELECT|NONE]
        /// [TIME=]`. SELECT saves every node, as ALL; NONE saves nothing.
        /// The last card wins. ngspice's `.save` vector list never carries a
        /// `key=value` field, so one of these keys selects this reading.
        fn readSaveOp(r: *R, line: []const u8, f: *F) Error!void {
            var op: core.SaveOp = .{};
            var none_level = false;
            while (f.next()) |key| {
                if (!F.isWord(key) or !f.takeEq()) return r.failed(line, error.ParseError);
                const Key = enum { type, file, level, time };
                switch (std.meta.stringToEnum(Key, key) orelse return r.failed(line, error.ParseError)) {
                    .file => op.file = try r.pathOf(f),
                    .time => op.time = S.parseNum(f.next() orelse "") orelse return r.failed(line, error.ParseError),
                    .type => {
                        const v = f.next() orelse "";
                        if (!std.mem.eql(u8, v, "ic") and !std.mem.eql(u8, v, "nodeset")) return r.failed(line, error.ParseError);
                        op.ic = std.mem.eql(u8, v, "ic");
                    },
                    .level => {
                        const v = f.next() orelse "";
                        const levels = std.StaticStringMap(void).initComptime(.{ .{"all"}, .{"top"}, .{"select"}, .{"none"} });
                        if (!levels.has(v)) return r.failed(line, error.ParseError);
                        op.top_only = std.mem.eql(u8, v, "top");
                        none_level = std.mem.eql(u8, v, "none");
                    },
                }
            }
            if (!(op.time >= 0)) return r.failed(line, error.ParseError);
            r.save_op = if (none_level) null else op;
        }

        /// True when the `.save` card `line` carries a `type=`, `file=`,
        /// `level=` or `time=` key: the operating-point save, not ngspice's
        /// vector list.
        fn isSaveOp(line: []const u8) bool {
            return setsKey(line, "type") or setsKey(line, "file") or setsKey(line, "level") or setsKey(line, "time");
        }
    };
}
