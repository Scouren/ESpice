//! The identity rows the placement brief adds to the calibration file
//! (`gpu`, `cpu`, `cpus`, `build`), and the refusal that names the row on
//! which a file must not price this machine and build. Read under lever
//! `p1` only (`machine.loadKeyed`); HEAD's `machine.stale` is untouched.
//! In: the file's rows, and the live machine from sysfs and procfs alone
//! (never the GPU driver) plus this binary's build. Out: `Keys`, and a
//! `Refusal` naming a missing or differing row.
//! Cites: docs/perf_research/08-placement.md sec. 3 (schema, invalidation
//! keys) and sec. 7 questions 4 and 5 (per machine and build; keyed by CPU
//! model, card model and driver, not machine id and card uuid).
//!
//! Contents:
//! - `pub const rows: [4][]const u8`
//! - `pub const Keys = struct` (`parseRow`, `format`)
//! - `pub const Refusal = struct`
//! - `pub fn build() machine.Text`
//! - `pub fn live(root: []const u8, v: machine.Vendor, id: *const machine.Identity) Keys`
//! - `pub fn refusal(file: *const machine.Machine, live_id: *const machine.Identity, live_keys: *const Keys) ?Refusal`

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const abi = @import("device").abi;
const machine = @import("machine.zig");
const Text = machine.Text;
const cards_max = machine.cards_max;

/// The identity rows `Keys` holds, in file order. A file without one of
/// them past the first is refused under `p1` by that name; `gpu` is one
/// row per card, none on a machine without cards.
pub const rows = [_][]const u8{ "gpu", "cpu", "cpus", "build" };

/// What the identity rows say: the machine and the build a calibration
/// was measured on. `seen` marks the rows a parsed file carried.
pub const Keys = struct {
    /// Each card's model name (NVIDIA procfs `Model:`; empty for AMD,
    /// whose kfd node has none), one `gpu` row each, compared as a set.
    gpus: [cards_max]Text = undefined,
    n_gpus: u8 = 0,
    /// `/proc/cpuinfo`'s first `model name`: every host row.
    cpu: Text = .{},
    /// Online CPUs (`/sys/devices/system/cpu/online`), not the affinity
    /// mask, so `taskset` does not make the file stale.
    cpus: u32 = 0,
    /// Optimize mode, CPU target and device ABI (`build`): a Debug binary
    /// never prices with a ReleaseFast file.
    build: Text = .{},
    /// Bit i: row `rows[i]` was present.
    seen: u4 = 0,

    /// Takes the row `key` when it is one of `rows`: true when taken,
    /// false for any other key. `error.Malformed` on a value that does not
    /// parse or one `gpu` row past `cards_max`.
    pub fn parseRow(k: *Keys, key: []const u8, value: []const u8) error{Malformed}!bool {
        assert(k.n_gpus <= cards_max);
        const i = for (rows, 0..) |name, j| {
            if (std.mem.eql(u8, key, name)) break j;
        } else return false;
        switch (i) {
            0 => {
                if (k.n_gpus == cards_max) return error.Malformed;
                k.gpus[k.n_gpus] = Text.init(value) orelse return error.Malformed;
                k.n_gpus += 1;
            },
            1 => k.cpu = Text.init(value) orelse return error.Malformed,
            2 => k.cpus = std.fmt.parseInt(u32, value, 10) catch return error.Malformed,
            3 => k.build = Text.init(value) orelse return error.Malformed,
            else => unreachable,
        }
        k.seen |= @as(u4, 1) << @intCast(i);
        assert(k.n_gpus <= cards_max);
        return true;
    }

    /// Writes one `gpu` row per card and the other rows `seen` marks, so a
    /// file without them formats as it did before `p1`.
    pub fn format(k: *const Keys, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(k.n_gpus <= cards_max);
        for (k.gpus[0..k.n_gpus]) |*g| try w.print("gpu\t{s}\n", .{g.slice()});
        if (k.seen & 2 != 0) try w.print("cpu\t{s}\n", .{k.cpu.slice()});
        if (k.seen & 4 != 0) try w.print("cpus\t{d}\n", .{k.cpus});
        if (k.seen & 8 != 0) try w.print("build\t{s}\n", .{k.build.slice()});
    }
};

/// Why a file must not price: the row's name, and whether the file lacks
/// it (`missing`) or holds another value than the live machine.
pub const Refusal = struct { row: []const u8, missing: bool };

/// This binary's `build` row: optimize mode, CPU model and device ABI
/// version, e.g. `ReleaseFast raptorlake abi42`.
pub fn build() Text {
    const s = comptime std.fmt.comptimePrint("{s} {s} abi{d}", .{ @tagName(builtin.mode), builtin.cpu.model.name, abi.abi_version });
    comptime assert(s.len <= 64);
    return Text.init(s).?;
}

/// The live machine's keys under `root` ("" for the live system, a fake
/// tree in tests), every row marked seen. `id` is `machine.identity`'s
/// read of the same root: one `gpu` row per card it found.
pub fn live(root: []const u8, v: machine.Vendor, id: *const machine.Identity) Keys {
    assert(id.cards <= cards_max);
    var k: Keys = .{ .seen = std.math.maxInt(u4), .build = build() };
    var buf: [4096]u8 = undefined;
    if (machine.readAt(root, "/proc/cpuinfo", &buf)) |t| k.cpu = Text.init(field(t, "model name") orelse "") orelse .{};
    if (machine.readAt(root, "/sys/devices/system/cpu/online", &buf)) |t| k.cpus = countList(std.mem.trim(u8, t, " \t\r\n"));
    switch (v) {
        .nvidia => readNames(root, &k),
        // ponytail: kfd nodes carry no name; one empty `gpu` row per card
        // keeps the count compared. Read the drm product name if a
        // two-model AMD machine appears.
        .amd => {
            for (k.gpus[0..id.cards]) |*g| g.* = .{};
            k.n_gpus = id.cards;
        },
    }
    assert(k.n_gpus <= cards_max);
    return k;
}

/// The first row on which `file` must not price on the live machine: a
/// `rows` row past `gpu` it lacks, then the driver, the card models, the CPU model,
/// the online CPUs, the core lists and the build. Null when it may. Card
/// uuids and the affinity thread count are not compared (sec. 7 q. 5).
pub fn refusal(file: *const machine.Machine, live_id: *const machine.Identity, live_keys: *const Keys) ?Refusal {
    const f = &file.keys;
    assert(f.n_gpus <= cards_max);
    assert(live_keys.n_gpus <= cards_max);
    for (rows[1..], 1..) |name, i| {
        if (f.seen & (@as(u4, 1) << @intCast(i)) == 0) return .{ .row = name, .missing = true };
    }
    const differs = [_]struct { []const u8, bool }{
        .{ "driver", !eql(&file.id.driver, &live_id.driver) },
        .{ "gpu", !sameSet(f.gpus[0..f.n_gpus], live_keys.gpus[0..live_keys.n_gpus]) },
        .{ "cpu", !eql(&f.cpu, &live_keys.cpu) },
        .{ "cpus", f.cpus != live_keys.cpus },
        .{ "p_cpus", !eql(&file.id.p_cpus, &live_id.p_cpus) },
        .{ "e_cpus", !eql(&file.id.e_cpus, &live_id.e_cpus) },
        .{ "build", !eql(&f.build, &live_keys.build) },
    };
    for (differs) |d| if (d[1]) return .{ .row = d[0], .missing = false };
    return null;
}

// ---- private ----

fn eql(a: *const Text, b: *const Text) bool {
    return std.mem.eql(u8, a.slice(), b.slice());
}

/// Whether `a` and `b` hold the same names as multisets.
fn sameSet(a: []const Text, b: []const Text) bool {
    if (a.len != b.len) return false;
    for (a) |*x| {
        var in_a: usize = 0;
        var in_b: usize = 0;
        for (a) |*y| in_a += @intFromBool(eql(x, y));
        for (b) |*y| in_b += @intFromBool(eql(x, y));
        if (in_a != in_b) return false;
    }
    return true;
}

/// The value of the first `key<spaces/tabs>: value` line of `text`.
fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.trim(u8, line[key.len..colon], " \t").len != 0) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
    }
    return null;
}

/// CPUs a kernel CPU list names (`0-15,32-47` is 32); 0 when it does not
/// parse.
fn countList(list: []const u8) u32 {
    var n: u32 = 0;
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        const dash = std.mem.indexOfScalar(u8, part, '-');
        const first = std.fmt.parseInt(u32, part[0 .. dash orelse part.len], 10) catch return 0;
        const last = if (dash) |d| std.fmt.parseInt(u32, part[d + 1 ..], 10) catch return 0 else first;
        if (last < first) return 0;
        n += last - first + 1;
    }
    return n;
}

/// The `Model:` line of each NVIDIA procfs card that has a uuid line, the
/// cards `machine.identity` counts, at most `cards_max`.
fn readNames(root: []const u8, k: *Keys) void {
    if (comptime builtin.os.tag != .linux) return;
    const dir_name = "/proc/driver/nvidia/gpus";
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.mem.printSentinel(&dir_buf, "{s}{s}", .{ root, dir_name }, 0) catch return;
    const dir = std.c.opendir(dir_path) orelse return;
    defer _ = std.c.closedir(dir);
    // Bounded: one entry per card plus `.` and `..`.
    for (0..4 * cards_max) |_| {
        const ent = std.c.readdir(dir) orelse break;
        const name = std.mem.sliceTo(&ent.name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        var path_buf: [600]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}/information", .{ dir_name, name }) catch continue;
        var text_buf: [4096]u8 = undefined;
        const text = machine.readAt(root, p, &text_buf) orelse continue;
        if (field(text, "GPU UUID") == null) continue;
        if (k.n_gpus == cards_max) break;
        k.gpus[k.n_gpus] = Text.init(field(text, "Model") orelse "") orelse .{};
        k.n_gpus += 1;
    }
}

test "machine_keys: live keys from a fake tree, refusal names the row" {
    // Linux-only: card discovery reads procfs and is compiled out elsewhere.
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    // Oracle: a hand-made sysfs/procfs tree with this machine's files (the
    // same RTX 4060 Laptop and i9-14900HX as machine.zig's identity test),
    // and expectations written by hand per row.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sys/module/nvidia");
    try tmp.dir.createDirPath(std.testing.io, "sys/devices/system/cpu");
    try tmp.dir.createDirPath(std.testing.io, "proc/driver/nvidia/gpus/0000:01:00.0");
    try tmp.dir.createDirPath(std.testing.io, "proc/driver/nvidia/gpus/0000:02:00.0");
    const files = [_][2][]const u8{
        .{ "sys/module/nvidia/version", "595.71.05\n" },
        .{ "sys/devices/system/cpu/online", "0-15,16-31\n" },
        .{ "proc/cpuinfo", "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel\t\t: 183\nmodel name\t: Intel(R) Core(TM) i9-14900HX\n" },
        .{ "proc/driver/nvidia/gpus/0000:01:00.0/information", "Model: \t\t NVIDIA GeForce RTX 4060 Laptop GPU\nIRQ:   \t\t 187\nGPU UUID: \t GPU-a5b262fa-fc3e-0653-9187-0d58e7372cbd\n" },
        // No uuid line: not a card `identity` counts, so no `gpu` row.
        .{ "proc/driver/nvidia/gpus/0000:02:00.0/information", "Model: \t\t x\n" },
    };
    for (files) |f| try tmp.dir.writeFile(std.testing.io, .{ .sub_path = f[0], .data = f[1] });
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const id = machine.identity(root, .nvidia);
    const k = live(root, .nvidia, &id);
    try std.testing.expectEqual(@as(u8, 1), k.n_gpus);
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 4060 Laptop GPU", k.gpus[0].slice());
    try std.testing.expectEqualStrings("Intel(R) Core(TM) i9-14900HX", k.cpu.slice());
    try std.testing.expectEqual(@as(u32, 32), k.cpus);
    try std.testing.expectEqualStrings(build().slice(), k.build.slice());

    const m: machine.Machine = .{ .id = id, .keys = k, .c = undefined };
    try std.testing.expect(refusal(&m, &id, &k) == null);
    // Each identity row changed alone is refused by its own name.
    var other_id = id;
    other_id.driver = Text.init("595.71.06").?;
    try std.testing.expectEqualStrings("driver", refusal(&m, &other_id, &k).?.row);
    other_id = id;
    other_id.e_cpus = Text.init("16-23").?;
    try std.testing.expectEqualStrings("e_cpus", refusal(&m, &other_id, &k).?.row);
    const Case = struct { row: []const u8, edit: *const fn (*Keys) void };
    const cases = [_]Case{
        .{ .row = "gpu", .edit = struct {
            fn f(x: *Keys) void {
                x.gpus[0] = Text.init("NVIDIA A100-SXM4-80GB").?;
            }
        }.f },
        .{ .row = "gpu", .edit = struct {
            fn f(x: *Keys) void {
                x.gpus[1] = x.gpus[0];
                x.n_gpus = 2;
            }
        }.f },
        .{ .row = "cpu", .edit = struct {
            fn f(x: *Keys) void {
                x.cpu = Text.init("AMD EPYC 7763 64-Core Processor").?;
            }
        }.f },
        .{ .row = "cpus", .edit = struct {
            fn f(x: *Keys) void {
                x.cpus = 16;
            }
        }.f },
        .{ .row = "build", .edit = struct {
            fn f(x: *Keys) void {
                x.build = Text.init("Debug x86_64 abi42").?;
            }
        }.f },
    };
    for (cases) |c| {
        var moved = k;
        c.edit(&moved);
        const r = refusal(&m, &id, &moved) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c.row, r.row);
        try std.testing.expect(!r.missing);
    }
    // The affinity thread count and the card uuid are not keys: `taskset`
    // and a cloned node keep the file.
    other_id = id;
    other_id.threads = 16;
    other_id.uuids[0][0] ^= 1;
    try std.testing.expect(refusal(&m, &other_id, &k) == null);
    // A file without a row is refused by that row's name, as missing.
    for (rows[1..], 1..) |name, i| {
        var old = m;
        old.keys.seen &= ~(@as(u4, 1) << @intCast(i));
        const r = refusal(&old, &id, &k) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(name, r.row);
        try std.testing.expect(r.missing);
    }
}

test "machine_keys: CPU lists and cpuinfo fields" {
    // Oracle: counts and fields by hand.
    try std.testing.expectEqual(@as(u32, 32), countList("0-31"));
    try std.testing.expectEqual(@as(u32, 5), countList("0,2-4,7"));
    try std.testing.expectEqual(@as(u32, 0), countList("3-1"));
    try std.testing.expectEqual(@as(u32, 0), countList(""));
    try std.testing.expectEqualStrings("x y", field("model\t\t: 183\nmodel name\t: x y\n", "model name").?);
    try std.testing.expectEqualStrings("183", field("model name x: q\nmodel\t\t: 183\n", "model").?);
    try std.testing.expect(field("vendor_id\t: x\n", "model") == null);
}
