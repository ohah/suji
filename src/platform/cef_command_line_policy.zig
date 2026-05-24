const std = @import("std");

pub const Platform = enum {
    macos,
    linux,
    windows,
    other,
};

pub const Switch = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const MAX_SWITCHES = 16;

pub const SwitchSet = struct {
    items: [MAX_SWITCHES]Switch = undefined,
    len: usize = 0,

    fn add(self: *SwitchSet, sw: Switch) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = sw;
        self.len += 1;
    }

    pub fn slice(self: *const SwitchSet) []const Switch {
        return self.items[0..self.len];
    }
};

fn envTruthy(value: ?[]const u8) bool {
    const v = value orelse return false;
    if (v.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(v, "0")) return false;
    if (std.ascii.eqlIgnoreCase(v, "false")) return false;
    if (std.ascii.eqlIgnoreCase(v, "no")) return false;
    return true;
}

pub fn switches(platform: Platform, ci_env_value: ?[]const u8) SwitchSet {
    var set = SwitchSet{};
    set.add(.{ .name = "use-mock-keychain" });
    set.add(.{ .name = "disable-background-mode" });
    set.add(.{ .name = "remote-allow-origins", .value = "*" });

    if (platform != .macos) {
        set.add(.{ .name = "disable-gpu" });
        set.add(.{ .name = "disable-gpu-compositing" });
    }

    if (platform == .linux) {
        set.add(.{ .name = "no-sandbox" });

        if (envTruthy(ci_env_value)) {
            set.add(.{ .name = "disable-dev-shm-usage" });
            set.add(.{ .name = "disable-crash-reporter" });
            set.add(.{ .name = "disable-gpu-sandbox" });
            set.add(.{ .name = "disable-setuid-sandbox" });
            set.add(.{ .name = "enable-logging", .value = "stderr" });
            set.add(.{ .name = "v", .value = "1" });
            set.add(.{ .name = "ozone-platform", .value = "x11" });
        }
    }

    return set;
}

test "CEF command switches preserve baseline browser flags" {
    const set = switches(.macos, null).slice();
    try std.testing.expectEqual(@as(usize, 3), set.len);
    try std.testing.expectEqualStrings("use-mock-keychain", set[0].name);
    try std.testing.expectEqualStrings("disable-background-mode", set[1].name);
    try std.testing.expectEqualStrings("remote-allow-origins", set[2].name);
    try std.testing.expectEqualStrings("*", set[2].value.?);
}

test "CEF command switches disable GPU on non-macOS platforms" {
    const linux = switches(.linux, null).slice();
    const windows = switches(.windows, null).slice();

    try std.testing.expect(containsSwitch(linux, "disable-gpu"));
    try std.testing.expect(containsSwitch(linux, "disable-gpu-compositing"));
    try std.testing.expect(containsSwitch(windows, "disable-gpu"));
    try std.testing.expect(containsSwitch(windows, "disable-gpu-compositing"));
}

test "CEF command switches add Linux CI headless guards only when requested" {
    const normal = switches(.linux, null).slice();
    try std.testing.expect(containsSwitch(normal, "no-sandbox"));
    try std.testing.expect(!containsSwitch(normal, "disable-dev-shm-usage"));
    try std.testing.expect(!containsSwitch(normal, "no-zygote"));
    try std.testing.expect(!containsSwitch(normal, "ozone-platform"));

    const ci = switches(.linux, "true").slice();
    try std.testing.expect(containsSwitch(ci, "disable-dev-shm-usage"));
    try std.testing.expect(containsSwitch(ci, "disable-crash-reporter"));
    try std.testing.expect(containsSwitch(ci, "disable-gpu-sandbox"));
    try std.testing.expect(containsSwitch(ci, "disable-setuid-sandbox"));
    try std.testing.expectEqualStrings("stderr", switchValue(ci, "enable-logging").?);
    try std.testing.expectEqualStrings("1", switchValue(ci, "v").?);
    try std.testing.expect(!containsSwitch(ci, "single-process"));
    try std.testing.expect(!containsSwitch(ci, "no-zygote"));
    try std.testing.expectEqualStrings("x11", switchValue(ci, "ozone-platform").?);

    const disabled = switches(.linux, "false").slice();
    try std.testing.expect(!containsSwitch(disabled, "disable-dev-shm-usage"));
}

fn containsSwitch(items: []const Switch, name: []const u8) bool {
    return switchValue(items, name) != null or blk: {
        for (items) |item| {
            if (std.mem.eql(u8, item.name, name) and item.value == null) break :blk true;
        }
        break :blk false;
    };
}

fn switchValue(items: []const Switch, name: []const u8) ?[]const u8 {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item.value;
    }
    return null;
}
