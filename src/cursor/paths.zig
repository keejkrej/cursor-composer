const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const default_relpath = "cursor-sdk-bridge/bin/cursor-sdk-bridge";

const sibling_suffixes = [_][]const []const u8{
    &.{"cursor-sdk-bridge"},
    &.{"cursor-sdk-bridge.exe"},
    &.{ "cursor-sdk-bridge", "bin", "cursor-sdk-bridge" },
    &.{ "cursor-sdk-bridge", "bin", "cursor-sdk-bridge.exe" },
    &.{ "..", "cursor-sdk-bridge", "bin", "cursor-sdk-bridge" },
    &.{ "..", "cursor-sdk-bridge", "bin", "cursor-sdk-bridge.exe" },
};

const home_suffixes = [_][]const []const u8{
    &.{ ".cc", "bin", "cursor-sdk-bridge" },
    &.{ ".cc", "bin", "cursor-sdk-bridge.exe" },
    &.{ ".cc", "cursor-sdk-bridge", "bin", "cursor-sdk-bridge" },
    &.{ ".cc", "cursor-sdk-bridge", "bin", "cursor-sdk-bridge.exe" },
};

pub fn joinUnder(alloc: Allocator, root: []const u8, parts: []const []const u8) ![]u8 {
    var current = try alloc.dupe(u8, root);
    errdefer alloc.free(current);
    for (parts) |part| {
        const next = try std.fs.path.join(alloc, &.{ current, part });
        alloc.free(current);
        current = next;
    }
    return current;
}

pub fn siblingBridgeCandidates(alloc: Allocator, exe_dir: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| alloc.free(item);
        list.deinit(alloc);
    }
    for (sibling_suffixes) |parts| {
        try list.append(alloc, try joinUnder(alloc, exe_dir, parts));
    }
    return list.toOwnedSlice(alloc);
}

pub fn homeBridgeCandidates(alloc: Allocator, home_dir: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| alloc.free(item);
        list.deinit(alloc);
    }
    for (home_suffixes) |parts| {
        try list.append(alloc, try joinUnder(alloc, home_dir, parts));
    }
    return list.toOwnedSlice(alloc);
}

pub fn firstExisting(search: []const []const u8) ?[]const u8 {
    for (search) |path| {
        if (pathExists(path)) return path;
    }
    return null;
}

pub fn firstExistingOwned(search: []const []u8) ?[]const u8 {
    for (search) |path| {
        if (pathExists(path)) return path;
    }
    return null;
}

pub fn pathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

pub fn exeDir(alloc: Allocator) ?[]u8 {
    const path = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch return null;
    defer alloc.free(path);
    const dir = std.fs.path.dirname(path) orelse return null;
    return alloc.dupe(u8, dir) catch null;
}

test "sibling candidates cover next-to-exe and repo layouts" {
    const alloc = std.testing.allocator;
    const candidates = try siblingBridgeCandidates(alloc, "/opt/cc/bin");
    defer {
        for (candidates) |item| alloc.free(item);
        alloc.free(candidates);
    }
    try std.testing.expectEqualStrings("/opt/cc/bin/cursor-sdk-bridge", candidates[0]);
    try expectContains(candidates, "/opt/cc/bin/cursor-sdk-bridge/bin/cursor-sdk-bridge");
    try expectContains(candidates, "/opt/cc/bin/../cursor-sdk-bridge/bin/cursor-sdk-bridge");
}

test "home candidates cover installer layout" {
    const alloc = std.testing.allocator;
    const candidates = try homeBridgeCandidates(alloc, "/home/you");
    defer {
        for (candidates) |item| alloc.free(item);
        alloc.free(candidates);
    }
    try expectContains(candidates, "/home/you/.cc/bin/cursor-sdk-bridge");
    try expectContains(candidates, "/home/you/.cc/cursor-sdk-bridge/bin/cursor-sdk-bridge");
}

test "firstExisting skips missing paths" {
    const search = [_][]const u8{ "/definitely-missing-cc-bridge", default_relpath };
    const found = firstExisting(&search);
    if (pathExists(default_relpath)) {
        try std.testing.expectEqualStrings(default_relpath, found.?);
    } else {
        try std.testing.expect(found == null);
    }
}

fn expectContains(haystack: []const []u8, needle: []const u8) !void {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return;
    }
    return error.TestExpectedEqual;
}
