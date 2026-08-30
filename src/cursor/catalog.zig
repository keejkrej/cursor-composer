const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const json_util = @import("json_util.zig");
const client_mod = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// Cursor SDK ids that `/model` should offer when ListModels is unavailable.
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

/// Optional live ListModels hook. Installed by the TUI so `/model` can spawn or
/// attach to the SDK bridge. Returns owned JSON or null to use the static list.
pub const ListModelsFn = *const fn (Allocator) Allocator.Error!?[]u8;
pub var list_models_fn: ?ListModelsFn = null;

pub fn installListModels(list_fn: ListModelsFn) void {
    list_models_fn = list_fn;
}

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
    const items = modelsArray(parsed.value) orelse return error.MalformedResponse;

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (items.items) |item| {
        const raw = modelId(item) orelse continue;
        const id = cursorModelId(raw) orelse continue;
        try entries.append(alloc, try entry(alloc, id));
    }
    return entries;
}

fn modelId(item: std.json.Value) ?[]const u8 {
    const keys = [_][]const u8{ "id", "modelId", "model_id", "model" };
    for (keys) |key| {
        if (json_util.stringGet(item, key)) |id| {
            const trimmed = std.mem.trim(u8, id, " \t");
            if (trimmed.len > 0) return trimmed;
        }
    }
    return null;
}

fn modelsArray(root: std.json.Value) ?std.json.Array {
    switch (root) {
        .array => |items| return items,
        .object => {},
        else => return null,
    }
    const keys = [_][]const u8{ "items", "models", "data" };
    for (keys) |key| {
        if (json_util.arrayGet(root, key)) |items| return items;
    }
    if (json_util.objectGet(root, "result")) |inner| return modelsArray(inner);
    return null;
}

fn fetch(
    _: ?*anyopaque,
    alloc: Allocator,
    _: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (try fetchLive(alloc)) |catalog| return .{ .catalog = catalog };
    return .{ .catalog = staticCatalog(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    } };
}

fn fetchLive(alloc: Allocator) Allocator.Error!?std.ArrayList(model_catalog.ModelCatalogEntry) {
    const body = (try liveListModelsJson(alloc)) orelse {
        debug_trace.logf("catalog", "list_models_live skipped reason=unavailable", .{});
        return null;
    };
    defer alloc.free(body);
    var entries = parseListModels(alloc, body) catch {
        debug_trace.logf("catalog", "list_models_live skipped reason=malformed", .{});
        return null;
    };
    if (entries.items.len == 0) {
        model_catalog.freeModelCatalog(alloc, &entries);
        debug_trace.logf("catalog", "list_models_live skipped reason=empty", .{});
        return null;
    }
    debug_trace.logf("catalog", "list_models_live count={d}", .{entries.items.len});
    return entries;
}

fn liveListModelsJson(alloc: Allocator) Allocator.Error!?[]u8 {
    if (list_models_fn) |list_fn| {
        return list_fn(alloc);
    }
    return listModelsViaAttach(alloc);
}

fn listModelsViaAttach(alloc: Allocator) Allocator.Error!?[]u8 {
    const url = nonemptyEnv("CURSOR_SDK_BRIDGE_URL") orelse return null;
    const token = nonemptyEnv("CURSOR_SDK_BRIDGE_TOKEN") orelse return null;
    const key = nonemptyEnv("CURSOR_API_KEY") orelse nonemptyEnv("AI_GATEWAY_API_KEY") orelse return null;
    const client = client_mod.Client.init(alloc, url, token, key);
    return client.listModels() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn nonemptyEnv(name: []const u8) ?[]const u8 {
    const value = io_mod.getenv(name) orelse return null;
    return if (value.len > 0) value else null;
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

test "ListModels models and result envelopes parse" {
    const alloc = std.testing.allocator;
    var via_models = try parseListModels(alloc, "{\"models\":[{\"id\":\"composer-2.5\"}]}");
    defer model_catalog.freeModelCatalog(alloc, &via_models);
    try std.testing.expectEqualStrings("composer-2.5", via_models.items[0].id);

    var via_result = try parseListModels(alloc, "{\"result\":{\"items\":[{\"id\":\"gpt-5.4\"}]}}");
    defer model_catalog.freeModelCatalog(alloc, &via_result);
    try std.testing.expectEqualStrings("gpt-5.4", via_result.items[0].id);

    var via_model_id = try parseListModels(alloc, "{\"data\":[{\"modelId\":\"gpt-5.6-sol\"}]}");
    defer model_catalog.freeModelCatalog(alloc, &via_model_id);
    try std.testing.expectEqualStrings("gpt-5.6-sol", via_model_id.items[0].id);

    var via_array = try parseListModels(alloc, "[{\"id\":\"claude-opus-5\"}]");
    defer model_catalog.freeModelCatalog(alloc, &via_array);
    try std.testing.expectEqualStrings("claude-opus-5", via_array.items[0].id);
}

test "ListModels skips slash ids leftover from the fx gateway catalog" {
    const alloc = std.testing.allocator;
    var entries = try parseListModels(alloc, "{\"items\":[{\"id\":\"moonshotai/kimi-k3\"},{\"id\":\"composer-2.5\"}]}");
    defer model_catalog.freeModelCatalog(alloc, &entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("composer-2.5", entries.items[0].id);
}

test "fetch without a bridge uses the static catalog" {
    const alloc = std.testing.allocator;
    list_models_fn = null;
    const result = try fetch(null, alloc, .{ .endpoint = "/v1/models" });
    var catalog = switch (result) {
        .catalog => |entries| entries,
        .failure => return error.TestUnexpectedResult,
    };
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(@as(usize, known_ids.len), catalog.items.len);
}

test "fetch prefers a live ListModels hook over the static list" {
    const alloc = std.testing.allocator;
    const Live = struct {
        fn list(list_alloc: Allocator) Allocator.Error!?[]u8 {
            return try list_alloc.dupe(u8, "{\"items\":[{\"id\":\"mock-live-model\"}]}");
        }
    };
    list_models_fn = Live.list;
    defer list_models_fn = null;

    const result = try fetch(null, alloc, .{ .endpoint = "/v1/models" });
    var catalog = switch (result) {
        .catalog => |entries| entries,
        .failure => return error.TestUnexpectedResult,
    };
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("mock-live-model", catalog.items[0].id);
}
