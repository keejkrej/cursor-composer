const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const json_util = @import("json_util.zig");

const Allocator = std.mem.Allocator;

/// Cursor SDK ids that `/model` should offer without a Vercel gateway catalog.
pub const known_ids = [_][]const u8{
    "grok-4.6",
    "composer-2.5",
    "gpt-5.6-sol",
    "gpt-5.6-luna",
    "claude-opus-5",
    "gemini-3.1-pro",
};

const Alias = struct { from: []const u8, to: []const u8 };

const aliases = [_]Alias{
    .{ .from = "cursor-grok-4-6", .to = "grok-4.6" },
    .{ .from = "cursor-grok-4.6", .to = "grok-4.6" },
    .{ .from = "xai/grok-4.6", .to = "grok-4.6" },
    .{ .from = "composer-2-5", .to = "composer-2.5" },
};

pub const provider = model_catalog.Provider{
    .fetch_fn = fetch,
};

pub fn mapAlias(id: []const u8) []const u8 {
    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(alias.from, id)) return alias.to;
    }
    return id;
}

/// A Cursor SDK model id is slash-free (or a known alias of one).
pub fn cursorModelId(id: []const u8) ?[]const u8 {
    const mapped = mapAlias(std.mem.trim(u8, id, " \t"));
    if (mapped.len == 0 or std.ascii.eqlIgnoreCase(mapped, "auto")) return null;
    if (std.mem.indexOfScalar(u8, mapped, '/') != null) return null;
    return mapped;
}

pub fn entry(alloc: Allocator, id: []const u8) !model_catalog.ModelCatalogEntry {
    return .{
        .id = try alloc.dupe(u8, id),
        .model_type = try alloc.dupe(u8, "language"),
        .has_tool_use = true,
    };
}

pub fn staticCatalog(alloc: Allocator) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (known_ids) |id| {
        try entries.append(alloc, try entry(alloc, id));
    }
    return entries;
}

pub fn parseListModels(alloc: Allocator, body: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.MalformedResponse;
    defer parsed.deinit();
    const items = json_util.arrayGet(parsed.value, "items") orelse
        json_util.arrayGet(parsed.value, "models") orelse
        return error.MalformedResponse;

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (items.items) |item| {
        const id = json_util.stringGet(item, "id") orelse continue;
        if (id.len == 0) continue;
        try entries.append(alloc, try entry(alloc, id));
    }
    return entries;
}

fn fetch(
    _: ?*anyopaque,
    alloc: Allocator,
    _: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    return .{ .catalog = staticCatalog(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    } };
}

test "aliases map CLI slugs to SDK ids" {
    try std.testing.expectEqualStrings("grok-4.6", mapAlias("cursor-grok-4-6"));
    try std.testing.expectEqualStrings("grok-4.6", cursorModelId("xai/grok-4.6").?);
    try std.testing.expect(cursorModelId("moonshotai/kimi-k3") == null);
    try std.testing.expectEqualStrings("composer-2.5", cursorModelId("composer-2.5").?);
}

test "ListModels items become catalog ids" {
    const alloc = std.testing.allocator;
    var entries = try parseListModels(alloc, "{\"items\":[{\"id\":\"grok-4.6\"},{\"id\":\"composer-2.5\"}]}");
    defer model_catalog.freeModelCatalog(alloc, &entries);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("grok-4.6", entries.items[0].id);
}
