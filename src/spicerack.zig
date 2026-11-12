//! A deck in another dialect, translated by SpiceRack before ESPice reads a
//! byte of it. In: the deck's path, its dialect (named, or detected from its
//! text), the `spice2rack` binary. Out: a fresh temporary directory holding
//! SpiceRack's ngspice translation of the deck and every file it includes,
//! the translated entry's path, and SpiceRack's wall time; on stderr,
//! SpiceRack's own notes and one timing line. The library reads only its
//! ngspice dialect and never spawns a process: the CLI owns this step, and
//! the corpus runner reaches it through the CLI.
//! Cites: SpiceRack's `spice2rack --dialect D --to espice --kit -o DIR DECK`
//! contract (the entry's path as the only stdout line; exit 0 ok, 1 a
//! refused construct, 2 usage); dev/research/{hspice,spectre}-syntax.md
//! (`detect`'s markers), the corpus decks' `tokenizer` fields (its oracle).
//!
//! Contents:
//! - `pub const Dialect = enum { ngspice, hspice, spectre, ltspice, xyce, vacask }`
//! - `pub const Request = struct`
//! - `pub const Kit = struct`
//! - `pub fn deinit(kit: *Kit, gpa: Allocator, io: Io) void`
//! - `pub const Detection = struct`
//! - `pub fn parseDialect(name: []const u8) ?Dialect`
//! - `pub fn detect(text: []const u8) Detection`
//! - `pub fn translate(gpa: Allocator, io: Io, request: Request, log: *Io.Writer) !Kit`
//! - `pub fn seconds(d: Io.Duration) f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A netlist dialect: ngspice is read as is, every other one through
/// SpiceRack (`spice2rack --dialect <tag>`).
pub const Dialect = enum { ngspice, hspice, spectre, ltspice, xyce, vacask };

/// One translation: what to run and where its output goes.
pub const Request = struct {
    /// The `spice2rack` binary: a path, or a name looked up on PATH.
    exe: []const u8,
    /// Never `.ngspice` (asserted): an ngspice deck needs no translation.
    dialect: Dialect,
    /// The user's deck, as given on the command line (relative to the cwd):
    /// the name ESPice's own lines use.
    deck: []const u8,
    /// The deck's real path (`realpath` of `deck`), which spice2rack opens:
    /// `/dev/stdin` redirected from a file names that file.
    path: []const u8,
    /// The directory the kit's own directory is made in (`TMPDIR`, `/tmp`).
    tmp_dir: []const u8,
};

/// A translated deck. `dir` and `entry` are owned, in the `gpa` passed to
/// `translate`; `deinit` deletes `dir` and frees both.
pub const Kit = struct {
    /// The fresh directory SpiceRack wrote into.
    dir: []const u8,
    /// The translated deck to read, under `dir`: SpiceRack's stdout line.
    /// Its includes resolve against it, so they find the translated copies.
    entry: []const u8,
    /// SpiceRack's wall time, by the monotonic clock.
    elapsed: Io.Duration,

    /// Deletes the kit's directory, then frees `dir` and `entry`. A failed
    /// delete leaves the directory behind: nothing reads it again.
    pub fn deinit(kit: *Kit, gpa: Allocator, io: Io) void {
        Io.Dir.cwd().deleteTree(io, kit.dir) catch {};
        gpa.free(kit.entry);
        gpa.free(kit.dir);
        kit.* = undefined;
    }
};

/// What `detect` found: the dialect, and for any but ngspice the 1-based
/// line and the text that decided it, a slice of the deck.
pub const Detection = struct {
    dialect: Dialect,
    line: u32 = 0,
    marker: []const u8 = "",
};

/// The dialect a CLI name or short alias (`ng`, `hs`, `scs`) selects; null
/// for any other text.
pub fn parseDialect(name: []const u8) ?Dialect {
    return std.StaticStringMap(Dialect).initComptime(.{
        .{ "ngspice", .ngspice }, .{ "ng", .ngspice },
        .{ "hspice", .hspice },   .{ "hs", .hspice },
        .{ "spectre", .spectre }, .{ "scs", .spectre },
        .{ "ltspice", .ltspice }, .{ "xyce", .xyce },
        .{ "vacask", .vacask },
    }).get(name);
}

/// The dialect a deck's own text is in. Spectre: `simulator lang=` or a
/// `name (nodes) master` instance. HSPICE: a spelling ESPice's own reader
/// refuses and SpiceRack writes in ngspice's form, all of which
/// ngspice-44.2 stops on too: `.dcvolt`, `.temperature`, a `.dc` keyed by
/// `start=`, a P card's `port=`. A deck ESPice runs as written therefore
/// never detects (the tests pin both halves), and anything else is
/// ngspice: ESPice's own HSPICE cards (`.data`, `.alter`, `sweep monte=`)
/// and HSPICE decks in ngspice's syntax included, whose meaning can still
/// differ, as TNOM does: name `--tokenizer` for those. Reads neither the
/// title line nor the includes; never answers LTspice, Xyce or VACASK.
pub fn detect(text: []const u8) Detection {
    var found: Detection = .{ .dialect = .ngspice };
    var card: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.ascii.startsWithIgnoreCase(line, "simulator") and std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, line[9..], " \t"), "lang"))
            return .{ .dialect = .spectre, .line = n, .marker = line };
        if (n == 1 or line.len == 0 or line[0] == '*') continue;
        var rest = line;
        if (line[0] == '+') rest = line[1..] else {
            const end = std.mem.indexOfAny(u8, line, " \t(") orelse line.len;
            card = line[0..end];
            rest = line[end..];
            // `r1 (a b) resistor`: Spectre's instance form.
            const tail = std.mem.trimStart(u8, rest, " \t");
            if (std.ascii.isAlphabetic(line[0]) and tail.len != 0 and tail[0] == '(') if (std.mem.indexOfScalar(u8, tail, ')')) |close| {
                const after = tail[close + 1 ..];
                const master = std.mem.trimStart(u8, after, " \t");
                if (master.len != 0 and master.len < after.len and std.ascii.isAlphabetic(master[0]))
                    return .{ .dialect = .spectre, .line = n, .marker = line };
            };
            // Past the first HSPICE marker only a Spectre one can change
            // the answer.
            if (found.dialect == .hspice) continue;
            if (std.ascii.eqlIgnoreCase(card, ".dcvolt") or std.ascii.eqlIgnoreCase(card, ".temperature")) {
                found = .{ .dialect = .hspice, .line = n, .marker = card };
                continue;
            }
        }
        if (found.dialect == .hspice) continue;
        // `.dc v1 start=0 stop=1 step=0.1`, `p1 a 0 port=1 z0=50`.
        const key: []const u8 = if (std.ascii.eqlIgnoreCase(card, ".dc")) "start=" else if (card.len != 0 and (card[0] == 'p' or card[0] == 'P')) "port=" else continue;
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        while (words.next()) |w| if (std.ascii.startsWithIgnoreCase(w, key)) {
            found = .{ .dialect = .hspice, .line = n, .marker = w };
            break;
        };
    }
    return found;
}

/// Runs `request.exe --dialect D --to espice --kit -o DIR PATH` into a
/// fresh `request.tmp_dir/espice-spicerack-<hex>` and returns the kit; the
/// caller reads `kit.entry` as its ngspice deck and calls `deinit` after
/// the run. Writes SpiceRack's stderr to `log` as it came, then, on
/// success, `espice: spicerack translated DECK (D -> ngspice, N files) in
/// S s`, or on failure `error: spicerack: DECK: COMMAND: REASON`. Never
/// falls back to reading the deck as ngspice. Asserts `request.dialect` is
/// not `.ngspice`. Fails with `error.SpiceRackNotFound` when the binary
/// cannot be started (missing, not executable), `error.SpiceRackFailed`
/// when it exits non-zero, dies, or writes past 64 KiB of stdout or 1 MiB
/// of stderr, `error.SpiceRackNoEntry` when it prints no single existing
/// path; a temporary-directory, walk, write or allocation error otherwise.
/// Every failure deletes the directory first.
pub fn translate(gpa: Allocator, io: Io, request: Request, log: *Io.Writer) !Kit {
    assert(request.dialect != .ngspice);
    assert(request.deck.len != 0 and request.path.len != 0 and request.exe.len != 0);
    const dir = blk: {
        var random: [8]u8 = undefined;
        io.random(&random);
        break :blk try std.fmt.allocPrint(gpa, "{s}/espice-spicerack-{s}", .{ request.tmp_dir, std.fmt.bytesToHex(random, .lower) });
    };
    errdefer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const argv = [_][]const u8{ request.exe, "--dialect", @tagName(request.dialect), "--to", "espice", "--kit", "-o", dir, request.path };
    const start = Io.Timestamp.now(io, .awake);
    const result = std.process.run(gpa, io, .{ .argv = &argv, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 20) }) catch |err| {
        try refuse(log, request.deck, &argv, @errorName(err));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.InvalidExe, error.IsDir, error.NotDir => error.SpiceRackNotFound,
            // else: a limit or a system error, past what SpiceRack's exit says.
            else => error.SpiceRackFailed,
        };
    };
    const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try log.writeAll(result.stderr);
    if (!result.term.success()) {
        var code: [16]u8 = undefined;
        try refuse(log, request.deck, &argv, switch (result.term) {
            .exited => |c| std.fmt.bufPrint(&code, "exit {d}", .{c}) catch unreachable,
            // else: killed or stopped, which no exit code says.
            else => @tagName(result.term),
        });
        return error.SpiceRackFailed;
    }
    const line = std.mem.trim(u8, result.stdout, " \t\r\n");
    const single = line.len != 0 and std.mem.indexOfScalar(u8, line, '\n') == null;
    if (!single) {
        try refuse(log, request.deck, &argv, "no entry path on stdout");
        return error.SpiceRackNoEntry;
    }
    Io.Dir.cwd().access(io, line, .{}) catch |err| {
        try refuse(log, request.deck, &argv, @errorName(err));
        return error.SpiceRackNoEntry;
    };
    const files = try countFiles(gpa, io, dir);
    const entry = try gpa.dupe(u8, line);
    try log.print("espice: spicerack translated {s} ({t} -> ngspice, {d} files) in {d:.2} s\n", .{ request.deck, request.dialect, files, seconds(elapsed) });
    assert(files >= 1);
    return .{ .dir = dir, .entry = entry, .elapsed = elapsed };
}

/// `d` in seconds, for the timing lines.
pub fn seconds(d: Io.Duration) f64 {
    return @as(f64, @floatFromInt(d.nanoseconds)) / 1e9;
}

// ---- private ----

/// The refusal line: the deck, the command as run, why.
fn refuse(log: *Io.Writer, deck: []const u8, argv: []const []const u8, reason: []const u8) Io.Writer.Error!void {
    try log.print("error: spicerack: {s}:", .{deck});
    for (argv) |arg| try log.print(" {s}", .{arg});
    try log.print(": {s}\n", .{reason});
}

/// The regular files under `dir`: the entry and every include SpiceRack wrote.
fn countFiles(gpa: Allocator, io: Io, dir: []const u8) !u32 {
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(gpa);
    defer walker.deinit();
    var files: u32 = 0;
    while (try walker.next(io)) |e| files += @intFromBool(e.kind == .file);
    return files;
}

test parseDialect {
    try std.testing.expectEqual(Dialect.spectre, parseDialect("scs").?);
    try std.testing.expectEqual(Dialect.ngspice, parseDialect("ngspice").?);
    try std.testing.expectEqual(Dialect.vacask, parseDialect("vacask").?);
    // Only the listed names and aliases, no prefixes.
    try std.testing.expectEqual(null, parseDialect("h"));
    try std.testing.expectEqual(null, parseDialect(""));
}

test detect {
    try std.testing.expectEqual(Dialect.ngspice, detect("t\nv1 a 0 1\nr1 a 0 {2*rv}\n.tran 1n 1u\n.meas tran x max v(a)\n.end\n").dialect);
    // ESPice's own HSPICE cards, and ngspice's `.lib file section`, run as
    // written; the title line may say anything.
    for ([_][]const u8{
        "t\n.param rl=1k\n.data rows rl\n+ 1k\n.enddata\n.dc data=rows\n.end\n",
        "t\nr1 a 0 1k\n.tran 1n 1u\n+ sweep monte=10\n.end\n",
        "t\n.lib 'models.lib' tt\n* .dcvolt in a comment\n.op\n",
        ".dcvolt in the title\nv1 a 0 1\n.op\n",
    }) |deck| try std.testing.expectEqual(Dialect.ngspice, detect(deck).dialect);
    const hs = detect("t\nv1 a 0 1\n.dc v1\n+ START=0 stop=1 step=0.5\n.end\n");
    try std.testing.expectEqualDeep(Detection{ .dialect = .hspice, .line = 4, .marker = "START=0" }, hs);
    try std.testing.expectEqual(Dialect.spectre, detect("simulator lang=spectre\nr1 (a 0) resistor r=1k\n").dialect);
    const scs = detect("title\nr1 (out 0) resistor r=1k\nt1 tran stop=1u\n");
    try std.testing.expectEqual(Dialect.spectre, scs.dialect);
    try std.testing.expectEqual(@as(u32, 2), scs.line);
}

// Oracle: ESPice's own reader, and ngspice-44.2, which stops on each deck
// too (measured): every HSPICE marker is a deck that cannot run as
// written, so detection never takes one from the native reader.
test "detect: every HSPICE marker is refused by the native reader" {
    const api = @import("espice");
    for ([_][]const u8{
        "t\nv1 a 0 1\nr1 a 0 1k\n.dcvolt a 1\n.op\n.end\n",
        "t\nv1 a 0 1\nr1 a 0 1k\n.temperature 50\n.op\n.end\n",
        "t\nv1 a 0 1\nr1 a 0 1k\n.dc v1 start=0 stop=1 step=0.5\n.end\n",
        "t\nv1 a 0 1\nr1 a 0 1k\np1 a 0 port=1 z0=50\n.op\n.end\n",
    }) |deck| {
        try std.testing.expectEqual(Dialect.hspice, detect(deck).dialect);
        const p = api.Problem.init(std.testing.allocator, std.testing.io, .{ .source = .{ .bytes = .{ .data = deck, .origin = "marker.sp" } } }) catch continue;
        p.deinit();
        std.debug.print("ran natively, yet detected:\n{s}", .{deck});
        return error.TestExpectedError;
    }
}

// Every corpus deck whose oracle names no tokenizer reads as ngspice, and
// a deck detected as HSPICE or Spectre is one: the markers are precise.
// No recall bound: most HSPICE decks of the corpus use only cards ESPice
// reads as written, which `detect` leaves to the native reader.
test "detect: no false positive over the corpus" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/conformance/tests/netlist", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var decks: usize = 0;
    while (try walker.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".expected.json")) continue;
        const json = try dir.readFileAlloc(io, entry.path, a, .limited(1 << 24));
        defer a.free(json);
        const deck_path = try std.mem.concat(a, u8, &.{ entry.path[0 .. entry.path.len - ".expected.json".len], ".sp" });
        defer a.free(deck_path);
        const deck = dir.readFileAlloc(io, deck_path, a, .limited(1 << 26)) catch continue;
        defer a.free(deck);
        const wanted: Dialect = for ([_]Dialect{ .hspice, .spectre }) |d| {
            if (std.mem.indexOf(u8, json, switch (d) {
                .hspice => "\"tokenizer\": \"hspice\"",
                else => "\"tokenizer\": \"spectre\"",
            }) != null) break d;
        } else .ngspice;
        const got = detect(deck);
        if (got.dialect != .ngspice and got.dialect != wanted)
            std.debug.print("{s}:{d}: `{s}` detects {t}, its oracle reads {t}\n", .{ deck_path, got.line, got.marker, got.dialect, wanted });
        try std.testing.expect(got.dialect == .ngspice or got.dialect == wanted);
        decks += 1;
    }
    // A walk that read no deck checked nothing.
    try std.testing.expect(decks > 100);
}

// Oracle: the contract's own failure modes, each from a binary that cannot
// be a SpiceRack (a missing path, `false`); the directory is gone after.
test "translate: a missing binary and a failing one, never a kit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var log: Io.Writer.Allocating = .init(a);
    defer log.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer a.free(root);
    const missing: Request = .{ .exe = "/nonexistent/spice2rack", .dialect = .hspice, .deck = "deck.sp", .path = "/work/deck.sp", .tmp_dir = root };
    try std.testing.expectError(error.SpiceRackNotFound, translate(a, io, missing, &log.writer));
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "error: spicerack: deck.sp: /nonexistent/spice2rack --dialect hspice --to espice --kit -o ") != null);
    const failing: Request = .{ .exe = "false", .dialect = .spectre, .deck = "deck.scs", .path = "/work/deck.scs", .tmp_dir = root };
    try std.testing.expectError(error.SpiceRackFailed, translate(a, io, failing, &log.writer));
    try std.testing.expect(std.mem.indexOf(u8, log.written(), ": exit 1\n") != null);
    // Neither left its kit directory behind.
    var it = tmp.dir.iterate();
    try std.testing.expectEqual(null, try it.next(io));
}
