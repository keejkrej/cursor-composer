const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const bridge_mod = @import("bridge.zig");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;

pub const default_model = "composer-2.5";

var mutex: std.Io.Mutex = .init;
var started: bool = false;
var manager: bridge_mod.Manager = undefined;
var client_mem: ?client_mod.Client = null;
var agent_id_owned: ?[]u8 = null;
var workspace_owned: ?[]u8 = null;
var api_key_owned: ?[]u8 = null;
var model_owned: ?[]u8 = null;
var alloc_ref: Allocator = std.heap.c_allocator;

pub fn resolveApiKey() ?[]const u8 {
    return io_mod.getenv("CURSOR_API_KEY") orelse io_mod.getenv("AI_GATEWAY_API_KEY");
}

pub fn resolveBridgeBin() []const u8 {
    return io_mod.getenv("CURSOR_SDK_BRIDGE_BIN") orelse "cursor-sdk-bridge/bin/cursor-sdk-bridge";
}

pub fn resolveModel(preferred: []const u8) []const u8 {
    if (preferred.len > 0 and !std.mem.eql(u8, preferred, "auto")) return preferred;
    return io_mod.getenv("CURSOR_MODEL") orelse default_model;
}

pub const Session = struct {
    client: client_mod.Client,
    agent_id: []const u8,
    model: []const u8,
};

pub fn ensure(alloc: Allocator, workspace: []const u8, preferred_model: []const u8, resume_id: ?[]const u8) !Session {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    alloc_ref = alloc;

    const api_key = resolveApiKey() orelse return error.MissingCursorApiKey;
    const model = resolveModel(preferred_model);

    if (!started) {
        manager = bridge_mod.Manager.init(alloc);
        const attach_url = io_mod.getenv("CURSOR_SDK_BRIDGE_URL");
        const attach_token = io_mod.getenv("CURSOR_SDK_BRIDGE_TOKEN");
        const endpoint = if (attach_url != null and attach_token != null)
            try manager.attach(attach_url.?, attach_token.?)
        else
            manager.start(resolveBridgeBin(), workspace, api_key) catch |err| {
                return err;
            };

        api_key_owned = try alloc.dupe(u8, api_key);
        workspace_owned = try alloc.dupe(u8, workspace);
        model_owned = try alloc.dupe(u8, model);
        client_mem = client_mod.Client.init(alloc, endpoint.url, endpoint.token, api_key_owned.?);
        client_mem.?.ping() catch |err| {
            manager.stop();
            return err;
        };
        started = true;
    }

    const client = client_mem orelse return error.CursorSessionUnavailable;
    if (agent_id_owned == null) {
        if (resume_id) |id| {
            agent_id_owned = try client.resumeAgent(id, workspace, model);
        } else {
            agent_id_owned = try client.createAgent(workspace, model);
        }
    }

    return .{
        .client = client,
        .agent_id = agent_id_owned.?,
        .model = model_owned orelse model,
    };
}

pub fn resetAgent() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (agent_id_owned) |id| {
        alloc_ref.free(id);
        agent_id_owned = null;
    }
}

pub fn shutdown() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (client_mem) |client| client.shutdown();
    if (started) manager.stop();
    if (agent_id_owned) |id| alloc_ref.free(id);
    if (workspace_owned) |cwd| alloc_ref.free(cwd);
    if (api_key_owned) |key| alloc_ref.free(key);
    if (model_owned) |model| alloc_ref.free(model);
    agent_id_owned = null;
    workspace_owned = null;
    api_key_owned = null;
    model_owned = null;
    client_mem = null;
    started = false;
}

test "default model is composer-2.5" {
    try std.testing.expectEqualStrings("composer-2.5", default_model);
}
