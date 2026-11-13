//! SPICE letter and LEVEL dispatch tests: card letter + LEVEL → device type (`spice.zig` policy), against ngspice's mapping.
const std = @import("std");
const devices = @import("builder").spice;
const DeviceId = devices.DeviceId;
const letter_map = devices.letter_map;

test "dispatch policy resolves letters and levels" {
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("o").?);
    try std.testing.expectEqual(DeviceId.txl, letter_map.get("y").?);
    try std.testing.expectEqual(DeviceId.mos1, try devices.levelDeviceId('m', 1));
    try std.testing.expectEqual(DeviceId.bsim4va, try devices.levelDeviceId('m', 54));
    try std.testing.expectEqual(DeviceId.bsim3, try devices.levelDeviceId('m', 49));
    try std.testing.expectEqual(DeviceId.bsim3, try devices.levelDeviceId('m', 8));
    try std.testing.expectEqual(DeviceId.hicumL2_va, try devices.levelDeviceId('q', 8));
    try std.testing.expectEqual(DeviceId.jfet2, try devices.levelDeviceId('j', 2));
    try std.testing.expectEqual(DeviceId.mesa, try devices.levelDeviceId('z', 3));
    try std.testing.expectEqual(DeviceId.b3soifd, try devices.levelDeviceId('m', 55));
    try std.testing.expectEqual(DeviceId.b3soidd, try devices.levelDeviceId('m', 56));
    try std.testing.expectEqual(DeviceId.psp103, try devices.levelDeviceId('m', 1040));
    // Missing-from-catalog (b3soipd, level 57) and unknown levels are
    // unsupported netlists, not panics: the loader turns this into a clean skip.
    // Both warn; the warning is the expected output here, not test noise.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('m', 57));
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('m', 1041));
    // Every tag must resolve to a type: consumers switch `inline else` over
    // the whole enum, so a tag that fails to resolve breaks their build.
    inline for (@typeInfo(DeviceId).@"enum".field_names) |name| _ = DeviceId.Type(@field(DeviceId, name));
}

test "every level table maps each listed level and refuses its neighbours" {
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    try std.testing.expectEqual(DeviceId.diode, try devices.levelDeviceId('d', 1));
    try std.testing.expectEqual(DeviceId.diode, try devices.levelDeviceId('d', 3));
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('d', 2));
    try std.testing.expectEqual(DeviceId.gummel_poon, try devices.levelDeviceId('q', 1));
    try std.testing.expectEqual(DeviceId.gummel_poon, try devices.levelDeviceId('q', 2));
    try std.testing.expectEqual(DeviceId.vbic13_4t, try devices.levelDeviceId('q', 4));
    try std.testing.expectEqual(DeviceId.vbic13_4t, try devices.levelDeviceId('q', 9));
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('q', 3));
    try std.testing.expectEqual(DeviceId.jfet, try devices.levelDeviceId('j', 1));
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('j', 3));
    try std.testing.expectEqual(DeviceId.mes, try devices.levelDeviceId('z', 1));
    try std.testing.expectEqual(DeviceId.hfet1, try devices.levelDeviceId('z', 5));
    try std.testing.expectEqual(DeviceId.hfet2, try devices.levelDeviceId('z', 6));
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('z', 7));
    // LEVEL 0 is no level in any table (an absent LEVEL reads as 1).
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('m', 0));
    try std.testing.expectError(error.UnsupportedDevice, devices.levelDeviceId('m', std.math.maxInt(u16)));
}

test "the letter map knows only the SPICE letters with a device" {
    // m q j z resolve through their LEVEL tables, and u expands in the
    // builder; none of them is a letter_map key.
    for ("mqjzuax") |c| try std.testing.expect(letter_map.get(&.{c}) == null);
    try std.testing.expectEqual(DeviceId.diode, letter_map.get("d").?);
    try std.testing.expectEqual(DeviceId.cswitch, letter_map.get("w").?);
    // Keys are the lowercase letters the netlist hands over.
    try std.testing.expect(letter_map.get("R") == null);
}
