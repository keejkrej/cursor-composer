const std = @import("std");

pub fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn stringGet(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = objectGet(value, key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

pub fn boolGet(value: std.json.Value, key: []const u8) ?bool {
    const field = objectGet(value, key) orelse return null;
    return switch (field) {
        .bool => |flag| flag,
        else => null,
    };
}

pub fn arrayGet(value: std.json.Value, key: []const u8) ?std.json.Array {
    const field = objectGet(value, key) orelse return null;
    return switch (field) {
        .array => |items| items,
        else => null,
    };
}

pub fn stringifyAlloc(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "object and string getters" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\"}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("assistant", stringGet(parsed.value, "type").?);
    try std.testing.expect(objectGet(parsed.value, "message") != null);
    try std.testing.expect(stringGet(parsed.value, "missing") == null);
}
