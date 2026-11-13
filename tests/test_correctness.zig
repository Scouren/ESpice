//! End-to-end fixture runner: simulates every tests/conformance/tests/netlist deck in a child
//! espice and checks the raw output against its embedded .expected.json
//! oracle. An unsupported feature is a failure, never a skip. The one skip:
//! under an explicit `--backend cuda|hip`, a deck with nothing GPU-eligible,
//! which that backend refuses by design; `auto`, the release GPU corpus
//! (`zig build test -- --backend auto --jobs 1`), runs such a deck on the
//! CPU and compares it like any other. A deck whose
//! header carries `* KNOWN GAP:` reports XFAIL when it fails, which does not
//! fail the run, and XPASS when it passes, which does: drop the marker. From
//! the root:
//!   zig build test -- --jobs 8 --filter op/
//!   zig build test -- --list
//! A full CPU run (no `--filter`) also checks every deck's verdict by name
//! against tests/VERDICTS.tsv (AGENTS.md, Testing), and fails on any difference:
//! a deck added, removed, or moved between PASS and XFAIL. After a measured
//! run whose differences are intended, rewrite the file from that run:
//!   zig build test -- --update-verdicts
//! With `--metamorphic` it instead runs every deck tests/metamorphic.zig can
//! rewrite exactly, once as written and once per rewrite, and fails when a
//! rewrite moves a result past float noise (part of `zig build test`).
//! With `--perturb` every expected value moves by 0.1% (`perturb`) and a deck
//! that still passes is reported LOOSE: its tolerance cannot see an error
//! that size. It reports and never fails (the nightly tier).
//! After the decks, the `spicerack/` checks run the CLI's SpiceRack step
//! against fake spice2rack binaries (tests/spicerack/, `spicerack_checks`),
//! `vpi/bare_name` the CLI's `--vpi` file name, and
//! `netlist/behavioural_dropped` its warning for a dropped field (`cli_checks`).
//! A deck on the SpiceRack route (`tokenizer` hspice or spectre) whose run
//! warns that ESPice dropped input fails as `DroppedInput` unless its oracle
//! lists the warning as a `stderr_line` check (`droppedInput`).
//! `--zig PATH` and `--perf LEVERS` set `ZIG` and `ESPICE_PERF` in every
//! espice it starts. build.zig passes them (`-Dperf`) as arguments: setting
//! a variable on its Run step would clone and hash its whole environment.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Complex = std.math.Complex(f64);

const catalog = @import("fixture_catalog");
const metamorphic = @import("metamorphic.zig");
const spice_files = catalog.spice_files;
const expected_files = catalog.expected_files;
const expected_outputs = catalog.expected_outputs;

// Oracle schema (.expected.json, schema_version 1). Counts fit u32; byte
// offsets use usize.
/// `magnitude`: compare |actual| with |expected|, for a complex column whose
/// oracle only knows amplitudes.
const Column = struct { values: []const Json, rtol: f64, atol: f64, magnitude: bool = false };
const Axis = struct { name: []const u8, values: []const f64, rtol: f64, atol: f64 };
const ExpectedPlot = struct {
    name: []const u8,
    match: enum { exact, samples, selected_rows, unordered },
    row_count: ?u32 = null,
    row_indices: []const u32 = &.{},
    axis: ?Axis = null,
    input_source: ?[]const u8 = null,
    columns: std.json.ArrayHashMap(Column),
};
const Expectation = struct {
    status: enum { success, @"error" },
    plots: []const ExpectedPlot = &.{},
    checks: []const Json = &.{},
    category: ?[]const u8 = null,
};
/// `tokenizer`: the `--tokenizer` dialect the deck is read in; null keeps
/// espice's default (ngspice). The CLI runs any other through spice2rack
/// (src/spicerack.zig), found as a user's espice finds it: a missing one
/// fails the deck, never skips it.
const Oracle = struct { schema_version: u8, netlist_sha256: []const u8, expect: Expectation, tokenizer: ?[]const u8 = null };
/// espice's `--measures` JSON (src/espice/report.zig) as `measure` reads
/// it: each `.meas` result and optimized parameter as its exact f64, null
/// when the card failed, and the statistics, of which a `"kind": "monte"`
/// one has `mean`, `sigma`, `min` and `max`.
const Measures = struct { results: []const Measured, optimized: []const Measured = &.{}, statistics: []const Statistic = &.{} };
const Measured = struct { name: []const u8, value: ?f64 };
const Statistic = struct { kind: []const u8 = "", name: []const u8 = "", mean: ?f64 = null, sigma: ?f64 = null, min: ?f64 = null, max: ?f64 = null };
/// One plot of a binary raw file, borrowing the file's row-major data.
const Plot = struct {
    name: []const u8,
    names: []const []const u8,
    rows: u32,
    complex: bool,
    data: []align(1) const f64,

    fn value(self: Plot, row: usize, col: usize) Complex {
        const i = (row * self.names.len + col) * @as(usize, if (self.complex) 2 else 1);
        return .init(self.data[i], if (self.complex) self.data[i + 1] else 0);
    }

    /// Case-insensitive column lookup: an exact name first, then the
    /// `canonical` aliases, which must match exactly one column.
    fn column(self: Plot, name: []const u8) !usize {
        for (self.names, 0..) |actual, i| if (equal(actual, name)) return i;
        var found: ?usize = null;
        for (self.names, 0..) |actual, i| {
            if (!equal(canonical(actual), canonical(name))) continue;
            if (found != null) return error.AmbiguousColumn;
            found = i;
        }
        return found orelse error.MissingColumn;
    }
};

// Workers claim independent indices; the result slots have one writer each.
const Outcome = enum(u8) { unselected, pass, fail, xfail, xpass, skip };
const Runner = struct {
    io: Io,
    app: []const u8,
    filter: []const u8,
    timeout_seconds: u32,
    metamorphic: bool,
    next: std.atomic.Value(u32) = .init(0),
    outcomes: []Outcome,
};
/// The `--backend` every run gets; `auto` and `cuda` check the GPU path
/// against the same expectations. Set once in `main`, before any worker.
var backend_name: []const u8 = "cpu";
/// `--perturb`: the factor on every expected column, measure and statistic.
// ponytail: report-only; ratchet the LOOSE names like VERDICTS.tsv once the list is triaged.
var perturb: f64 = 1;
/// The C VPI application build.zig compiles for the decks marked
/// `* VPI FIXTURE` (`--vpi-fixture`, #197); no path in a deck can name it.
var vpi_fixture: ?[]const u8 = null;
/// Every espice child's environment: this process's, with `--zig` and
/// `--perf` applied. Set once in `main`, before any worker; null inherits.
var child_env: ?*const std.process.Environ.Map = null;
/// Per-case failure detail, printed under the case's FAIL line.
threadlocal var diagnostics: ?*Io.Writer = null;
fn diagnostic(comptime fmt: []const u8, args: anytype) void {
    if (diagnostics) |writer| writer.print(fmt, args) catch {};
}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const app = args.next() orelse "zig-out/bin/espice";
    var filter: []const u8 = "";
    var jobs: u16 = 8;
    var timeout_seconds: u32 = 300;
    var list = equal(app, "--list");
    var update_verdicts = false;
    var metamorphic_mode = false;
    const Flag = enum(u8) { list, filter, jobs, timeout, backend, update_verdicts, metamorphic, vpi_fixture, perturb, zig, perf };
    const flags = std.StaticStringMap(Flag).initComptime(.{
        .{ "--list", .list },               .{ "--filter", .filter },
        .{ "--jobs", .jobs },               .{ "--timeout", .timeout },
        .{ "--backend", .backend },         .{ "--update-verdicts", .update_verdicts },
        .{ "--metamorphic", .metamorphic }, .{ "--vpi-fixture", .vpi_fixture },
        .{ "--perturb", .perturb },         .{ "--zig", .zig },
        .{ "--perf", .perf },
    });
    while (args.next()) |arg| {
        switch (flags.get(arg) orelse return error.UnknownArgument) {
            .list => list = true,
            .filter => filter = args.next() orelse return error.MissingArgument,
            .jobs => jobs = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArgument, 10),
            .timeout => timeout_seconds = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10),
            .backend => backend_name = args.next() orelse return error.MissingArgument,
            .update_verdicts => update_verdicts = true,
            .metamorphic => metamorphic_mode = true,
            .vpi_fixture => vpi_fixture = args.next() orelse return error.MissingArgument,
            .perturb => perturb = 1 + 1e-3,
            .zig => try init.environ_map.put("ZIG", args.next() orelse return error.MissingArgument),
            .perf => try init.environ_map.put("ESPICE_PERF", args.next() orelse return error.MissingArgument),
        }
    }
    child_env = init.environ_map;
    if (jobs == 0) return error.InvalidWorkerCount;
    if (timeout_seconds == 0) return error.InvalidTimeout;
    var selected: u32 = 0;
    for (spice_files, expected_files) |path, expected| {
        if (std.mem.indexOf(u8, path, filter) == null) continue;
        selected += 1;
        if (list) std.debug.print("{s} -> {s}\n", .{ path, expected });
    }
    for (cli_checks) |name| if (std.mem.indexOf(u8, name, filter) != null) {
        selected += 1;
        if (list) std.debug.print("{s} -> the CLI\n", .{name});
    };
    if (selected == 0) return error.NoMatchingFixtures;
    if (list) return 0;
    const outcomes = try init.gpa.alloc(Outcome, spice_files.len);
    defer init.gpa.free(outcomes);
    @memset(outcomes, .unselected);
    var runner: Runner = .{ .io = init.io, .app = app, .filter = filter, .timeout_seconds = timeout_seconds, .metamorphic = metamorphic_mode, .outcomes = outcomes };
    var group: Io.Group = .init;
    defer group.cancel(init.io);
    std.debug.print("Correctness: {d} fixtures, {d} workers\n", .{ selected, @min(jobs, selected) });
    for (0..@min(jobs, selected)) |_| try group.concurrent(init.io, worker, .{&runner});
    try group.await(init.io);
    var count = std.EnumArray(Outcome, u32).initFill(0);
    for (outcomes) |outcome| count.getPtr(outcome).* += 1;
    if (!metamorphic_mode and perturb == 1) for (cli_checks) |name| {
        if (std.mem.indexOf(u8, name, filter) == null) continue;
        count.getPtr(if (cliCheck(init.io, app, name, timeout_seconds)) .pass else .fail).* += 1;
    };
    std.debug.print("Correctness: {d} passed, {d} failed, {d} xfail, {d} xpass, {d} skipped, {d} selected\n", .{
        count.get(.pass), count.get(.fail), count.get(.xfail), count.get(.xpass), count.get(.skip), selected,
    });
    if (perturb != 1 and !metamorphic_mode) {
        std.debug.print("Correctness: {d} of {d} checked decks LOOSE (still pass with every expected value moved 0.1%)\n", .{ count.get(.pass), count.get(.pass) + count.get(.fail) });
        return 0;
    }
    const clean = count.get(.fail) == 0 and count.get(.xpass) == 0;
    // The name list holds only for the whole corpus on the CPU path.
    if (metamorphic_mode or filter.len != 0 or !equal(backend_name, "cpu")) return if (clean) 0 else 1;
    const current = try verdictList(init.gpa, outcomes);
    defer init.gpa.free(current);
    if (update_verdicts) {
        if (!clean) return error.UncleanRun; // the file records only PASS and XFAIL
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = verdicts_path, .data = current });
        std.debug.print("Correctness: wrote {s}\n", .{verdicts_path});
        return 0;
    }
    const recorded = Io.Dir.cwd().readFileAlloc(init.io, verdicts_path, init.gpa, .unlimited) catch |err| {
        std.debug.print("Correctness: cannot read {s} ({s}); run with --update-verdicts\n", .{ verdicts_path, @errorName(err) });
        return 1;
    };
    defer init.gpa.free(recorded);
    var stderr_buf: [256]u8 = undefined;
    var stderr = Io.File.stderr().writer(init.io, &stderr_buf);
    const same = reportVerdictDiff(&stderr.interface, recorded, current);
    stderr.interface.flush() catch {};
    return if (clean and same) 0 else 1;
}

/// The verdict name list, one `PASS<TAB>path` or `XFAIL<TAB>path` per line in
/// catalog order (the build sorts the catalog), so a diff names the decks.
const verdicts_path = "tests/VERDICTS.tsv";

fn verdictList(gpa: Allocator, outcomes: []const Outcome) ![]u8 {
    std.debug.assert(outcomes.len == spice_files.len);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("# Measured by tests/test_correctness.zig; rewrite with `zig build test -- --update-verdicts`.\n");
    for (outcomes, spice_files) |outcome, path| switch (outcome) {
        .pass => try out.writer.print("PASS\t{s}\n", .{path}),
        .xfail => try out.writer.print("XFAIL\t{s}\n", .{path}),
        // A full CPU run selects every deck and skips none.
        .unselected, .skip => unreachable,
        // A clean run has none; an unclean one already fails.
        .fail, .xpass => {},
    };
    return out.toOwnedSlice();
}

/// Prints every line in one list and not the other; true when the two hold
/// the same lines. Zero recorded lines means the file broke, not a pass.
fn reportVerdictDiff(out: *Io.Writer, recorded: []const u8, current: []const u8) bool {
    var same = true;
    var rec_lines: u32 = 0;
    var it = std.mem.splitScalar(u8, recorded, '\n');
    while (it.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        rec_lines += 1;
        if (!containsLine(current, row)) {
            out.print("VERDICT recorded, not measured: {s}\n", .{row}) catch {};
            same = false;
        }
    }
    if (rec_lines == 0) {
        out.print("VERDICT {s} lists no decks\n", .{verdicts_path}) catch {};
        return false;
    }
    it = std.mem.splitScalar(u8, current, '\n');
    while (it.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        if (!containsLine(recorded, row)) {
            out.print("VERDICT measured, not recorded: {s}\n", .{row}) catch {};
            same = false;
        }
    }
    return same;
}

fn containsLine(text: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, want)) return true;
    return false;
}

// Oracle: hand-written name lists whose differences are known.
test "verdict diff names both directions and refuses an empty list" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expect(reportVerdictDiff(&sink.writer, "PASS\ta.sp\nXFAIL\tb.sp\n", "PASS\ta.sp\nXFAIL\tb.sp\n"));
    try std.testing.expect(!reportVerdictDiff(&sink.writer, "PASS\ta.sp\nPASS\tb.sp\n", "PASS\ta.sp\nXFAIL\tb.sp\n"));
    try std.testing.expect(!reportVerdictDiff(&sink.writer, "PASS\ta.sp\n", "PASS\ta.sp\nPASS\tc.sp\n"));
    try std.testing.expect(!reportVerdictDiff(&sink.writer, "# header only\n", "PASS\ta.sp\n"));
}

fn worker(runner: *Runner) void {
    while (true) {
        const i = runner.next.fetchAdd(1, .monotonic);
        if (i >= spice_files.len) return;
        const path = spice_files[i];
        if (std.mem.indexOf(u8, path, runner.filter) == null) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var report: Io.Writer.Allocating = .init(arena.allocator());
        diagnostics = &report.writer;
        defer diagnostics = null;
        const gap = knownGap(arena.allocator(), runner.io, path);
        if (runner.metamorphic) {
            // A known gap's results are wrong to begin with: nothing to keep.
            const ran = !gap and (runMetamorphic(arena.allocator(), runner.io, runner.app, path, expected_outputs[i], runner.timeout_seconds) catch |err| {
                runner.outcomes[i] = .fail;
                std.debug.print("FAIL {s}: {s}\n{s}", .{ path, @errorName(err), report.written() });
                continue;
            });
            runner.outcomes[i] = if (ran) .pass else .skip;
            if (ran) std.debug.print("PASS {s}\n", .{path});
            continue;
        }
        if (perturb != 1) {
            // A known gap fails as written, and a rejection has no value to
            // move: perturbing either says nothing.
            if (gap) continue;
            const oracle = parseOracle(arena.allocator(), expected_outputs[i]) catch continue;
            if (oracle.expect.status == .@"error") continue;
            const loose = if (runCase(arena.allocator(), runner.io, runner.app, path, expected_outputs[i], runner.timeout_seconds)) true else |_| false;
            runner.outcomes[i] = if (loose) .pass else .fail;
            if (loose) std.debug.print("LOOSE {s}\n", .{path});
            continue;
        }
        runCase(arena.allocator(), runner.io, runner.app, path, expected_outputs[i], runner.timeout_seconds) catch |err| {
            if (err == error.NotEligible) {
                runner.outcomes[i] = .skip;
                std.debug.print("SKIP {s}: nothing in the circuit runs on --backend {s}\n", .{ path, backend_name });
                continue;
            }
            runner.outcomes[i] = if (gap) .xfail else .fail;
            std.debug.print("{s} {s}: {s}\n{s}", .{ if (gap) "XFAIL" else "FAIL", path, @errorName(err), report.written() });
            continue;
        };
        runner.outcomes[i] = if (gap) .xpass else .pass;
        std.debug.print("{s} {s}\n", .{ if (gap) "XPASS" else "PASS", path });
    }
}

/// The translation step's contract (src/spicerack.zig), run through the
/// CLI with fake spice2rack binaries from tests/spicerack/. Each runs as a
/// pseudo-deck under its name, after the decks: PASS or FAIL, chosen by
/// `--filter`, outside VERDICTS.tsv. The first three went red before the
/// step existed: `--spicerack` was a usage error (exit 2), and
/// `--tokenizer=hspice` read deck.hsp natively and printed no spicerack line.
/// `include` goes red when the kit names an include relatively: ngspice's
/// order reads the working directory's decoy.inc first. `fifo` goes red
/// without the CLI's regular-file check: the fake translates the FIFO's
/// name and the run exits 0. The file kinds (`touchstone` to `hdl`,
/// `checkKitFile`) run files_spice2rack.sh, whose kit names the one file
/// its entry reads by its absolute path into the kit; `data`, `vec` and
/// `load` go red when it names the file relatively (ngspice's order reads
/// the working directory's decoy first), `touchstone`, `soalimits`, `vpi`
/// and `hdl` only when ESPice resolves those from the working directory too
/// (prepare.zig `deckRelative` reads them beside the entry). `lin` goes red
/// when `.lin format=touchstone` writes beside the deck, which is the kit
/// the CLI deletes, not beside the -r output (publish.zig `writeTouchstone`).
/// `refused` (e2ad5d7's exit 1 and refusal text) went red while every
/// non-zero exit was `SpiceRackFailed`; `refused_exit3` (P8-324's exit 3,
/// a coded line and no refusal header) goes red while only that text
/// decides; `crashed`, the refusal text then a panic's exit 101, goes red
/// when the text alone decides.
const spicerack_checks = [_][]const u8{
    "spicerack/translated", "spicerack/missing",   "spicerack/refused",    "spicerack/refused_exit3", "spicerack/crashed",
    "spicerack/include",    "spicerack/fifo",      "spicerack/touchstone", "spicerack/data",          "spicerack/vec",
    "spicerack/load",       "spicerack/soalimits", "spicerack/vpi",        "spicerack/lin",           "spicerack/hdl",
};
const SpicerackCheck = enum { translated, missing, refused, refused_exit3, crashed, include, fifo, touchstone, data, vec, load, soalimits, vpi, lin, hdl };

/// Every check of the CLI's own handling that runs after the decks, as the
/// spicerack ones do: those, then `vpi/bare_name` (`runVpiBareName`) and
/// `netlist/behavioural_dropped` (`runBehaviouralDropped`).
const cli_checks = spicerack_checks ++ [_][]const u8{ "vpi/bare_name", "netlist/behavioural_dropped" };

/// Runs the check `name` and prints its verdict; true when it passed.
fn cliCheck(io: Io, app: []const u8, name: []const u8, timeout_seconds: u32) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var report: Io.Writer.Allocating = .init(arena.allocator());
    diagnostics = &report.writer;
    defer diagnostics = null;
    const run = if (std.mem.startsWith(u8, name, "spicerack/"))
        runSpicerackCheck(arena.allocator(), io, app, name, timeout_seconds)
    else if (std.mem.startsWith(u8, name, "vpi/"))
        runVpiBareName(arena.allocator(), io, app, timeout_seconds)
    else
        runBehaviouralDropped(arena.allocator(), io, app, timeout_seconds);
    run catch |err| {
        std.debug.print("FAIL {s}: {s}\n{s}", .{ name, @errorName(err), report.written() });
        return false;
    };
    std.debug.print("PASS {s}\n", .{name});
    return true;
}

/// `vpi/bare_name`: `--vpi app.so`, a name with no directory, opens app.so
/// in the working directory, as every other file argument does, where
/// dlopen alone searches the library path (vpi_host.zig `loadApp`); a name
/// nothing is at is refused as no such file. Oracles: veriloga_vpi_app.sp's
/// golden worked by hand, v(out) = 1 V * 500 / (1k + 500) = 1/3 V through
/// the application's G = 2 mS (1 V without it), at the golden's rtol; and
/// the coded message with exit 1. Red with the bare name passed to dlopen:
/// no library path holds app.so, so the run exits 1.
fn runVpiBareName(a: Allocator, io: Io, app: []const u8, timeout_seconds: u32) !void {
    const scratch = try scratchDir(a, io, "vpi");
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const dir = try Io.Dir.cwd().realPathFileAlloc(io, scratch, a);
    const fixture = vpi_fixture orelse return error.MissingVpiFixture;
    try Io.Dir.copyFile(Io.Dir.cwd(), fixture, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/app.so", .{scratch}), io, .{});
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, app, a);
    const deck = try Io.Dir.cwd().realPathFileAlloc(io, "tests/conformance/tests/netlist/hdl/veriloga_vpi_app.sp", a);
    const raw = try std.fmt.allocPrint(a, "{s}/out.raw", .{dir});
    const argv = [_][]const u8{ exe, "--backend", backend_name, "--format=binary", "-b", "-r", raw, "--vpi", "app.so", deck };
    try requireSuccess(try runEspice(a, io, &argv, dir, timeout_seconds));
    const plots = try parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, raw, a, .unlimited));
    if (plots.len != 1 or plots[0].rows != 1) return error.UnexpectedPlots;
    const v_out = plots[0].value(0, try plots[0].column("v(out)")).re;
    if (!(@abs(v_out - 1.0 / 3.0) <= 1e-6 / 3.0)) {
        diagnostic("  v(out) = {d} V, not the application's 1/3 V\n", .{v_out});
        return error.VpiAppNotLoaded;
    }
    var gone = argv;
    gone[8] = "gone.so";
    const refused = try runEspice(a, io, &gone, dir, timeout_seconds);
    if (refused.term != .exited or refused.term.exited != 1) {
        diagnostic("  process {any}\n{s}\n", .{ refused.term, refused.stderr });
        return error.ExpectedExit1;
    }
    _ = try stderrLine(refused.stderr, "error: vpi: gone.so: cannot open the application: no such file");
}

/// `netlist/behavioural_dropped`: a `key=value` field that ngspice's network
/// for a behavioural R, C or L drops without a word (reader_rcl.zig
/// `behaviouralPassive`) is warned about once, and the deck still runs.
/// Oracle: ngspice-44.2 runs `{1n*v(ctl)} ctype=1` and `... foo=1` as the
/// card without the field (va1 0.3068527 either way), and keeps m= and tc1=
/// (inpcom.c eval_m, eval_tc), which draw no warning: the sorted `ignoring`
/// lines are exactly the three named. Red with no warning: HSPICE's CTYPE
/// and LTYPE decks lost those fields through SpiceRack silently.
fn runBehaviouralDropped(a: Allocator, io: Io, app: []const u8, timeout_seconds: u32) !void {
    const scratch = try scratchDir(a, io, "dropped");
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const dir = try Io.Dir.cwd().realPathFileAlloc(io, scratch, a);
    const cards = [_][]const u8{ "ca a 0 {1n*v(ctl)} ctype=1 m=2 tc1=1m", "cc a 0 {1n*v(ctl)} foo=1", "lb a b {1m*v(ctl)} ltype=1" };
    const deck = try std.fmt.allocPrint(a, "* behavioural fields ngspice drops\nvctl ctl 0 1\nr1 ctl a 1k\n{s}\n{s}\n{s}\nrb b 0 1k\n.op\n.end\n", .{ cards[0], cards[1], cards[2] });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/deck.sp", .{dir}), .data = deck });
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, app, a);
    const raw = try std.fmt.allocPrint(a, "{s}/out.raw", .{dir});
    const result = try runEspice(a, io, &.{ exe, "--backend", backend_name, "--format=binary", "-b", "-r", raw, "deck.sp" }, dir, timeout_seconds);
    try requireSuccess(result);
    var want: [cards.len][]const u8 = undefined;
    for (&want, cards, [_][]const u8{ "ctype", "foo", "ltype" }) |*w, card, key|
        w.* = try std.fmt.allocPrint(a, "warning: netlist: ignoring unsupported parameter '{s}' of a behavioural {c}, as ngspice drops it: {s}", .{ key, std.ascii.toUpper(card[0]), card });
    var got: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |l| if (std.mem.indexOf(u8, l, "ignoring") != null) try got.append(a, l);
    std.mem.sort([]const u8, got.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    const same = got.items.len == want.len and for (got.items, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        diagnostic("  want the three lines\n{s}\n{s}\n{s}\n  stderr:\n{s}\n", .{ want[0], want[1], want[2], result.stderr });
        return error.WrongWarnings;
    }
}

/// `translated`: oracle, the native run of the ngspice twin the fake
/// writes, bit for bit, and the fake's 0.2 s sleep as a floor under the
/// SpiceRack time both stderr lines report. `missing` and `refused`:
/// oracle, the contract's coded error and exit 1, the fake's stderr passed
/// through, and no raw file, so the deck was never read natively; `refused`
/// and `refused_exit3` as `SpiceRackRefused` with spice2rack's coded line,
/// `crashed` as `SpiceRackFailed` with its exit 101.
/// `include`: oracle, the divider worked by hand, v(out) = 2 V * 1k / (1k +
/// 1k) = 1 V from the kit's decoy.inc; the working directory's gives 1.5 V.
/// `fifo`: oracle, the contract's coded refusal (`SpiceRackNeedsFile`, exit
/// 1) for a deck spice2rack would open and find empty.
fn runSpicerackCheck(a: Allocator, io: Io, app: []const u8, name: []const u8, timeout_seconds: u32) !void {
    const dir = "tests/spicerack";
    const fixtures = try Io.Dir.cwd().realPathFileAlloc(io, dir, a);
    const scratch = try scratchDir(a, io, "spicerack");
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const out = try Io.Dir.cwd().realPathFileAlloc(io, scratch, a);
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, app, a);
    const kind = std.meta.stringToEnum(SpicerackCheck, name["spicerack/".len..]).?;
    const fake = try std.fmt.allocPrint(a, "{s}/{s}", .{ fixtures, switch (kind) {
        .translated, .fifo => "fake_spice2rack.sh",
        .missing => "no_such_spice2rack",
        .refused => "refusing_spice2rack.sh",
        .refused_exit3 => "exit3_spice2rack.sh",
        .crashed => "crashing_spice2rack.sh",
        .include => "kit_spice2rack.sh",
        .touchstone, .data, .vec, .load, .soalimits, .vpi, .lin, .hdl => "files_spice2rack.sh",
    } });
    const deck = switch (kind) {
        .fifo => fifo: {
            const path = try std.fmt.allocPrint(a, "{s}/deck.hsp", .{out});
            const made = try std.process.run(a, io, .{ .argv = &.{ "mkfifo", path } });
            if (!made.term.success()) return error.MkfifoFailed;
            break :fifo path;
        },
        // files_spice2rack.sh picks the kit by the deck's name, unread.
        .touchstone, .data, .vec, .load, .soalimits, .vpi, .lin, .hdl => stub: {
            const path = try std.fmt.allocPrint(a, "{s}/{t}.hsp", .{ out, kind });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "* never read: files_spice2rack.sh writes the kit this name picks\n.end\n" });
            break :stub path;
        },
        .translated, .missing, .refused, .refused_exit3, .crashed, .include => "deck.hsp",
    };
    const raw = try std.fmt.allocPrint(a, "{s}/translated.raw", .{out});
    const result = try runEspice(a, io, &.{ exe, "--backend", backend_name, "--format=binary", "-b", "-r", raw, "--tokenizer", "hspice", "--spicerack", fake, deck }, dir, timeout_seconds);
    switch (kind) {
        .touchstone, .data, .vec, .load, .soalimits, .vpi, .lin, .hdl => return checkKitFile(a, io, kind, deck, raw, result),
        .translated, .missing, .refused, .refused_exit3, .crashed, .include, .fifo => {},
    }
    if (kind == .include) {
        try requireSuccess(result);
        _ = try stderrLine(result.stderr, "espice: spicerack translated deck.hsp (hspice -> ngspice, 2 files) in ");
        const plots = try parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, raw, a, .unlimited));
        if (plots.len != 1 or plots[0].rows != 1) return error.UnexpectedPlots;
        const v_out = plots[0].value(0, try plots[0].column("v(out)")).re;
        if (!(@abs(v_out - 1) <= 1e-9)) {
            diagnostic("  v(out) = {d} V, not the kit's 1 V (1.5 V is the working directory's decoy.inc)\n", .{v_out});
            return error.IncludeFromWorkDir;
        }
        return;
    }
    if (kind != .translated) {
        if (result.term != .exited or result.term.exited != 1) {
            diagnostic("  process {any}\n{s}\n", .{ result.term, result.stderr });
            return error.ExpectedExit1;
        }
        _ = try stderrLine(result.stderr, switch (kind) {
            .missing => "Error: deck.hsp: SpiceRackNotFound",
            .refused, .refused_exit3 => "Error: deck.hsp: SpiceRackRefused",
            .crashed => "Error: deck.hsp: SpiceRackFailed",
            .fifo => try std.fmt.allocPrint(a, "Error: {s}: SpiceRackNeedsFile", .{deck}),
            .translated, .include, .touchstone, .data, .vec, .load, .soalimits, .vpi, .lin, .hdl => unreachable, // returned above
        });
        if (kind == .refused) _ = try stderrLine(result.stderr, "error: spicerack: deck.hsp: deck:2:1: W0001 a statement kept as another dialect's text");
        if (kind == .refused_exit3) _ = try stderrLine(result.stderr, "error: spicerack: deck.hsp: deck:2:1: W0336 a construct no ngspice form expresses");
        if (kind == .crashed) _ = try stderrLine(result.stderr, "thread 'main' panicked at ");
        if (Io.Dir.cwd().access(io, raw, .{})) |_| return error.ReadNatively else |_| {}
        return;
    }
    try requireSuccess(result);
    const twin = try std.fmt.allocPrint(a, "{s}/twin.raw", .{out});
    try requireSuccess(try runEspice(a, io, &.{ exe, "--backend", backend_name, "--format=binary", "-b", "-r", twin, "--tokenizer", "ngspice", "twin.sp" }, dir, timeout_seconds));
    const want = try parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, twin, a, .unlimited));
    try repeatable(want, try parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, raw, a, .unlimited)));
    _ = try stderrLine(result.stderr, "note: fake spice2rack translated deck.hsp");
    const lines = [_][2][]const u8{
        .{ "espice: spicerack translated deck.hsp (hspice -> ngspice, 1 files) in ", " s" },
        .{ "espice: finished deck.hsp in ", " s in spicerack" },
    };
    for (lines) |l| {
        const rest = try stderrLine(result.stderr, l[0]);
        const value = std.mem.cutSuffix(u8, rest, l[1]) orelse return error.TimingLine;
        // The last number on the line is SpiceRack's time.
        const at = if (std.mem.lastIndexOfScalar(u8, value, ' ')) |i| i + 1 else 0;
        const spent = std.fmt.parseFloat(f64, value[at..]) catch return error.TimingLine;
        if (!(spent >= 0.2)) {
            diagnostic("  {s}{s}: under the fake's 0.2 s\n", .{ l[0], rest });
            return error.TimingLine;
        }
    }
}

/// A file-kind check: files_spice2rack.sh's kit for `kind`, the entry and
/// the one file it reads (2 files), run from tests/spicerack/, where a
/// decoy of that file's name holds another value. Oracles, worked by hand
/// from the kit's file (the decoy's in parentheses): `touchstone`,
/// hspice/s_element.sp's network at DC, the 100 ohm shunt at p1 beside 10
/// ohm into the 50 ohm load, 37.5 ohm behind the 50 ohm source: v(p2) =
/// 1 V * 37.5 / 87.5 * 50 / 60 = 5/14 V (a flat series 50 ohm: 1/3 V);
/// `data`, rl = 1k: v(out) = 2 V * 1k / 2k = 1 V (3k: 1.5 V); `vec`, a at
/// VIH = 1 V from t = 0 (3 V); `load`, v(b) = 0.25 V at t = 0 under uic,
/// the `.ic` itself (0.75 V); `hdl`, a Verilog-A R = 1k compiled at run
/// time (`--zig`) under r1 = 1k: v(out) = 2 V * 1k / 2k = 1 V (3k:
/// 1.5 V); `soalimits`, vgs = 2 V past vgs_max 1.5 V,
/// the one excursion (vds = 1 V past vds_max 0.5 V); `vpi`, the refusal
/// (exit 1, no raw) names the kit's app.vpi, which is no shared object (the
/// decoy's names tests/spicerack/app.vpi). Each value is exact to rounding
/// in the kit's data; the S element's fit is exact on a rational network.
/// `lin` reads no file (1 file): oracle, the `.save`/`.stim` rule that a
/// side file lands beside the -r output, so lin.s2p is there after the run.
fn checkKitFile(a: Allocator, io: Io, kind: SpicerackCheck, deck: []const u8, raw: []const u8, result: std.process.RunResult) !void {
    const files: u8 = if (kind == .lin) 1 else 2;
    _ = try stderrLine(result.stderr, try std.fmt.allocPrint(a, "espice: spicerack translated {s} (hspice -> ngspice, {d} files) in ", .{ deck, files }));
    const want: struct { node: []const u8, volts: f64, decoy: f64 } = switch (kind) {
        .lin => {
            try requireSuccess(result);
            const s2p = try std.fmt.allocPrint(a, "{s}/lin.s2p", .{std.fs.path.dirname(raw).?});
            const written = Io.Dir.cwd().readFileAlloc(io, s2p, a, .unlimited) catch |err| {
                diagnostic("  no {s} ({s}): the .lin file stayed in the deleted kit\n", .{ s2p, @errorName(err) });
                return error.SideFileLost;
            };
            if (std.mem.indexOf(u8, written, "# Hz S RI R 50\n") == null) return error.SideFileLost;
            return;
        },
        .touchstone => .{ .node = "v(p2)", .volts = 5.0 / 14.0, .decoy = 1.0 / 3.0 },
        .data => .{ .node = "v(out)", .volts = 1, .decoy = 1.5 },
        .vec => .{ .node = "v(a)", .volts = 1, .decoy = 3 },
        .load => .{ .node = "v(b)", .volts = 0.25, .decoy = 0.75 },
        .hdl => .{ .node = "v(out)", .volts = 1, .decoy = 1.5 },
        .soalimits => {
            try requireSuccess(result);
            _ = try stderrLine(result.stderr, "soa: m1 vgs = 2.0000 V > vgs_max 1.5 V (op)");
            _ = try stderrLine(result.stderr, "soa: 1 excursions on 1 instances");
            return;
        },
        .vpi => {
            if (result.term != .exited or result.term.exited != 1) {
                diagnostic("  process {any}\n{s}\n", .{ result.term, result.stderr });
                return error.ExpectedExit1;
            }
            // The kit's directory is absolute (src/spicerack.zig `translate`).
            const opened = try stderrLine(result.stderr, "error: vpi: ");
            if (!std.mem.startsWith(u8, opened, "/") or std.mem.indexOf(u8, opened, "/espice-spicerack-") == null or
                std.mem.indexOf(u8, opened, "/app.vpi: cannot open the application") == null)
            {
                diagnostic("  opened {s}, not the kit's app.vpi\n", .{opened});
                return error.FileFromWorkDir;
            }
            if (Io.Dir.cwd().access(io, raw, .{})) |_| return error.RanPastRefusal else |_| {}
            return;
        },
        .translated, .missing, .refused, .refused_exit3, .crashed, .include, .fifo => unreachable, // runSpicerackCheck's own
    };
    try requireSuccess(result);
    const plots = try parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, raw, a, .unlimited));
    if (plots.len != 1 or plots[0].rows == 0) return error.UnexpectedPlots;
    const got = plots[0].value(0, try plots[0].column(want.node)).re;
    if (!(@abs(got - want.volts) <= 1e-9 * want.volts)) {
        diagnostic("  {s} = {d} V, not the kit's {d} V ({d} V is the working directory's decoy)\n", .{ want.node, got, want.volts, want.decoy });
        return error.FileFromWorkDir;
    }
}

/// The rest of the first `stderr` line starting with `prefix`;
/// `error.MissingLine` when none does.
fn stderrLine(stderr: []const u8, prefix: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |l| if (std.mem.cutPrefix(u8, l, prefix)) |rest| return rest;
    diagnostic("  no stderr line `{s}...`:\n{s}\n", .{ prefix, stderr });
    return error.MissingLine;
}

/// The first `stderr` line in which ESPice says it dropped input (a
/// `warning:` holding `ignor`, `skipped` or `unchanged`: an option, a field,
/// a card) that no `stderr_line` check in `checks` allows; null when none.
fn droppedInput(stderr: []const u8, checks: []const Json) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    next: while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "warning: ")) continue;
        const drop = for ([_][]const u8{ "ignor", "skipped", "unchanged" }) |word| {
            if (std.mem.indexOf(u8, l, word) != null) break true;
        } else false;
        if (!drop) continue;
        for (checks) |check| {
            if (try checkKind(check) == .stderr_line and std.mem.startsWith(u8, l, try string(try field(check, "prefix")))) continue :next;
        }
        return l;
    }
    return null;
}

// Oracle: gshunt's and gmindc's stderr as unit run 13's ESPice wrote them
// for their SpiceRack kits, with the lists their oracles would hold.
test "droppedInput: a drop warning the oracle does not list is the verdict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const listed = try std.json.parseFromSliceLeaky(Json, arena.allocator(), "[{\"kind\":\"stderr_line\",\"prefix\":\"warning: options: ignoring unsupported option 'post'\"}]", .{});
    const gmindc = "warning: options: ignoring unsupported option 'gmindc'";
    try std.testing.expectEqualStrings(gmindc, (try droppedInput("warning: options: ignoring unsupported option 'post'\n* gmindc: 2 devices\n" ++ gmindc ++ "\n", listed.array.items)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try droppedInput("warning: options: ignoring unsupported option 'post'\nnote: a seam reran\n", listed.array.items));
    const bdf = "warning: options: unsupported integration method 'bdf'; the method is unchanged";
    try std.testing.expectEqualStrings(bdf, (try droppedInput(bdf ++ "\n", &.{})).?);
}

/// Whether the deck at `path` (under tests/) is marked `* KNOWN GAP:`.
fn knownGap(a: Allocator, io: Io, path: []const u8) bool {
    const full = std.fmt.allocPrint(a, "tests/{s}", .{path}) catch return false;
    return marked(a, io, full, "KNOWN GAP:");
}

/// Whether a `*` comment line of the deck at `netlist` starts with
/// `marker`. An unreadable deck reads as unmarked: the simulator run that
/// follows fails and names it.
fn marked(a: Allocator, io: Io, netlist: []const u8, marker: []const u8) bool {
    const source = Io.Dir.cwd().readFileAlloc(io, netlist, a, .unlimited) catch return false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| {
        if (text.len == 0 or text[0] != '*') continue;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, text[1..], " \t"), marker)) return true;
    }
    return false;
}

/// An `.expected.json` as the schema reads it, in `a`; unknown fields
/// (provenance) are skipped.
fn parseOracle(a: Allocator, json: []const u8) !Oracle {
    return std.json.parseFromSliceLeaky(Oracle, a, json, .{ .ignore_unknown_fields = true });
}

/// The lowercase hex SHA-256 of `bytes`, the form `netlist_sha256` records.
fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// A fresh `.zig-cache/<kind>/<random hex>` directory, created; the caller
/// deletes it.
fn scratchDir(a: Allocator, io: Io, kind: []const u8) ![]const u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(a, ".zig-cache/{s}/{s}", .{ kind, std.fmt.bytesToHex(random, .lower) });
    try Io.Dir.cwd().createDirPath(io, path);
    return path;
}

/// `simulate`, required to exit 0, then its raw output parsed.
fn simulatePlots(a: Allocator, io: Io, app: []const u8, netlist: []const u8, output: []const u8, timeout_seconds: u32, tokenizer: ?[]const u8) ![]const Plot {
    try requireSuccess(try simulate(a, io, app, netlist, output, timeout_seconds, tokenizer));
    return parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, output, a, .unlimited));
}

/// Checks the oracle, the deck's hash against it, then simulates and compares.
/// A `repeatability` check reruns the deck and requires bitwise-equal output.
fn runCase(a: Allocator, io: Io, app: []const u8, path: []const u8, expected: []const u8, timeout_seconds: u32) !void {
    const oracle = try parseOracle(a, expected);
    try validateOracle(oracle);
    const netlist = try std.fmt.allocPrint(a, "tests/{s}", .{path});
    const source = try Io.Dir.cwd().readFileAlloc(io, netlist, a, .unlimited);
    if (!equal(&sha256Hex(source), oracle.netlist_sha256)) return error.StaleOracle;

    // Isolated output per case/run. Child processes see the fixture directory,
    // so relative .include/.hdl paths keep their SPICE meaning.
    const scratch = try scratchDir(a, io, "correctness");
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const raw = try Io.Dir.cwd().realPathFileAlloc(io, scratch, a);
    const output = try std.fmt.allocPrint(a, "{s}/result.raw", .{raw});
    const executable = try Io.Dir.cwd().realPathFileAlloc(io, app, a);
    const result = try simulate(a, io, executable, netlist, output, timeout_seconds, oracle.tokenizer);
    if (oracle.expect.status == .@"error") return checkRejection(oracle.expect.category.?, result);
    // An explicit GPU backend refuses a circuit with no GPU-eligible device
    // (no CPU fallback); under it that deck has nothing to compare. `auto`
    // warns the same reason and runs the deck on the CPU.
    if (explicitGpu() and std.mem.indexOf(u8, result.stderr, "(CircuitNotEligible)") != null) return error.NotEligible;
    // A runtime model whose device kernels failed to build runs on the host
    // under a GPU backend (src/device/hdl_gpu.zig): the deck never tested
    // the GPU path it asked for. Under `auto` too: a failed kernel build is a bug either way.
    if (!equal(backend_name, "cpu") and std.mem.indexOf(u8, result.stderr, "hdl: no device kernels for ") != null) return error.DeviceKernelsFailed;
    try requireSuccess(result);
    // A routed deck ran SpiceRack's translation: a warning that ESPice
    // dropped part of it is input the translation lost, whatever the numbers.
    const routed = if (oracle.tokenizer) |t| !equal(t, "ngspice") else false;
    if (routed) if (try droppedInput(result.stderr, oracle.expect.checks)) |l| {
        diagnostic("  {s}\n  (list it as a stderr_line check if the drop is harmless)\n", .{l});
        return error.DroppedInput;
    };
    // A `-Dcertify` build reports its KCL record on stderr (src/analysis/certify.zig).
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, "certify:")) std.debug.print("{s} {s}\n", .{ netlist, l });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, output, a, .unlimited);
    const plots = try parseRaw(a, bytes);
    try compare(a, oracle.expect, plots);
    var measures: ?Measures = null;
    for (oracle.expect.checks) |check| if (try checkKind(check) == .measure) {
        if (measures == null) {
            const json = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}.json", .{output}), a, .unlimited);
            measures = try std.json.parseFromSliceLeaky(Measures, a, json, .{ .ignore_unknown_fields = true });
        }
        try measure(measures.?, result.stdout, check);
    };
    for (oracle.expect.checks) |check| if (try checkKind(check) == .stderr_line) {
        _ = try stderrLine(result.stderr, try string(try field(check, "prefix")));
    };
    for (oracle.expect.checks) |check| {
        if (!equal(try string(try field(check, "kind")), "repeatability")) continue;
        // Remove the first output so a missing second result cannot reuse it.
        try Io.Dir.cwd().deleteFile(io, output);
        try repeatable(plots, try simulatePlots(a, io, executable, netlist, output, timeout_seconds, oracle.tokenizer));
    }
}

/// The deck at `path` as written and after each metamorphic rewrite,
/// compared column by column; false when no rewrite applies (an error
/// oracle, a dialect other than ngspice, or syntax the rewrites skip).
fn runMetamorphic(a: Allocator, io: Io, app: []const u8, path: []const u8, expected: []const u8, timeout_seconds: u32) !bool {
    const oracle = try parseOracle(a, expected);
    if (oracle.expect.status == .@"error" or oracle.tokenizer != null) return false;
    const netlist = try std.fmt.allocPrint(a, "tests/{s}", .{path});
    const source = try Io.Dir.cwd().readFileAlloc(io, netlist, a, .unlimited);
    const scratch = try scratchDir(a, io, "metamorphic");
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const dir = try Io.Dir.cwd().realPathFileAlloc(io, scratch, a);
    const executable = try Io.Dir.cwd().realPathFileAlloc(io, app, a);
    var base: ?[]const Plot = null;
    var bad = false;
    for (std.meta.tags(metamorphic.Kind)) |kind| {
        const v = try metamorphic.rewrite(a, source, kind) orelse continue;
        if (base == null) {
            base = try simulatePlots(a, io, executable, netlist, try std.fmt.allocPrint(a, "{s}/base.raw", .{dir}), timeout_seconds, null);
        }
        const deck = try std.fmt.allocPrint(a, "{s}/{t}.sp", .{ dir, kind });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = deck, .data = v.text });
        const plots = try simulatePlots(a, io, executable, deck, try std.fmt.allocPrint(a, "{s}/{t}.raw", .{ dir, kind }), timeout_seconds, null);
        sameResults(a, base.?, plots, v) catch |err| {
            diagnostic("  {t}: {s}\n{s}", .{ kind, @errorName(err), v.text });
            bad = true;
        };
    }
    if (bad) return error.MetamorphicMismatch;
    return base != null;
}

/// Every column of every plot of `base` against its `v.column` in `got`:
/// pointwise for op, dc and ac; for a transient, at the time points both
/// grids hold. A rewrite may move the step grid (the LTE test's `abstol` and
/// `chgtol` floors are absolute, so `scale` moves it in ngspice too), and an
/// interpolated coarse step is no evidence either way.
fn sameResults(a: Allocator, base: []const Plot, got: []const Plot, v: metamorphic.Variant) !void {
    if (base.len != got.len) return error.PlotCount;
    for (base, got) |p, q| {
        if (!equal(p.name, q.name)) return error.PlotName;
        const transient = std.ascii.findIgnoreCase(p.name, "transient") != null;
        if (!transient and p.rows != q.rows) return error.RowCount;
        for (p.names, 0..) |name, col| {
            // A variant keeps the base's column order, so the same index is
            // tried first: `column` walks every name, which is quadratic
            // over a plot with one column per node.
            const mapped = try v.column(a, name);
            const qcol = if (col < q.names.len and equal(q.names[col], mapped)) col else q.column(mapped) catch |err| {
                diagnostic("  column {s}: {s}\n", .{ name, @errorName(err) });
                return err;
            };
            const current = std.mem.startsWith(u8, name, "i(") or std.mem.endsWith(u8, name, "#branch");
            const factor: f64 = if (current) v.current_factor else 1;
            var peak: f64 = 0;
            for (0..p.rows) |r| peak = @max(peak, std.math.hypot(p.value(r, col).re, p.value(r, col).im));
            // Float noise for a direct solve; a transient point within the LTE bound (reltol 1e-3).
            const rtol: f64 = if (transient) 1e-3 else 1e-6;
            const atol = rtol * peak + 1e-15;
            var compared: usize = 0;
            var at: usize = 0; // both time axes increase: one merge walk
            for (0..p.rows) |r| {
                const row = if (!transient) r else blk: {
                    const t = p.value(r, 0).re;
                    while (at < q.rows and q.value(at, 0).re < t) at += 1;
                    if (at == q.rows or q.value(at, 0).re != t) continue;
                    break :blk at;
                };
                compared += 1;
                const raw = q.value(row, qcol);
                const have: Complex = .init(raw.re * factor, raw.im * factor);
                const want = p.value(r, col);
                if (!close(have, want, rtol, atol)) {
                    diagnostic("  {s} ({s}) row {d}: {d} != {d}\n", .{ name, p.name, r, have.re, want.re });
                    return error.ResultMoved;
                }
            }
            // Time 0 and the stop time are on every grid.
            if (p.rows > 0 and compared == 0) return error.NoCommonPoints;
        }
    }
}

/// Runs espice on `netlist` from its own directory, so relative includes
/// resolve; its `.meas` results also go to `<output>.json` (`--measures`).
/// `error.Timeout` after `timeout_seconds`; `error.MemoryLeaked`
/// when the run's allocator reported a leak, whatever it exited with: Zig's
/// start code leaves the exit code alone on one, so only stderr shows it.
fn simulate(a: Allocator, io: Io, app: []const u8, netlist: []const u8, output: []const u8, timeout_seconds: u32, tokenizer: ?[]const u8) !std.process.RunResult {
    const measures = try std.fmt.allocPrint(a, "--measures={s}.json", .{output});
    const base = [_][]const u8{ app, "--backend", backend_name, "--format=binary", "-b", "-r", output, measures, "--tokenizer", tokenizer orelse "ngspice", std.fs.path.basename(netlist) };
    var with_vpi: [base.len + 2][]const u8 = undefined;
    const argv: []const []const u8 = if (marked(a, io, netlist, "VPI FIXTURE")) blk: {
        @memcpy(with_vpi[0..base.len], &base);
        with_vpi[base.len] = "--vpi";
        // Absolute, as `app` is: the deck runs from its own directory.
        with_vpi[base.len + 1] = try Io.Dir.cwd().realPathFileAlloc(io, vpi_fixture orelse return error.MissingVpiFixture, a);
        break :blk &with_vpi;
    } else &base;
    return runEspice(a, io, argv, std.fs.path.dirname(netlist).?, timeout_seconds);
}

/// Runs the espice command `argv` in `cwd`. `error.Timeout` after
/// `timeout_seconds`; `error.MemoryLeaked` as `simulate` says.
fn runEspice(a: Allocator, io: Io, argv: []const []const u8, cwd: []const u8, timeout_seconds: u32) !std.process.RunResult {
    // A total deadline also covers a child that closes its streams then hangs.
    const Event = union(enum) { process: std.process.RunError!std.process.RunResult, timeout: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    const options: std.process.RunOptions = .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = child_env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    };
    try select.concurrent(.process, std.process.run, .{ a, io, options });
    try select.concurrent(.timeout, Io.sleep, .{ io, Io.Duration.fromSeconds(timeout_seconds), Io.Clock.awake });
    const result = switch (try select.await()) {
        .process => |result| try result,
        .timeout => return error.Timeout,
    };
    if (std.mem.indexOf(u8, result.stderr, leak_report) != null) {
        diagnostic("  leak\n{s}\n", .{result.stderr});
        return error.MemoryLeaked;
    }
    return result;
}

/// What a Debug or ReleaseSafe espice's allocator prints per leaked block
/// at exit (std.heap.SafeAllocator).
const leak_report = "error(SafeAllocator): leaked";

fn requireSuccess(result: std.process.RunResult) !void {
    if (result.term == .exited and result.term.exited == 0) return;
    diagnostic("  process {any}\n{s}{s}\n", .{ result.term, result.stdout, result.stderr });
    return error.SimulatorFailed;
}

fn checkRejection(category: []const u8, result: std.process.RunResult) !void {
    // A crash, usage error, missing model or generic unsupported-feature error
    // is not evidence that the requested invalid analysis was diagnosed.
    if (result.term != .exited or result.term.exited != 1) return error.ExpectedDiagnosticExit;
    const categories = std.StaticStringMap([]const u8).initComptime(.{
        .{ "InvalidQueryOptions", "invalid_analysis_arguments" },
        .{ "InvalidAnalysisArguments", "invalid_analysis_arguments" },
        .{ "InvalidAnalysis", "invalid_analysis_arguments" },
        .{ "AnalysisSourceNotFound", "invalid_analysis_arguments" },
        .{ "AnalysisNodeNotFound", "invalid_analysis_arguments" },
        .{ "NonuniqueOperatingPoint", "nonunique_operating_point" },
        .{ "FloatingNode", "nonunique_operating_point" },
        .{ "InconsistentCircuit", "inconsistent_circuit" },
        .{ "InconsistentVoltageLoop", "inconsistent_circuit" },
        .{ "VoltageSourceLoop", "inconsistent_circuit" },
        .{ "CurrentSourceCutset", "inconsistent_circuit" },
        .{ "invalid_analysis_arguments", "invalid_analysis_arguments" },
        .{ "nonunique_operating_point", "nonunique_operating_point" },
        .{ "inconsistent_circuit", "inconsistent_circuit" },
        .{ "UnsupportedCard", "unsupported_input" },
        .{ "UnresolvedParameter", "unsupported_input" },
        .{ "UnknownParameter", "unsupported_input" },
        .{ "UnsupportedDevice", "unsupported_input" },
        .{ "InvalidParameterValue", "unsupported_input" },
        .{ "WrongNodeCount", "inconsistent_circuit" },
        .{ "OsdiUnsupported", "unsupported_input" },
        .{ "UnregisteredSystf", "unsupported_input" },
        .{ "VpiSecondSystfModule", "unsupported_input" },
        .{ "UnpairedPoleRoot", "unsupported_input" },
        // spice2rack's refusal of a construct, never its absence or crash
        // (SpiceRackNotFound, SpiceRackFailed): spicerack.zig `refusal`.
        .{ "SpiceRackRefused", "unsupported_input" },
        .{ "unsupported_input", "unsupported_input" },
    });
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |text| {
        // Match the diagnostic, not a filename which happens to name an error.
        const start = if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| colon + 1 else 0;
        if (categories.get(std.mem.trim(u8, text[start..], " \t\r"))) |actual| {
            if (equal(actual, category)) return;
        }
    }
    diagnostic("  wanted diagnostic category {s}, received:\n{s}\n", .{ category, result.stderr });
    return error.WrongDiagnostic;
}

/// `--backend cuda` or `hip`: no CPU fallback.
fn explicitGpu() bool {
    return !equal(backend_name, "cpu") and !equal(backend_name, "auto");
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Folds the spellings ngspice and espice use for the same `.tf` and
/// branch-current columns onto one name.
fn canonical(name: []const u8) []const u8 {
    const tf = std.StaticStringMap([]const u8).initComptime(.{
        .{ "v(transfer_function)", "transfer_function" },
        .{ "transfer_function", "transfer_function" },
        .{ "input_resistance", "input_resistance" },
        .{ "output_resistance", "output_resistance" },
    });
    if (tf.get(name)) |mapped| return mapped;
    if (std.mem.indexOf(u8, name, "#input_impedance") != null) return "input_resistance";
    if (std.mem.startsWith(u8, name, "v(output_impedance_at_")) return "output_resistance";
    if (std.mem.endsWith(u8, name, "#branch")) return name[0 .. name.len - 7];
    return name;
}

fn line(bytes: []const u8, pos: *usize) ![]const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, pos.*, '\n') orelse return error.TruncatedRaw;
    const text = std.mem.trim(u8, bytes[pos.*..end], " \t\r");
    pos.* = end + 1;
    return text;
}

/// Parses concatenated binary raw plots, rejecting duplicate columns,
/// truncation and non-finite values.
fn parseRaw(a: Allocator, bytes: []const u8) ![]const Plot {
    var plots: std.ArrayList(Plot) = .empty;
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == '\n' or bytes[pos] == '\r') {
            pos += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, try line(bytes, &pos), "Title:")) return error.InvalidRawHeader;
        var name: ?[]const u8 = null;
        var ncols: ?u32 = null;
        var nrows: ?u32 = null;
        var complex: ?bool = null;
        while (true) {
            const text = try line(bytes, &pos);
            if (equal(text, "Variables:")) break;
            const split = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidRawHeader;
            const key = text[0..split];
            const value = std.mem.trim(u8, text[split + 1 ..], " \t");
            if (equal(key, "Plotname")) name = value;
            if (equal(key, "No. Variables")) ncols = try std.fmt.parseInt(u32, value, 10);
            if (equal(key, "No. Points")) nrows = try std.fmt.parseInt(u32, value, 10);
            if (equal(key, "Flags")) {
                complex = if (equal(value, "complex")) true else if (equal(value, "real")) false else return error.UnsupportedRawFlags;
            }
        }
        const cols = ncols orelse return error.InvalidRawHeader;
        const rows = nrows orelse return error.InvalidRawHeader;
        const is_complex = complex orelse return error.InvalidRawHeader;
        if (cols == 0 or cols > bytes.len) return error.InvalidRawHeader;
        const names = try a.alloc([]const u8, cols);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try seen.ensureTotalCapacity(a, cols);
        for (names, 0..) |*dest, i| {
            var tokens = std.mem.tokenizeAny(u8, try line(bytes, &pos), " \t");
            if (try std.fmt.parseInt(u32, tokens.next() orelse return error.InvalidRawHeader, 10) != i) return error.InvalidRawHeader;
            dest.* = tokens.next() orelse return error.InvalidRawHeader;
            _ = tokens.next() orelse return error.InvalidRawHeader;
            if (tokens.next() != null) return error.InvalidRawHeader;
            const key = try std.ascii.allocLowerString(a, dest.*);
            if (seen.getOrPutAssumeCapacity(key).found_existing) return error.DuplicateColumn;
        }
        if (!equal(try line(bytes, &pos), "Binary:")) return error.ExpectedBinaryRaw;
        const width: usize = if (is_complex) 16 else 8;
        const size = try std.math.mul(usize, try std.math.mul(usize, rows, cols), width);
        if (size > bytes.len - pos) return error.TruncatedRaw;
        const data = std.mem.bytesAsSlice(f64, bytes[pos..][0..size]);
        for (data) |v| if (!std.math.isFinite(v)) return error.NonfiniteOutput;
        try plots.append(a, .{ .name = name orelse return error.InvalidRawHeader, .names = names, .rows = rows, .complex = is_complex, .data = data });
        pos += size;
    }
    if (plots.items.len == 0) return error.MissingPlots;
    return plots.toOwnedSlice(a);
}

fn number(value: Json) !f64 {
    const n: f64 = switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => return error.InvalidOracle,
    };
    if (!std.math.isFinite(n)) return error.InvalidOracle;
    return n;
}
fn string(value: Json) ![]const u8 {
    return if (value == .string) value.string else error.InvalidOracle;
}
fn array(value: Json) ![]const Json {
    return if (value == .array) value.array.items else error.InvalidOracle;
}
fn field(value: Json, key: []const u8) !Json {
    if (value != .object) return error.InvalidOracle;
    return value.object.get(key) orelse error.InvalidOracle;
}
fn scalar(value: Json) !Complex {
    if (value != .array) return .init(try number(value), 0);
    const pair = try array(value);
    if (pair.len != 2) return error.InvalidOracle;
    return .init(try number(pair[0]), try number(pair[1]));
}
/// |actual - expected| <= atol + rtol * |expected|, on the complex plane.
fn close(actual: Complex, expected: Complex, rtol: f64, atol: f64) bool {
    return std.math.hypot(actual.re - expected.re, actual.im - expected.im) <= atol + rtol * std.math.hypot(expected.re, expected.im);
}
fn tolerance(rtol: f64, atol: f64) !void {
    if (!std.math.isFinite(rtol) or !std.math.isFinite(atol) or rtol < 0 or atol < 0) return error.InvalidOracle;
}

fn validateOracle(oracle: Oracle) !void {
    if (oracle.schema_version != 1 or oracle.netlist_sha256.len != 64) return error.InvalidOracle;
    if (oracle.expect.status == .@"error") {
        if (oracle.expect.category == null) return error.InvalidOracle;
        return;
    }
    if (oracle.expect.plots.len == 0 and oracle.expect.checks.len == 0) return error.EmptyOracle;
    for (oracle.expect.plots) |p| {
        if (p.match != .samples and p.row_count == null) return error.InvalidOracle;
        if (p.match == .samples and p.axis == null) return error.InvalidOracle;
        const count: usize = if (p.match == .selected_rows) p.row_indices.len else if (p.axis) |axis| axis.values.len else p.row_count.?;
        if (p.match == .exact or p.match == .unordered) if (count != p.row_count.?) return error.InvalidOracle;
        if (p.match == .selected_rows) for (p.row_indices, 0..) |index, i| {
            if (index >= p.row_count.? or (i > 0 and index <= p.row_indices[i - 1])) return error.InvalidOracle;
        };
        if (p.axis) |axis| {
            try tolerance(axis.rtol, axis.atol);
            if (axis.values.len != count) return error.InvalidOracle;
            for (axis.values, 0..) |v, i| {
                if (!std.math.isFinite(v)) return error.InvalidOracle;
                if (p.match == .samples and i > 0 and v <= axis.values[i - 1]) return error.InvalidOracle;
            }
        }
        for (p.columns.map.values()) |col| {
            try tolerance(col.rtol, col.atol);
            if (col.values.len != count) return error.InvalidOracle;
            for (col.values) |v| _ = try scalar(v);
        }
    }
    for (oracle.expect.checks) |check| _ = try checkKind(check);
}

/// Plot names match case-insensitively; espice appends the THD to Fourier titles.
fn plotName(actual: []const u8, expected: []const u8) bool {
    if (equal(actual, expected)) return true;
    // `.four` ends its name with the THD: "Fourier Analysis[ v(out)] (THD = ...)".
    return std.mem.startsWith(u8, expected, "Fourier Analysis") and std.mem.startsWith(u8, actual, expected) and
        std.mem.startsWith(u8, actual[expected.len..], " (THD = ");
}

fn findPlot(plots: []const Plot, name: []const u8) !Plot {
    var found: ?Plot = null;
    for (plots) |p| if (plotName(p.name, name)) {
        if (found != null) return error.AmbiguousPlot;
        found = p;
    };
    return found orelse error.MissingPlot;
}

fn compare(a: Allocator, expected: Expectation, plots: []const Plot) !void {
    const used = try a.alloc(bool, plots.len);
    @memset(used, false);
    for (expected.plots) |p| {
        var chosen: ?usize = null;
        for (plots, 0..) |actual, i| {
            if (used[i] or !plotName(actual.name, p.name)) continue;
            if (p.input_source) |source| {
                // Ngspice carries the source identity in its impedance column.
                // Generic app TF columns use directive order for repeated plots.
                var identified = false;
                var matches = false;
                for (actual.names) |name| if (std.mem.indexOf(u8, name, "#input_impedance")) |end| {
                    identified = true;
                    matches = matches or equal(std.mem.trimStart(u8, name[0..end], "v("), source);
                };
                if (identified and !matches) continue;
            }
            chosen = i;
            break;
        }
        const i = chosen orelse {
            diagnostic("  missing plot: {s}\n", .{p.name});
            return error.MissingPlot;
        };
        used[i] = true;
        comparePlot(a, p, plots[i]) catch |err| {
            diagnostic("  plot: {s}\n", .{p.name});
            return err;
        };
    }
    for (expected.checks) |check| try compareCheck(a, check, plots);
}

fn comparePlot(a: Allocator, expected: ExpectedPlot, actual: Plot) !void {
    for (expected.columns.map.keys()) |name| _ = try actual.column(name);
    if (expected.row_count) |count| if (count != actual.rows) {
        diagnostic("  rows: expected {d}, got {d}\n", .{ count, actual.rows });
        return error.RowCountMismatch;
    };
    if (expected.match == .unordered) {
        const owners = try a.alloc(?u32, actual.rows);
        const seen = try a.alloc(bool, actual.rows);
        @memset(owners, null);
        for (0..actual.rows) |row| {
            @memset(seen, false);
            if (!try assignRow(expected, actual, @intCast(row), owners, seen)) return error.UnmatchedRow;
        }
        return;
    }
    if (expected.axis) |axis| {
        const c = try actual.column(axis.name);
        if (expected.match == .samples) {
            try increasing(actual, c);
        } else {
            for (axis.values, 0..) |v, j| {
                const row = if (expected.match == .selected_rows) expected.row_indices[j] else j;
                try checkValue(axis.name, row, actual.value(row, c), .init(v, 0), axis.rtol, axis.atol);
            }
        }
    }
    for (expected.columns.map.keys(), expected.columns.map.values()) |name, col| {
        const c = actual.column(name) catch |err| {
            diagnostic("  missing/ambiguous column: {s}\n", .{name});
            return err;
        };
        for (col.values, 0..) |v, j| {
            const row = if (expected.match == .selected_rows) expected.row_indices[j] else j;
            const got = if (expected.match == .samples) blk: {
                const axis = expected.axis.?;
                break :blk try sample(actual, try actual.column(axis.name), c, axis.values[j], axis.rtol, axis.atol);
            } else actual.value(row, c);
            const want = (try scalar(v)).mul(.init(perturb, 0));
            if (col.magnitude) {
                try checkValue(name, row, .init(got.magnitude(), 0), .init(want.magnitude(), 0), col.rtol, col.atol);
            } else try checkValue(name, row, got, want, col.rtol, col.atol);
        }
    }
}

// Augmenting paths preserve multiplicity even when tolerance regions overlap.
// Greedily taking the first close root can reject an otherwise valid pairing.
fn assignRow(expected: ExpectedPlot, actual: Plot, row: u32, owners: []?u32, seen: []bool) anyerror!bool {
    for (0..actual.rows) |candidate| {
        if (seen[candidate]) continue;
        var matches = true;
        for (expected.columns.map.keys(), expected.columns.map.values()) |name, col| {
            matches = matches and close(actual.value(candidate, try actual.column(name)), try scalar(col.values[row]), col.rtol, col.atol);
        }
        if (expected.axis) |axis| matches = matches and close(actual.value(candidate, try actual.column(axis.name)), .init(axis.values[row], 0), axis.rtol, axis.atol);
        if (!matches) continue;
        seen[candidate] = true;
        if (owners[candidate]) |previous| if (!try assignRow(expected, actual, previous, owners, seen)) continue;
        owners[candidate] = row;
        return true;
    }
    return false;
}

fn checkValue(name: []const u8, row: usize, actual: Complex, expected: Complex, rtol: f64, atol: f64) !void {
    if (close(actual, expected, rtol, atol)) return;
    diagnostic("  {s}[{d}]: expected ({e},{e}), got ({e},{e}); rtol={e}, atol={e}\n", .{ name, row, expected.re, expected.im, actual.re, actual.im, rtol, atol });
    return error.ValueMismatch;
}

fn increasing(p: Plot, axis: usize) !void {
    if (p.rows == 0) return error.EmptyTimeAxis;
    for (0..p.rows) |r| {
        const t = p.value(r, axis);
        if (t.im != 0 or (r > 0 and t.re <= p.value(r - 1, axis).re)) return error.NonmonotonicAxis;
    }
}

/// Linear interpolation of column `col` at axis value `t`. An endpoint
/// within tolerance of `t` counts as covering it.
fn sample(p: Plot, axis: usize, col: usize, t: f64, rtol: f64, atol: f64) !Complex {
    if (p.rows == 0) return error.MissingSamples;
    const first = p.value(0, axis).re;
    const last = p.value(p.rows - 1, axis).re;
    if (t < first) {
        if (close(.init(first, 0), .init(t, 0), rtol, atol)) return p.value(0, col);
        return error.MissingTimeCoverage;
    }
    if (t > last) {
        if (close(.init(last, 0), .init(t, 0), rtol, atol)) return p.value(p.rows - 1, col);
        return error.MissingTimeCoverage;
    }
    var lo: usize = 0;
    var hi: usize = p.rows - 1;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (p.value(mid, axis).re <= t) lo = mid else hi = mid;
    }
    if (t == p.value(lo, axis).re) return p.value(lo, col);
    if (t == p.value(hi, axis).re) return p.value(hi, col);
    const fraction = (t - p.value(lo, axis).re) / (p.value(hi, axis).re - p.value(lo, axis).re);
    const x = p.value(lo, col);
    const y = p.value(hi, col);
    return .init(x.re + fraction * (y.re - x.re), x.im + fraction * (y.im - x.im));
}

/// `stderr_line`: some stderr line starts with `prefix`, such as a note.
const Check = enum { selected_values, fourier_thd, sample_moments, repeatability, pole_zero_sets, axis_bounds, time_weighted_moments, oscillation, measure, stderr_line };
fn checkKind(check: Json) !Check {
    const kinds = std.StaticStringMap(Check).initComptime(.{
        .{ "selected_values", .selected_values },             .{ "fourier_thd", .fourier_thd },
        .{ "sample_moments", .sample_moments },               .{ "repeatability", .repeatability },
        .{ "pole_zero_sets", .pole_zero_sets },               .{ "axis_bounds", .axis_bounds },
        .{ "time_weighted_moments", .time_weighted_moments }, .{ "oscillation", .oscillation },
        .{ "measure", .measure },                             .{ "stderr_line", .stderr_line },
    });
    return kinds.get(try string(try field(check, "kind"))) orelse error.UnknownCheck;
}
/// A value a stdout line `name = ...` prints, checked on its exact f64 in
/// `doc` (`exactValue`), as the line's 6 or 7 digits cannot hold it:
/// |value - expected| <= atol + rtol * |expected|. The line must print
/// that f64 rounded (`printedAs`).
fn measure(doc: Measures, stdout: []const u8, check: Json) !void {
    const name = try string(try field(check, "name"));
    const expected = try nfield(check, "value");
    const rtol = try nfield(check, "rtol");
    const atol = try nfield(check, "atol");
    try tolerance(rtol, atol);
    const text = printed(stdout, name) orelse {
        diagnostic("  measure {s} not printed\n", .{name});
        return error.MissingMeasure;
    };
    const r = exactValue(doc, name) orelse {
        diagnostic("  measure {s} not in --measures\n", .{name});
        return error.MissingMeasure;
    };
    const got = r.value orelse {
        diagnostic("  measure {s} failed\n", .{name});
        return error.MissingMeasure;
    };
    try printedAs(name, text, got);
    if (close(.init(got, 0), .init(expected * perturb, 0), rtol, atol)) return;
    diagnostic("  measure {s}: expected {e}, got {e}\n", .{ name, expected, got });
    return error.MeasureMismatch;
}
/// The entry whose exact value the stdout line `name = ...` prints, in the
/// line order: an optimized parameter (the summaries print first), a
/// `.meas` result, or a Monte Carlo statistic's `mean(card)`,
/// `sigma(card)`, `min(card)` or `max(card)`.
fn exactValue(doc: Measures, name: []const u8) ?Measured {
    for (doc.optimized) |r| if (equal(r.name, name)) return r;
    for (doc.results) |r| if (equal(r.name, name)) return r;
    const open = std.mem.indexOfScalar(u8, name, '(') orelse return null;
    if (!std.mem.endsWith(u8, name, ")")) return null;
    for (doc.statistics) |s| if (equal(s.kind, "monte") and equal(s.name, name[open + 1 .. name.len - 1])) {
        inline for (.{ "mean", "sigma", "min", "max" }) |f| if (equal(name[0..open], f)) return .{ .name = name, .value = @field(s, f) };
    };
    return null;
}
/// The value of the first stdout line `name = value ...`, as ngspice prints a `.meas` result.
fn printed(stdout: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |text| {
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        if (!equal(std.mem.trim(u8, text[0..eq], " \t"), name)) continue;
        var fields = std.mem.tokenizeAny(u8, text[eq + 1 ..], " \t");
        return fields.next();
    }
    return null;
}
/// `error.MeasurePrint` unless `text` is `exact` rounded: a count, an
/// integer, exactly; else 6 or 7 significant digits (ngspice's `%.5e` and
/// `%e`; which card prints which, src/output/measure/listing.zig's tests
/// pin) within half a unit of the last.
fn printedAs(name: []const u8, text: []const u8, exact: f64) !void {
    const value = std.fmt.parseFloat(f64, text) catch return error.MeasurePrint;
    const e = std.mem.indexOfScalar(u8, text, 'e') orelse text.len;
    const power = if (e == text.len) 0 else std.fmt.parseInt(i32, text[e + 1 ..], 10) catch return error.MeasurePrint;
    var digits: i32 = 0;
    for (text[0..e]) |c| digits += @intFromBool(std.ascii.isDigit(c));
    const unit = std.math.pow(f64, 10, @floatFromInt(power - digits + 1));
    // The slack covers parsing `text` (half an ulp), not a misprint.
    const ok = if (std.mem.indexOfAny(u8, text, ".e") == null) value == exact else (digits == 6 or digits == 7) and @abs(value - exact) <= 0.5 * unit * (1 + 1e-6);
    if (ok) return;
    diagnostic("  measure {s}: printed {s}, its value is {e}\n", .{ name, text, exact });
    return error.MeasurePrint;
}
fn nfield(value: Json, key: []const u8) !f64 {
    return number(try field(value, key));
}
fn between(value: f64, minimum: f64, maximum: f64) !void {
    if (minimum > maximum) return error.InvalidOracle;
    if (std.math.isFinite(value) and value >= minimum and value <= maximum) return;
    diagnostic("  value {e} outside [{e}, {e}]\n", .{ value, minimum, maximum });
    return error.StatisticMismatch;
}

/// |got - expected| <= rtol * |expected| for a quantity measured off a waveform.
fn measured(name: []const u8, got: f64, expected: f64, rtol: f64) !void {
    try tolerance(rtol, 0);
    if (std.math.isFinite(got) and close(.init(got, 0), .init(expected * perturb, 0), rtol, 0)) return;
    diagnostic("  {s}: expected {e}, got {e}; rtol={e}\n", .{ name, expected, got, rtol });
    return error.StatisticMismatch;
}

fn compareCheck(a: Allocator, check: Json, plots: []const Plot) !void {
    const kind = try checkKind(check);
    if (kind == .measure or kind == .stderr_line) return; // runCase reads them off stdout and stderr.
    if (kind == .repeatability) {
        if ((try field(check, "same_netlist")) != .bool or !(try field(check, "same_netlist")).bool or
            !equal(try string(try field(check, "comparison")), "bitwise_numeric_results")) return error.InvalidOracle;
        return; // runCase performs the second subprocess invocation.
    }
    const p = try findPlot(plots, if (kind == .fourier_thd) "Fourier Analysis" else try string(try field(check, "plot")));
    switch (kind) {
        .repeatability, .measure, .stderr_line => unreachable,
        .axis_bounds => {
            const col = try p.column(try string(try field(check, "axis")));
            const minimum = try nfield(check, "minimum");
            const maximum = try nfield(check, "maximum");
            if (p.rows == 0) return error.MissingSamples;
            for (0..p.rows) |r| {
                const v = p.value(r, col);
                if (v.im != 0) return error.ComplexAxis;
                try between(v.re, minimum, maximum);
            }
        },
        .selected_values => {
            const col = try p.column(try string(try field(check, "column")));
            const axis = try p.column(try string(try field(check, "axis")));
            const coordinates = try array(try field(check, "coordinates"));
            const values = try array(try field(check, "values"));
            const atol = try nfield(check, "atol");
            const period = try nfield(check, "period");
            if (coordinates.len != values.len or period <= 0 or atol < 0) return error.InvalidOracle;
            for (coordinates, values) |coordinate, expected| {
                var found: ?usize = null;
                for (0..p.rows) |r| if (p.value(r, axis).re == try number(coordinate)) {
                    if (found != null) return error.AmbiguousCoordinate;
                    found = r;
                };
                const value = p.value(found orelse return error.MissingCoordinate, col);
                const delta = @mod(value.re - try number(expected) + period / 2, period) - period / 2;
                try checkValue(p.names[col], found.?, .init(delta, value.im), .init(0, 0), 0, atol);
            }
        },
        .fourier_thd => {
            const harmonic = try p.column("harmonic");
            const magnitude = try p.column("magnitude");
            var fundamental: ?f64 = null;
            var sum: f64 = 0;
            for (0..p.rows) |r| {
                const h = p.value(r, harmonic).re;
                const v = p.value(r, magnitude);
                if (v.im != 0 or h < 0 or @trunc(h) != h) return error.InvalidHarmonics;
                if (h == 1) {
                    if (fundamental != null) return error.InvalidHarmonics;
                    fundamental = v.re;
                } else if (h > 1) sum += v.re * v.re;
            }
            const f = fundamental orelse return error.MissingFundamental;
            if (f <= 0) return error.MissingFundamental;
            try between(100 * @sqrt(sum) / f, try nfield(check, "percent_min"), try nfield(check, "percent_max"));
        },
        .sample_moments => {
            if (@as(f64, @floatFromInt(p.rows)) != try nfield(check, "row_count") or p.rows < 2) return error.RowCountMismatch;
            const col = try p.column(try string(try field(check, "column")));
            var mean: f64 = 0;
            var m2: f64 = 0;
            for (0..p.rows) |r| {
                const v = p.value(r, col);
                if (v.im != 0) return error.ExpectedRealStatistic;
                const delta = v.re - mean;
                mean += delta / @as(f64, @floatFromInt(r + 1));
                m2 += delta * (v.re - mean);
            }
            try between(mean, try nfield(check, "mean_min"), try nfield(check, "mean_max"));
            try between(@sqrt(m2 / @as(f64, @floatFromInt(p.rows - 1))), try nfield(check, "stddev_min"), try nfield(check, "stddev_max"));
        },
        .time_weighted_moments => {
            const col = try p.column(try string(try field(check, "column")));
            const axis = try p.column("time");
            try increasing(p, axis);
            const window = try array(try field(check, "time_window"));
            if (window.len != 2) return error.InvalidOracle;
            const start = try number(window[0]);
            const stop = try number(window[1]);
            if (stop <= start) return error.InvalidOracle;
            // 1e-12 relative slack: a `10u` t_stop parses to 9.999999999999999e-06 in
            // espice and ngspice alike, one ulp short of a literal 1e-5 window end.
            const slack = 1e-12;
            if (p.value(0, axis).re > start + slack * @abs(start) or
                p.value(p.rows - 1, axis).re < stop - slack * @abs(stop)) return error.MissingTimeCoverage;
            var count: u32 = 0;
            var integral: f64 = 0;
            var square: f64 = 0;
            for (0..p.rows) |r| {
                const t = p.value(r, axis).re;
                if (t >= start and t <= stop) count += 1;
                if (r == 0) continue;
                const left = @max(start, p.value(r - 1, axis).re);
                const right = @min(stop, t);
                if (left >= right) continue;
                const v0 = try sample(p, axis, col, left, 0, 0);
                const v1 = try sample(p, axis, col, right, 0, 0);
                if (v0.im != 0 or v1.im != 0) return error.ExpectedRealStatistic;
                integral += (right - left) * (v0.re + v1.re) / 2;
                square += (right - left) * (v0.re * v0.re + v1.re * v1.re) / 2;
            }
            if (@as(f64, @floatFromInt(count)) < try nfield(check, "min_points")) return error.MissingSamples;
            const mean = integral / (stop - start);
            try between(@abs(mean), 0, try nfield(check, "mean_abs_max"));
            try between(square / (stop - start) - mean * mean, try nfield(check, "variance_min"), try nfield(check, "variance_max"));
        },
        .oscillation => {
            // Period: mean spacing of the rising `level` crossings inside the
            // window, each crossing linearly interpolated. Swing: max - min of
            // the samples inside the window.
            const col = try p.column(try string(try field(check, "column")));
            const axis = try p.column("time");
            try increasing(p, axis);
            const window = try array(try field(check, "time_window"));
            if (window.len != 2) return error.InvalidOracle;
            const start = try number(window[0]);
            const stop = try number(window[1]);
            const level = try nfield(check, "level");
            if (stop <= start) return error.InvalidOracle;
            var first: ?f64 = null;
            var last: f64 = 0;
            var crossings: u32 = 0;
            var lo = std.math.inf(f64);
            var hi = -std.math.inf(f64);
            for (0..p.rows) |r| {
                const t = p.value(r, axis).re;
                const v = p.value(r, col);
                if (v.im != 0) return error.ExpectedRealStatistic;
                if (t < start or t > stop) continue;
                lo = @min(lo, v.re);
                hi = @max(hi, v.re);
                if (r == 0 or p.value(r - 1, axis).re < start) continue;
                const v0 = p.value(r - 1, col).re;
                if (!(v0 < level and v.re >= level)) continue;
                const t0 = p.value(r - 1, axis).re;
                const tc = t0 + (level - v0) / (v.re - v0) * (t - t0);
                if (first == null) first = tc;
                last = tc;
                crossings += 1;
            }
            if (crossings < 3) {
                diagnostic("  {s}: {d} rising crossings of {e} in the window, need 3\n", .{ p.names[col], crossings, level });
                return error.StatisticMismatch;
            }
            const period = (last - first.?) / @as(f64, @floatFromInt(crossings - 1));
            try measured("period", period, try nfield(check, "period"), try nfield(check, "period_rtol"));
            try measured("swing", hi - lo, try nfield(check, "swing"), try nfield(check, "swing_rtol"));
        },
        .pole_zero_sets => {
            const rtol = try nfield(check, "rtol");
            const atol = try nfield(check, "atol");
            try tolerance(rtol, atol);
            const multiplicity = try field(check, "multiplicity");
            if (multiplicity != .bool or !multiplicity.bool) return error.InvalidOracle;
            for ([_][]const u8{ "pole", "zero" }, [_][]const u8{ "poles", "zeros" }) |prefix, key| {
                var roots: std.ArrayList(Complex) = .empty;
                for (p.names, 0..) |name, c| {
                    const bare = if (std.mem.startsWith(u8, name, "v(")) name[2 .. name.len - 1] else name;
                    if (equal(bare, prefix)) {
                        for (0..p.rows) |r| try roots.append(a, p.value(r, c));
                    } else if (std.mem.startsWith(u8, bare, prefix) and bare.len > prefix.len and bare[prefix.len] == '(') {
                        if (p.rows != 1) return error.InvalidRootLayout;
                        try roots.append(a, p.value(0, c));
                    }
                }
                const expected = try array(try field(check, key));
                if (roots.items.len != expected.len) return error.RootCountMismatch;
                var columns: std.json.ArrayHashMap(Column) = .{};
                try columns.map.put(a, prefix, .{ .values = expected, .rtol = rtol, .atol = atol });
                const data = try a.alloc(f64, 2 * roots.items.len);
                for (roots.items, 0..) |root, i| {
                    data[2 * i] = root.re;
                    data[2 * i + 1] = root.im;
                }
                const root_plot: Plot = .{ .name = p.name, .names = &.{prefix}, .rows = @intCast(roots.items.len), .complex = true, .data = data };
                comparePlot(a, .{ .name = p.name, .match = .unordered, .row_count = root_plot.rows, .columns = columns }, root_plot) catch |err| return if (err == error.UnmatchedRow) error.UnmatchedRoot else err;
            }
        },
    }
}

fn repeatable(first: []const Plot, second: []const Plot) !void {
    if (first.len != second.len) return error.NotRepeatable;
    for (first, second) |p, q| {
        if (!equal(p.name, q.name) or p.rows != q.rows or p.complex != q.complex or p.names.len != q.names.len) return error.NotRepeatable;
        for (p.names, q.names) |x, y| if (!equal(x, y)) return error.NotRepeatable;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(p.data), std.mem.sliceAsBytes(q.data))) return error.NotRepeatable;
    }
}

test {
    _ = metamorphic;
    _ = @import("source_class.zig");
}

// Oracle: SHA-256 of each deck against the hash its .expected.json records.
test "every discovered fixture has a valid oracle and matching source hash" {
    try std.testing.expect(spice_files.len > 0);
    for (spice_files, expected_outputs) |path, json| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const oracle = try parseOracle(a, json);
        validateOracle(oracle) catch |err| {
            std.debug.print("invalid oracle: {s}\n", .{path});
            return err;
        };
        const source = try Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/{s}", .{path}), a, .unlimited);
        try std.testing.expectEqualStrings(oracle.netlist_sha256, &sha256Hex(source));
    }
}

// Oracle: a hand-encoded binary raw blob whose values and length are known.
test "raw parser rejects truncated and nonfinite data and reads concatenated plots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const header = "Title: test\nPlotname: AC Analysis\nFlags: complex\nNo. Variables: 2\nNo. Points: 1\nVariables:\n0 frequency frequency\n1 v(out) voltage\nBinary:\n";
    const data = [_]f64{ 1, 0, 0.5, -0.5 };
    const blob = try std.mem.concat(a, u8, &.{ header, std.mem.sliceAsBytes(&data), header, std.mem.sliceAsBytes(&data) });
    const plots = try parseRaw(a, blob);
    try std.testing.expectEqual(@as(usize, 2), plots.len);
    try std.testing.expectEqual(@as(f64, -0.5), plots[1].value(0, 1).im);
    try std.testing.expectError(error.TruncatedRaw, parseRaw(a, blob[0 .. blob.len - 1]));
    const bad = [_]f64{ 1, 0, std.math.nan(f64), 0 };
    try std.testing.expectError(error.NonfiniteOutput, parseRaw(a, try std.mem.concat(a, u8, &.{ header, std.mem.sliceAsBytes(&bad) })));
}

// Oracle: hand-computed linear interpolation (v(out) = 1.5 at t = 0.5) and
// root sets whose valid pairing is known.
test "numeric matching covers row indices, interpolation, phase and multiplicity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"name":"Transient Analysis","match":"samples","axis":{"name":"time","values":[0,0.5,1],"rtol":0,"atol":0},"columns":{"v(out)":{"values":[0,1,2],"rtol":0,"atol":1e-12}}}
    ;
    var expected = try std.json.parseFromSliceLeaky(ExpectedPlot, a, json, .{});
    const p: Plot = .{ .name = "Transient Analysis", .names = &.{ "time", "v(out)" }, .rows = 3, .complex = false, .data = &.{ 0, 0, 0.75, 1.5, 1, 2 } };
    try comparePlot(a, expected, p);
    try std.testing.expectError(error.MissingTimeCoverage, sample(p, 0, 1, -0.1, 0, 0));
    expected.match = .exact;
    expected.row_count = 3;
    try std.testing.expectError(error.ValueMismatch, comparePlot(a, expected, p));
    const selected = try std.json.parseFromSliceLeaky(ExpectedPlot, a,
        \\{"name":"Transient Analysis","match":"selected_rows","row_count":3,"row_indices":[0,2],"columns":{"v(out)":{"values":[0,2],"rtol":0,"atol":0}}}
    , .{});
    try comparePlot(a, selected, p);
    var short = p;
    short.rows = 2;
    try std.testing.expectError(error.RowCountMismatch, comparePlot(a, selected, short));
    try std.testing.expect(!close(.init(0, 1), .init(0, -1), 1e-3, 0));
    try std.testing.expect(!close(.init(1e-9, 0), .init(2e-9, 0), 1e-3, 0));
    const roots = try std.json.parseFromSliceLeaky(ExpectedPlot, a,
        \\{"name":"Pole-Zero Analysis","match":"unordered","row_count":2,"columns":{"pole":{"values":[[-1,0],[-1,0]],"rtol":0,"atol":0}}}
    , .{});
    const duplicate: Plot = .{ .name = "Pole-Zero Analysis", .names = &.{"pole"}, .rows = 2, .complex = true, .data = &.{ -1, 0, -2, 0 } };
    try std.testing.expectError(error.UnmatchedRow, comparePlot(a, roots, duplicate));
    const overlapping = try std.json.parseFromSliceLeaky(ExpectedPlot, a,
        \\{"name":"Pole-Zero Analysis","match":"unordered","row_count":2,"columns":{"pole":{"values":[0,1],"rtol":0,"atol":0.75}}}
    , .{});
    const shuffled: Plot = .{ .name = "Pole-Zero Analysis", .names = &.{"pole"}, .rows = 2, .complex = false, .data = &.{ 0.5, -0.5 } };
    try comparePlot(a, overlapping, shuffled);
    const wrong: Plot = .{ .name = p.name, .names = p.names, .rows = p.rows, .complex = false, .data = &.{ 0, 0, 0.75, 1.5, 1, 3 } };
    try std.testing.expectError(error.NotRepeatable, repeatable(&.{p}, &.{wrong}));
}

// Oracle: closed form: {0, 1, 2} has mean 1 and sample stddev 1.
test "statistical checks measure samples and reject biased output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const check = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"sample_moments","plot":"Monte Carlo","column":"v(out)","row_count":3,"mean_min":0.99,"mean_max":1.01,"stddev_min":0.99,"stddev_max":1.01}
    , .{});
    const p: Plot = .{ .name = "Monte Carlo", .names = &.{"v(out)"}, .rows = 3, .complex = false, .data = &.{ 0, 1, 2 } };
    try compareCheck(a, check, &.{p});
    var biased = p;
    biased.data = &.{ 1, 2, 3 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, check, &.{biased}));
    try std.testing.expectError(error.UnknownCheck, checkKind(try std.json.parseFromSliceLeaky(Json, a, "{\"kind\":\"typo\"}", .{})));
}

// Oracle: hand-written stderr and exit codes with a known category.
test "invalid decks require the intended diagnostic instead of arbitrary failure" {
    try checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error: example.sp: InvalidQueryOptions\n") });
    try std.testing.expectError(error.WrongDiagnostic, checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error: ModelNotFound\n") }));
    try std.testing.expectError(error.WrongDiagnostic, checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error: InvalidQueryOptions.sp: ModelNotFound\n") }));
    try std.testing.expectError(error.ExpectedDiagnosticExit, checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 2 }, .stdout = @constCast(""), .stderr = @constCast("Usage: espice FILE\n") }));
}

// Oracle: a script that sleeps 5 s against a 1 s deadline must time out.
test "deadline kills a simulator that closes output streams before hanging" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "simulator", .data = "#!/bin/sh\nexec 1>&- 2>&-\nexec sleep 5\n", .flags = .{ .permissions = .fromMode(0o755) } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app = try tmp.dir.realPathFileAlloc(io, "simulator", a);
    try std.testing.expectError(error.Timeout, simulate(a, io, app, "tests/conformance/tests/netlist/op/divider_default.sp", "/dev/null", 1, null));
}

// Oracle: a script that prints the allocator's leak line and exits 0 must
// fail, and the same script without that line must pass.
test "a run whose allocator reports a leak fails, whatever its exit code" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "leaky", .data = "#!/bin/sh\necho 'error(SafeAllocator): leaked [addr: 1, len: 8 (0x8) align: 8] allocated at:' >&2\n", .flags = .{ .permissions = .fromMode(0o755) } });
    try tmp.dir.writeFile(io, .{ .sub_path = "clean", .data = "#!/bin/sh\necho 'warning: unrelated' >&2\n", .flags = .{ .permissions = .fromMode(0o755) } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deck = "tests/conformance/tests/netlist/op/divider_default.sp";
    try std.testing.expectError(error.MemoryLeaked, simulate(a, io, try tmp.dir.realPathFileAlloc(io, "leaky", a), deck, "/dev/null", 10, null));
    try requireSuccess(try simulate(a, io, try tmp.dir.realPathFileAlloc(io, "clean", a), deck, "/dev/null", 10, null));
}

// Oracle: ngspice 44.2's own lines for 4*sqrt(6), a PARAM card at %.5e
// (tran/meas_param_expr), and C's %e of 1/3; a .check count is an integer.
test "a measure compares the exact --measures value, and its line must print it rounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const check = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"measure","name":"c","value":9.797958971132712,"rtol":1e-12,"atol":0}
    , .{});
    const exact = [_]Measured{.{ .name = "c", .value = 9.797958971132712 }};
    try measure(.{ .results = &exact }, "c                   =  9.79796e+00\n", check);
    try std.testing.expectError(error.MeasureMismatch, measure(.{ .results = &.{.{ .name = "c", .value = 9.79796 }} }, "c = 9.79796e+00\n", check));
    try std.testing.expectError(error.MeasurePrint, measure(.{ .results = &exact }, "c = 9.79797e+00\n", check));
    try std.testing.expectError(error.MeasurePrint, measure(.{ .results = &exact }, "c = 9.798e+00\n", check));
    try std.testing.expectError(error.MissingMeasure, measure(.{ .results = &.{.{ .name = "c", .value = null }} }, "c = 9.79796e+00\n", check));
    try std.testing.expectError(error.MissingMeasure, measure(.{ .results = &.{} }, "c = 9.79796e+00\n", check));
    try printedAs("t", "3.333333e-01", 1.0 / 3.0);
    try printedAs("n", "2", 2);
    try std.testing.expectError(error.MeasurePrint, printedAs("n", "2", 3));
    // An optimizer's line (Zig's {e:.6}) reads `optimized`, `mean(c)` a Monte Carlo statistic.
    try measure(.{ .results = &.{}, .optimized = &exact }, "  c = 9.797959e0 $ initial 1.000000e1\n", check);
    const mean = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"measure","name":"mean(c)","value":9.797958971132712,"rtol":1e-12,"atol":0}
    , .{});
    try measure(.{ .results = &exact, .statistics = &.{.{ .kind = "monte", .name = "c", .mean = 9.797958971132712 }} }, "mean(c) = 9.797959e+00\n", mean);
}

// Oracle: a triangle wave whose period and swing are known by construction.
test "oscillation check measures period and swing and rejects a slow or stalled waveform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A 0..1 V triangle with a 2 s period: rising 0.5 V crossings at 0.5, 2.5, 4.5, 6.5.
    const tri: Plot = .{ .name = "Transient Analysis", .names = &.{ "time", "v(1)" }, .rows = 8, .complex = false, .data = &.{ 0, 0, 1, 1, 2, 0, 3, 1, 4, 0, 5, 1, 6, 0, 7, 1 } };
    const check = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"oscillation","plot":"Transient Analysis","column":"v(1)","level":0.5,"time_window":[0,7],"period":2,"period_rtol":1e-3,"swing":1,"swing_rtol":1e-3}
    , .{});
    try compareCheck(a, check, &.{tri});
    var slow = tri;
    slow.data = &.{ 0, 0, 1, 1, 2, 0, 3, 1, 4, 0, 5, 1, 6.2, 0, 6.9, 1 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, check, &.{slow}));
    var small = tri;
    small.data = &.{ 0, 0.1, 1, 1, 2, 0.1, 3, 1, 4, 0.1, 5, 1, 6, 0.1, 7, 1 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, check, &.{small}));
    var stalled = tri;
    stalled.data = &.{ 0, 0.7, 1, 0.7, 2, 0.7, 3, 0.7, 4, 0.7, 5, 0.7, 6, 0.7, 7, 0.7 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, check, &.{stalled}));
}

// Oracle: analytic integrals of piecewise-linear waveforms, a spectrum with
// a known THD, and hand-placed roots.
test "time statistics, phase wrap, THD, axis bounds and root sets are enforced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const waveform: Plot = .{ .name = "Transient Noise Analysis", .names = &.{ "time", "v(out)" }, .rows = 3, .complex = false, .data = &.{ 0, -1, 0.5, 1, 1, -1 } };
    const moments = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"time_weighted_moments","plot":"Transient Noise Analysis","column":"v(out)","time_window":[0,1],"min_points":3,"mean_abs_max":0.01,"variance_min":0.99,"variance_max":1.01}
    , .{});
    try compareCheck(a, moments, &.{waveform});
    var silent = waveform;
    silent.data = &.{ 0, 0, 0.5, 0, 1, 0 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, moments, &.{silent}));
    var ulp_short = waveform;
    ulp_short.data = &.{ 0, -1, 0.5, 1, 1 - 1e-16, -1 };
    try compareCheck(a, moments, &.{ulp_short});
    var short = waveform;
    short.data = &.{ 0, -1, 0.5, 1, 1 - 1e-9, -1 };
    try std.testing.expectError(error.MissingTimeCoverage, compareCheck(a, moments, &.{short}));
    const bounds = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"axis_bounds","plot":"Transient Noise Analysis","axis":"time","minimum":0.5,"maximum":1}
    , .{});
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, bounds, &.{waveform}));
    const spectrum: Plot = .{ .name = "Fourier Analysis (THD = 0.0000 %)", .names = &.{ "harmonic", "magnitude", "phase_deg" }, .rows = 3, .complex = false, .data = &.{ 0, 0, 0, 1, 1, 270, 2, 0, 0 } };
    const phase = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"selected_values","plot":"Fourier Analysis","axis":"harmonic","coordinates":[1],"column":"phase_deg","values":[-90],"atol":0.01,"period":360}
    , .{});
    try compareCheck(a, phase, &.{spectrum});
    const thd = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"fourier_thd","percent_min":0,"percent_max":0.1}
    , .{});
    try compareCheck(a, thd, &.{spectrum});
    var distorted = spectrum;
    distorted.data = &.{ 0, 0, 0, 1, 1, 270, 2, 0.1, 0 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, thd, &.{distorted}));
    const roots: Plot = .{ .name = "Pole-Zero Analysis", .names = &.{ "pole(1)", "zero(1)", "pole(2)" }, .rows = 1, .complex = true, .data = &.{ -2, 0, 0, 0, -1, 0 } };
    const sets = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"pole_zero_sets","plot":"Pole-Zero Analysis","poles":[[-1,0],[-2,0]],"zeros":[[0,0]],"rtol":0,"atol":0,"multiplicity":true}
    , .{});
    try compareCheck(a, sets, &.{roots});
    var wrong = roots;
    wrong.data = &.{ -2, 0, 0, 0, -2, 0 };
    try std.testing.expectError(error.UnmatchedRoot, compareCheck(a, sets, &.{wrong}));
}
