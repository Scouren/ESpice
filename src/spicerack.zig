//! A deck in another dialect, translated by SpiceRack before ESPice reads a
//! byte of it. In: the deck's path, its dialect (named, or detected from its
//! text), the `spice2rack` binary. Out: a fresh temporary directory holding
//! SpiceRack's ngspice translation of the deck and every file it includes,
//! the translated entry's path, and SpiceRack's wall time; on stderr,
//! SpiceRack's own notes and one timing line. The library reads only its
//! ngspice dialect and never spawns a process: the CLI owns this step, and
//! the corpus runner reaches it through the CLI.
//! Cites: SpiceRack's `spice2rack --dialect D --to espice --kit -o DIR DECK`
//! contract (the entry's path as the only stdout line; exit 0 ok, 1 a deck
//! failed, 2 usage, 3 the input refused (SpiceRack ledger P8-324); a
//! refused file prints `PATH: D refused:` and then its coded
//! `NAME:LINE:COL: CODE text` lines; a panic exits 101: spice2rack.rs at
//! e2ad5d7, measured, which exits 1 for a refusal too);
//! dev/research/{hspice,spectre}-syntax.md
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

/// HSPICE cards `detect` takes as markers: spellings of ngspice cards
/// (`.dcvolt`, `.temperature`) and of cards ESPice reads under another name
/// (`.pss`, `.pac`, `.pnoise`, `.pxf`, `.pss v(osc)`, `.hb v(osc)`,
/// `.noise`, `.meas`, `.stim`, `.meas ... jitter`; card_table.zig `cards`).
const hspice_cards = [_][]const u8{ ".dcvolt", ".temperature", ".sn", ".snac", ".snnoise", ".snxf", ".snosc", ".hbosc", ".acphasenoise", ".power", ".stimuli", ".jitter" };

/// HSPICE's E and G modifiers `detect` takes as markers. ngspice-44.2 stops
/// on each (measured): after VALUE, "Undefined parameter [scale]" and, for
/// the function names, "Expression err: max}) ... Cannot compute
/// substitute"; after a gain, "MIF-ERROR ... Bad real value".
const eg_modifiers = [_][]const u8{ "scale=", "max=", "min=", "abs=" };

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
/// ngspice-44.2 stops on too: a card in `hspice_cards` (`.dcvolt`,
/// `.temperature`, and the renames of ESPice cards, `.sn` ... `.jitter`),
/// a `.dc` keyed by `start=`, a P card's `port=`, an E or G card's
/// `eg_modifiers` (`scale=`, `max=`, `min=`, `abs=`). A deck ESPice runs as
/// written therefore never detects (the tests pin both halves), and
/// anything else is ngspice: ESPice's own HSPICE cards (`.data`, `.alter`,
/// `sweep monte=`) and HSPICE decks in ngspice's syntax included, whose
/// meaning can still differ, as TNOM does: name `--tokenizer` for those.
/// Reads neither the title line nor the includes; never answers LTspice,
/// Xyce or VACASK.
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
            if (for (hspice_cards) |c| {
                if (std.ascii.eqlIgnoreCase(card, c)) break true;
            } else false) {
                found = .{ .dialect = .hspice, .line = n, .marker = card };
                continue;
            }
        }
        if (found.dialect == .hspice) continue;
        // `.dc v1 start=0 stop=1 step=0.1`, `p1 a 0 port=1 z0=50`,
        // `e1 o 0 value={2*v(a)} scale=3`.
        const keys: []const []const u8 = if (std.ascii.eqlIgnoreCase(card, ".dc")) &.{"start="} else if (card.len == 0) continue else switch (std.ascii.toLower(card[0])) {
            'p' => &.{"port="},
            'e', 'g' => &eg_modifiers,
            else => continue,
        };
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        scan: while (words.next()) |w| for (keys) |key| if (std.ascii.startsWithIgnoreCase(w, key)) {
            found = .{ .dialect = .hspice, .line = n, .marker = w };
            break :scan;
        };
    }
    return found;
}

/// Runs `request.exe --dialect D --to espice --kit -o DIR PATH` into a
/// fresh `request.tmp_dir/espice-spicerack-<hex>` and returns the kit; the
/// caller reads `kit.entry` as its ngspice deck and calls `deinit` after
/// the run. Writes SpiceRack's stderr to `log` as it came, then, on
/// success, `espice: spicerack translated DECK (D -> ngspice, N files) in
/// S s`, on a refusal `error: spicerack: DECK: NAME:LINE:COL: CODE text`
/// (SpiceRack's first coded line), or on another failure `error:
/// spicerack: DECK: COMMAND: REASON`. Never falls back to reading the deck
/// as ngspice. Asserts `request.dialect` is not `.ngspice`. Fails with
/// `error.SpiceRackRefused` when SpiceRack refuses the deck's input (exit
/// 3, or exit 1 with a refused file's coded line: `refusal`),
/// `error.SpiceRackNotFound` when the binary cannot be started (missing,
/// not executable), `error.SpiceRackFailed` when it exits non-zero any
/// other way (an unreadable deck, usage, a panic's 101), dies, or writes
/// past 64 KiB of stdout or 1 MiB of stderr, `error.SpiceRackNoEntry` when
/// it prints no single existing
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
    if (refusal(result.term, result.stderr)) |named| {
        try log.print("error: spicerack: {s}: {s}\n", .{ request.deck, if (named.len != 0) named else "refused, no coded line" });
        return error.SpiceRackRefused;
    }
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

/// What SpiceRack's refusal names when `term` is one: its first coded line,
/// or "" when it printed none. A refusal is exit 3 (P8-324), whatever it
/// printed; or, before P8-324, exit 1 with a `PATH: D refused:` line
/// followed at once by a coded line. Null for every other end, whatever it
/// printed first: exit 1 for an unreadable deck or a failed write, a
/// panic's 101, usage's 2, a signal.
fn refusal(term: std.process.Child.Term, stderr: []const u8) ?[]const u8 {
    const code = switch (term) {
        .exited => |c| c,
        else => return null,
    };
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    switch (code) {
        3 => {
            while (lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (coded(line)) return line;
            }
            return "";
        },
        // ponytail: e2ad5d7 exits 1 for a refusal and for an I/O or read
        // failure alike, so the text tells them apart; delete this prong
        // once the pinned spice2rack includes P8-324 (exit 3).
        1 => {
            var refused = false;
            while (lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (refused and coded(line)) return line;
                refused = std.mem.endsWith(u8, line, " refused:");
            }
            return null;
        },
        else => return null,
    }
}

/// Whether `line` is SpiceRack's coded diagnostic, `NAME:LINE:COL: CODE
/// text`, CODE a capital and four digits (`W0001`): its shape, never a code.
fn coded(line: []const u8) bool {
    var fields = std.mem.splitScalar(u8, line, ':');
    _ = fields.next(); // NAME
    for (0..2) |_| {
        const n = fields.next() orelse return false;
        if (n.len == 0 or std.mem.indexOfNone(u8, n, "0123456789") != null) return false;
    }
    const rest = fields.rest();
    return rest.len > 7 and rest[0] == ' ' and std.ascii.isUpper(rest[1]) and
        std.mem.indexOfNone(u8, rest[2..6], "0123456789") == null and rest[6] == ' ';
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
    // An E or G card's modifier, on the card or its continuation; never
    // another letter's, nor a function inside VALUE.
    const eg = detect("t\nva a 0 0.5\ne1 o 0 value={2*v(a)}\n+ SCALE=3\n.op\n");
    try std.testing.expectEqualDeep(Detection{ .dialect = .hspice, .line = 4, .marker = "SCALE=3" }, eg);
    try std.testing.expectEqual(Dialect.hspice, detect("t\ng1 0 o value={2m*v(a)} max=0.4\n.op\n").dialect);
    try std.testing.expectEqual(Dialect.ngspice, detect("t\ne1 o 0 value={max(2*v(a), 0.4)}\nb1 p 0 v=min(v(a), 1)\nr1 o 0 r=1k abs=1\n.op\n").dialect);
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
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.sn tres=10n period=1u\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.pss 1meg 100\n.snac dec 2 1k 10k\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.pss 1meg 100\n.snnoise v(a) v1 dec 2 1k 10k\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.pss 1meg 100\n.snxf v(a) dec 2 1k 10k\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.snosc v(a) 1meg 64\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.hbosc v(a) 1meg 7\n.end\n",
        "t\nv1 a 0 dc 0 ac 1\nr1 a 0 1k\n.ac dec 2 1k 10k\n.acphasenoise v(a) v1 carrier=1g\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.tran 1n 2u\n.power v1 from=0 to=1u\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.tran 1n 2u\n.stimuli pwl v(a)\n.end\n",
        "t\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.tran 1n 2u\n.jitter tran trig v(a) val=0 td=50n\n.end\n",
        // "Undefined parameter [scale]"; "Expression err: max}) ... Cannot
        // compute substitute" (min=, abs= alike); "MIF-ERROR ... Bad real
        // value" after a gain.
        "t\nva a 0 0.5\ne1 o 0 value={2*v(a)} scale=3\nr1 o 0 1k\n.op\n.end\n",
        "t\nva a 0 0.5\ne1 o 0 value={2*v(a)} max=0.4\nr1 o 0 1k\n.op\n.end\n",
        "t\nva a 0 0.5\ng1 0 o value={2m*v(a)} min=2\nr1 o 0 1k\n.op\n.end\n",
        "t\nva a 0 0.5\ng1 0 o value={2m*v(a)} abs=1\nr1 o 0 1k\n.op\n.end\n",
        "t\nva a 0 0.5\ne1 o 0 a 0 2 scale=3\nr1 o 0 1k\n.op\n.end\n",
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
// The one exception is an aliases/ deck, which pins the native reader's
// refusal of an HSPICE spelling (`unsupported_input`): it is that HSPICE
// deck. No recall bound: most HSPICE decks of the corpus use only cards
// ESPice reads as written, which `detect` leaves to the native reader.
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
        const refused_alias = std.mem.startsWith(u8, entry.path, "aliases/") and std.mem.indexOf(u8, json, "\"unsupported_input\"") != null;
        const precise = got.dialect == .ngspice or got.dialect == wanted or (refused_alias and got.dialect == .hspice);
        if (!precise)
            std.debug.print("{s}:{d}: `{s}` detects {t}, its oracle reads {t}\n", .{ deck_path, got.line, got.marker, got.dialect, wanted });
        try std.testing.expect(precise);
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

// Oracle: spice2rack e2ad5d7's own stderr and exit per class, measured
// (src/bin/spice2rack.rs: `exit((failed > 0) as i32)`, `usage` exits 2, a
// panic 101), and P8-324's exit 3 for a refused input. Only a refusal is
// the input's; a crash or kill after the same text, a coded note above a
// failed write, and an unreadable deck stay SpiceRack's failure. Red
// before: every non-zero exit was `SpiceRackFailed`, so a refused deck
// never read as unsupported input.
test "refusal: exit 3, or exit 1 with a refused file's coded line, and no other end" {
    const refused =
        \\/work/hspice_percent_operator.sp: Espice refused:
        \\hspice_percent_operator:7:1: W0001 a statement kept as another dialect's text
        \\hspice_percent_operator:7:9: P0002 an expression that does not parse
        \\/work/hspice_percent_operator.sp: nothing written: Espice refuses a file of the kit
        \\1 deck(s) failed
        \\
    ;
    try std.testing.expectEqualStrings("hspice_percent_operator:7:1: W0001 a statement kept as another dialect's text", refusal(.{ .exited = 1 }, refused).?);
    // P8-324: exit 3 is the refusal, header or none, under any code.
    try std.testing.expectEqualStrings("deck:2:1: W0336 a refused construct", refusal(.{ .exited = 3 }, "note: kept\ndeck:2:1: W0336 a refused construct\n").?);
    try std.testing.expectEqualStrings("", refusal(.{ .exited = 3 }, "1 deck(s) failed\n").?);
    const panicked = refused ++ "\nthread 'main' panicked at src/bin/spice2rack.rs:279:35:\n";
    for ([_]struct { std.process.Child.Term, []const u8 }{
        .{ .{ .exited = 101 }, panicked },
        .{ .{ .signal = .KILL }, refused },
        .{ .{ .exited = 2 }, refused },
        .{ .{ .exited = 0 }, refused },
        .{ .{ .exited = 1 }, "/work/deck.sp: /work/deck.sp: not found\n1 deck(s) failed\n" },
        .{ .{ .exited = 1 }, "deck:3:1: W0039 a statement only its source simulator has\n/work/deck.sp: No space left on device (os error 28)\n1 deck(s) failed\n" },
        .{ .{ .exited = 1 }, "/work/deck.sp: Espice refused:\n/work/deck.sp: nothing written: Espice refuses a file of the kit\n" },
    }) |case| try std.testing.expectEqual(null, refusal(case[0], case[1]));
}
