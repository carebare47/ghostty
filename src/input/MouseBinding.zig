//! Mouse bindings map mouse triggers (button + modifiers + click count) to
//! actions. This is the mouse equivalent of Binding.zig but much simpler:
//! no key sequences, no chains, just a flat trigger-to-action map.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Binding = @import("Binding.zig");
const key = @import("key.zig");
const key_mods = @import("key_mods.zig");

pub const Action = Binding.Action;

pub const Error = error{
    InvalidFormat,
    InvalidAction,
};

/// Mouse buttons and scroll directions that can be used as binding triggers.
/// Covers the same physical buttons as mouse.Button (with different naming
/// for config readability) plus scroll wheel directions.
pub const MouseButton = enum {
    left,
    right,
    middle,
    button_4,
    button_5,
    button_6,
    button_7,
    button_8,
    button_9,
    button_10,
    button_11,
    scroll_up,
    scroll_down,
    scroll_left,
    scroll_right,

    /// Convert from the terminal mouse button type. Returns null for unknown.
    pub fn fromMouseButton(button: @import("mouse.zig").Button) ?MouseButton {
        return switch (button) {
            .left => .left,
            .right => .right,
            .middle => .middle,
            .four => .button_4,
            .five => .button_5,
            .six => .button_6,
            .seven => .button_7,
            .eight => .button_8,
            .nine => .button_9,
            .ten => .button_10,
            .eleven => .button_11,
            .unknown => null,
        };
    }

    pub fn isScroll(self: MouseButton) bool {
        return switch (self) {
            .scroll_up, .scroll_down, .scroll_left, .scroll_right => true,
            else => false,
        };
    }

    pub fn parse(input: []const u8) ?MouseButton {
        return std.meta.stringToEnum(MouseButton, input);
    }

    pub fn format(
        self: MouseButton,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll(@tagName(self));
    }
};

/// A mouse trigger is a combination of a button, modifiers, and click count
/// that identifies a specific mouse event to bind an action to.
pub const Trigger = struct {
    button: MouseButton = .left,
    mods: key.Mods = .{},
    /// Number of clicks required. 1 = single, 2 = double, 3 = triple.
    /// 0 is used for scroll triggers (no click count concept).
    click_count: u8 = 1,

    /// Parse a trigger from a string. Format: `[mods+]button[:click_count]`
    /// where click_count can be `single`, `double`, `triple`, or a number 1-10.
    /// Scroll triggers must not have a click count suffix.
    pub fn parse(input: []const u8) Error!Trigger {
        if (input.len == 0) return Error.InvalidFormat;

        var result: Trigger = .{};
        var button_set = false;

        // Split off the click count suffix first (after ':')
        const colon_idx = std.mem.indexOfScalar(u8, input, ':');
        const trigger_part = if (colon_idx) |idx| input[0..idx] else input;
        const click_count_part = if (colon_idx) |idx| input[idx + 1 ..] else null;

        // Parse the trigger part (mods + button) split by '+'
        var remaining: []const u8 = trigger_part;
        while (remaining.len > 0) {
            const plus_idx = std.mem.indexOfScalar(u8, remaining, '+') orelse remaining.len;
            const part = remaining[0..plus_idx];
            remaining = if (plus_idx >= remaining.len) "" else remaining[plus_idx + 1 ..];

            // Try modifier names from the Mods struct
            const mods_info = @typeInfo(key.Mods).@"struct";
            const is_mod = is_mod: {
                inline for (mods_info.fields) |field| {
                    if (field.type == bool) {
                        if (std.mem.eql(u8, part, field.name)) {
                            if (@field(result.mods, field.name)) return Error.InvalidFormat;
                            @field(result.mods, field.name) = true;
                            break :is_mod true;
                        }
                    }
                }
                break :is_mod false;
            };
            if (is_mod) continue;

            // Try modifier aliases
            const is_alias = is_alias: {
                inline for (key_mods.alias) |pair| {
                    if (std.mem.eql(u8, part, pair[0])) {
                        const field_name = @tagName(pair[1]);
                        if (@field(result.mods, field_name)) return Error.InvalidFormat;
                        @field(result.mods, field_name) = true;
                        break :is_alias true;
                    }
                }
                break :is_alias false;
            };
            if (is_alias) continue;

            // Must be a button — only one allowed
            if (button_set) return Error.InvalidFormat;
            result.button = MouseButton.parse(part) orelse return Error.InvalidFormat;
            button_set = true;
        }

        if (!button_set) return Error.InvalidFormat;

        if (click_count_part) |count_str| {
            if (result.button.isScroll()) return Error.InvalidFormat;
            if (count_str.len == 0) return Error.InvalidFormat;

            if (std.mem.eql(u8, count_str, "single")) {
                result.click_count = 1;
            } else if (std.mem.eql(u8, count_str, "double")) {
                result.click_count = 2;
            } else if (std.mem.eql(u8, count_str, "triple")) {
                result.click_count = 3;
            } else {
                const count = std.fmt.parseInt(u8, count_str, 10) catch return Error.InvalidFormat;
                if (count < 1 or count > 10) return Error.InvalidFormat;
                result.click_count = count;
            }
        } else {
            // Scroll triggers have no click count concept; use 0.
            // Non-scroll buttons default to 1 (single click).
            result.click_count = if (result.button.isScroll()) 0 else 1;
        }

        return result;
    }

    pub fn format(
        self: Trigger,
        writer: *std.Io.Writer,
    ) !void {
        // Emit modifiers in the same order as Binding.Trigger.format
        if (self.mods.super) try writer.writeAll("super+");
        if (self.mods.ctrl) try writer.writeAll("ctrl+");
        if (self.mods.alt) try writer.writeAll("alt+");
        if (self.mods.shift) try writer.writeAll("shift+");

        try writer.writeAll(@tagName(self.button));

        // Only emit click count when it differs from the default (1 for
        // buttons, 0 for scroll). In practice, scroll is always 0 and we
        // never emit it; buttons only emit when count > 1.
        if (!self.button.isScroll() and self.click_count > 1) {
            try writer.writeByte(':');
            try writer.print("{d}", .{self.click_count});
        }
    }

    pub fn hash(self: Trigger) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, self.button);
        std.hash.autoHash(&hasher, self.mods.binding());
        std.hash.autoHash(&hasher, self.click_count);
        return hasher.final();
    }

    pub fn eql(self: Trigger, other: Trigger) bool {
        return self.button == other.button and
            self.mods.binding().equal(other.mods.binding()) and
            self.click_count == other.click_count;
    }
};

const TriggerContext = struct {
    pub fn hash(_: TriggerContext, trigger: Trigger) u32 {
        return @truncate(trigger.hash());
    }

    pub fn eql(_: TriggerContext, a: Trigger, b: Trigger, _: usize) bool {
        return a.eql(b);
    }
};

pub const Set = struct {
    const HashMap = std.ArrayHashMapUnmanaged(
        Trigger,
        Action,
        TriggerContext,
        true,
    );

    bindings: HashMap = .{},

    pub fn deinit(self: *Set, alloc: Allocator) void {
        self.bindings.deinit(alloc);
        self.* = undefined;
    }

    pub fn put(
        self: *Set,
        alloc: Allocator,
        trigger: Trigger,
        action: Action,
    ) Allocator.Error!void {
        try self.bindings.put(alloc, trigger, action);
    }

    pub fn remove(
        self: *Set,
        trigger: Trigger,
    ) void {
        _ = self.bindings.swapRemove(trigger);
    }

    pub fn get(self: Set, trigger: Trigger) ?Action {
        return self.bindings.get(trigger);
    }

    /// Parse a "trigger=action" string and add it to the set.
    /// The special action `unbind` removes the trigger from the set.
    pub fn parseAndPut(
        self: *Set,
        alloc: Allocator,
        input: []const u8,
    ) (Allocator.Error || Error)!void {
        // Reject keybind flag prefixes (unconsumed:, performable:, etc.)
        // by checking the text before the first colon, if any, against
        // known flag names. The colon could also be a click count separator
        // (e.g. "left:double") so we only reject exact flag name matches.
        if (std.mem.indexOf(u8, input, ":")) |colon_idx| {
            const prefix = input[0..colon_idx];
            const keybind_flags = [_][]const u8{ "unconsumed", "performable", "all", "global" };
            for (keybind_flags) |flag| {
                if (std.mem.eql(u8, prefix, flag)) return Error.InvalidFormat;
            }
        }

        const eql_idx = std.mem.indexOfScalar(u8, input, '=') orelse
            return Error.InvalidFormat;

        const trigger_str = input[0..eql_idx];
        const action_str = input[eql_idx + 1 ..];

        const trigger = try Trigger.parse(trigger_str);
        const action = Action.parse(action_str) catch return Error.InvalidAction;

        if (action == .unbind) {
            self.remove(trigger);
            return;
        }

        try self.put(alloc, trigger, action);
    }

    pub fn clone(self: *const Set, alloc: Allocator) Allocator.Error!Set {
        var result: Set = .{
            .bindings = try self.bindings.clone(alloc),
        };

        // Deep clone any actions that own allocated memory
        for (result.bindings.values()) |*action| {
            action.* = try action.clone(alloc);
        }

        return result;
    }

    pub fn equal(self: Set, other: Set) bool {
        if (self.bindings.count() != other.bindings.count()) return false;

        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            const other_action = other.bindings.get(entry.key_ptr.*) orelse return false;
            if (!entry.value_ptr.equal(other_action)) return false;
        }

        return true;
    }
};

test "Trigger parse: button only" {
    const testing = std.testing;
    const trigger = try Trigger.parse("left");
    try testing.expectEqual(MouseButton.left, trigger.button);
    try testing.expect(trigger.mods.binding().equal(.{}));
    try testing.expectEqual(@as(u8, 1), trigger.click_count);
}

test "Trigger parse: scroll button" {
    const testing = std.testing;
    const trigger = try Trigger.parse("scroll_up");
    try testing.expectEqual(MouseButton.scroll_up, trigger.button);
    try testing.expectEqual(@as(u8, 0), trigger.click_count);
}

test "Trigger parse: scroll with click count is error" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidFormat, Trigger.parse("scroll_up:double"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("scroll_down:1"));
}

test "Trigger parse: modifiers" {
    const testing = std.testing;
    const trigger = try Trigger.parse("ctrl+left");
    try testing.expectEqual(MouseButton.left, trigger.button);
    try testing.expect(trigger.mods.ctrl);
    try testing.expect(!trigger.mods.shift);
}

test "Trigger parse: multiple modifiers" {
    const testing = std.testing;
    const trigger = try Trigger.parse("ctrl+shift+right");
    try testing.expectEqual(MouseButton.right, trigger.button);
    try testing.expect(trigger.mods.ctrl);
    try testing.expect(trigger.mods.shift);
}

test "Trigger parse: modifier aliases" {
    const testing = std.testing;
    const trigger = try Trigger.parse("cmd+left");
    try testing.expectEqual(MouseButton.left, trigger.button);
    try testing.expect(trigger.mods.super);

    const trigger2 = try Trigger.parse("opt+middle");
    try testing.expectEqual(MouseButton.middle, trigger2.button);
    try testing.expect(trigger2.mods.alt);

    const trigger3 = try Trigger.parse("control+right");
    try testing.expectEqual(MouseButton.right, trigger3.button);
    try testing.expect(trigger3.mods.ctrl);
}

test "Trigger parse: named click counts" {
    const testing = std.testing;

    const single = try Trigger.parse("left:single");
    try testing.expectEqual(@as(u8, 1), single.click_count);

    const double = try Trigger.parse("left:double");
    try testing.expectEqual(@as(u8, 2), double.click_count);

    const triple = try Trigger.parse("left:triple");
    try testing.expectEqual(@as(u8, 3), triple.click_count);
}

test "Trigger parse: numeric click counts" {
    const testing = std.testing;

    const one = try Trigger.parse("left:1");
    try testing.expectEqual(@as(u8, 1), one.click_count);

    const ten = try Trigger.parse("left:10");
    try testing.expectEqual(@as(u8, 10), ten.click_count);
}

test "Trigger parse: error cases" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidFormat, Trigger.parse(""));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("ctrl"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("invalid_button"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("left:0"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("left:11"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("left:abc"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("left:"));
    try testing.expectError(Error.InvalidFormat, Trigger.parse("ctrl+ctrl+left"));
}

test "Trigger: hash and eql" {
    const testing = std.testing;

    const a = try Trigger.parse("ctrl+left:double");
    const b = try Trigger.parse("ctrl+left:double");
    const c = try Trigger.parse("ctrl+left:triple");

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expectEqual(a.hash(), b.hash());
    try testing.expect(a.hash() != c.hash());
}

test "Trigger: format" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const trigger = try Trigger.parse("ctrl+shift+left:double");
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try trigger.format(&buf.writer);
        try testing.expectEqualSlices(u8, "ctrl+shift+left:2", buf.written());
    }

    {
        const trigger = try Trigger.parse("scroll_up");
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try trigger.format(&buf.writer);
        try testing.expectEqualSlices(u8, "scroll_up", buf.written());
    }

    {
        const trigger = try Trigger.parse("right");
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try trigger.format(&buf.writer);
        try testing.expectEqualSlices(u8, "right", buf.written());
    }
}

test "Set: parseAndPut" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try set.parseAndPut(alloc, "ctrl+left:double=copy_to_clipboard");

    const trigger = try Trigger.parse("ctrl+left:double");
    const entry = set.get(trigger).?;
    try testing.expect(entry == .copy_to_clipboard);
}

test "Set: parseAndPut unbind" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try set.parseAndPut(alloc, "left=ignore");

    const trigger = try Trigger.parse("left");
    try testing.expect(set.get(trigger) != null);

    try set.parseAndPut(alloc, "left=unbind");
    try testing.expect(set.get(trigger) == null);
}

test "Set: parseAndPut invalid format" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try testing.expectError(Error.InvalidFormat, set.parseAndPut(alloc, "left"));
    try testing.expectError(Error.InvalidFormat, set.parseAndPut(alloc, "=ignore"));
    try testing.expectError(Error.InvalidAction, set.parseAndPut(alloc, "left=nonexistent_action"));
}

test "Set: clone and equal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try set.parseAndPut(alloc, "left=ignore");
    try set.parseAndPut(alloc, "ctrl+right=paste_from_clipboard");

    var cloned = try set.clone(alloc);
    defer cloned.deinit(alloc);

    try testing.expect(set.equal(cloned));

    // After modification they should not be equal
    try cloned.parseAndPut(alloc, "middle=copy_to_clipboard");
    try testing.expect(!set.equal(cloned));
}

test "Set: overwrite existing binding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try set.parseAndPut(alloc, "left=ignore");
    try set.parseAndPut(alloc, "left=paste_from_clipboard");

    const trigger = try Trigger.parse("left");
    const entry = set.get(trigger).?;
    try testing.expect(entry == .paste_from_clipboard);
    try testing.expectEqual(@as(usize, 1), set.bindings.count());
}

test "Set: parseAndPut rejects keybind flag prefixes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try testing.expectError(Error.InvalidFormat, set.parseAndPut(alloc, "unconsumed:left=ignore"));
    try testing.expectError(Error.InvalidFormat, set.parseAndPut(alloc, "performable:right=paste_from_clipboard"));
    try testing.expectError(Error.InvalidFormat, set.parseAndPut(alloc, "all:left=ignore"));
    try testing.expectError(Error.InvalidFormat, set.parseAndPut(alloc, "global:left=ignore"));
}

test "Set: click count colon is not confused with flag prefix colon" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try set.parseAndPut(alloc, "ctrl+left:double=copy_to_clipboard");

    const trigger: Trigger = .{
        .button = .left,
        .mods = .{ .ctrl = true },
        .click_count = 2,
    };
    const entry = set.get(trigger).?;
    try testing.expect(entry == .copy_to_clipboard);
}

test "Set: unbind on never-bound trigger is a no-op" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: Set = .{};
    defer set.deinit(alloc);

    try set.parseAndPut(alloc, "right=unbind");
    try testing.expectEqual(@as(usize, 0), set.bindings.count());
}

