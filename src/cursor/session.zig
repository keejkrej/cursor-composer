const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const bridge_mod = @import("bridge.zig");
const client_mod = @import("client.zig");
const paths = @import("paths.zig");
const catalog = @import("catalog.zig");

const Allocator = std.mem.Allocator;

// Cursor SDK / Agent API id for Cursor Grok 4.6 (not the CLI slug cursor-grok-4.6-*).
pub const default_model = "grok-4.6";
pub const persist_dir_name = ".cursor-composer";
pub const persist_file_name = "last-agent";

var mutex: std.Io.Mutex = .init;
var started: bool = false;
var manager: bridge_mod.Manager = undefined;
var client_mem: ?client_mod.Client = null;
var agent_id_owned: ?[]u8 = null;
var workspace_owned: ?[]u8 = null;
var api_key_owned: ?[]u8 = null;
var model_owned: ?[]u8 = null;
var pending_resume_owned: ?[]u8 = null;
var resume_last: bool = false;
var alloc_ref: Allocator = std.heap.c_allocator;
var bridge_bin_owned: ?[]u8 = null;
/// Optional host hook (tool callback server). Set by the Cursor turn path.
pub var on_shutdown: ?*const fn () void = null;
/// Starts the loopback CallCustomTool server before the bridge process / CreateAgent.
pub var prepare_host_callback: ?*const fn () void = null;
var custom_tools_ready: bool = false;
var host_callback_url: ?[]const u8 = null;
var host_callback_token: ?[]const u8 = null;

pub fn noteHostCallback(url: []const u8, token: []const u8) void {
    host_callback_url = url;
    host_callback_token = token;
}

pub fn resolveApiKey() ?[]const u8 {
    return io_mod.getenv("CURSOR_API_KEY") orelse io_mod.getenv("AI_GATEWAY_API_KEY");
}

pub fn resolveBridgeBin() []const u8 {
    if (io_mod.getenv("CURSOR_SDK_BRIDGE_BIN")) |explicit| {
        if (explicit.len > 0) return explicit;
    }
    if (bridge_bin_owned) |cached| return cached;
    if (findBridgeBin(alloc_ref)) |found| {
        bridge_bin_owned = found;
        return found;
    } else |_| {}
    return paths.default_relpath;
}

fn findBridgeBin(alloc: Allocator) ![]u8 {
    if (paths.exeDir(alloc)) |dir| {
        defer alloc.free(dir);
        const siblings = try paths.siblingBridgeCandidates(alloc, dir);
        defer {
            for (siblings) |item| alloc.free(item);
            alloc.free(siblings);
        }
        if (paths.firstExistingOwned(siblings)) |hit| return try alloc.dupe(u8, hit);
    }
    if (io_mod.getenv("HOME")) |home| {
        if (home.len > 0) {
            const homes = try paths.homeBridgeCandidates(alloc, home);
            defer {
                for (homes) |item| alloc.free(item);
                alloc.free(homes);
            }
            if (paths.firstExistingOwned(homes)) |hit| return try alloc.dupe(u8, hit);
        }
    }
    if (paths.pathExists(paths.default_relpath)) {
        return try alloc.dupe(u8, paths.default_relpath);
    }
    return error.BridgeBinaryMissing;
}

pub fn resolveModel(preferred: []const u8) []const u8 {
    return chooseModel(preferred, io_mod.getenv("CURSOR_MODEL"));
}

pub fn chooseModel(preferred: []const u8, env_model: ?[]const u8) []const u8 {
    // `/model` (and `--model`) win over CURSOR_MODEL so the FX picker can switch.
    if (catalog.cursorModelId(preferred)) |id| return id;
    if (env_model) |model| {
        if (catalog.cursorModelId(model)) |id| return id;
        if (model.len > 0) return model;
    }
    return default_model;
}

pub const Session = struct {
    client: client_mod.Client,
    agent_id: []const u8,
    model: []const u8,
};

fn currentCallback() ?bridge_mod.ToolCallback {
    if (host_callback_url != null and host_callback_token != null)
        return .{ .url = host_callback_url.?, .token = host_callback_token.? };
    return null;
}

fn ensureBridgeLocked(alloc: Allocator, workspace: []const u8) !client_mod.Client {
    const api_key = resolveApiKey() orelse return error.MissingCursorApiKey;
    if (!started) {
        manager = bridge_mod.Manager.init(alloc);
        const attach_url = io_mod.getenv("CURSOR_SDK_BRIDGE_URL");
        const attach_token = io_mod.getenv("CURSOR_SDK_BRIDGE_TOKEN");
        const callback = currentCallback();
        const endpoint = if (attach_url != null and attach_token != null)
            try manager.attach(attach_url.?, attach_token.?)
        else
            manager.start(resolveBridgeBin(), workspace, api_key, callback) catch |err| {
                return err;
            };

        api_key_owned = try alloc.dupe(u8, api_key);
        if (workspace_owned == null) workspace_owned = try alloc.dupe(u8, workspace);
        client_mem = client_mod.Client.init(alloc, endpoint.url, endpoint.token, api_key_owned.?);
        client_mem.?.ping() catch |err| {
            manager.stop();
            return err;
        };
        if (callback) |cb| {
            if (client_mem.?.setToolCallback(cb.url, cb.token)) |_| {
                custom_tools_ready = true;
            } else |_| {
                // Spawned bridges also get --tool-callback-* at launch.
                custom_tools_ready = attach_url == null;
            }
        }
        started = true;
    }
    return client_mem orelse error.CursorSessionUnavailable;
}

fn registerCallbackIfNeededLocked() void {
    if (custom_tools_ready) return;
    if (prepare_host_callback) |prepare| prepare();
    const client = client_mem orelse return;
    const callback = currentCallback() orelse return;
    if (client.setToolCallback(callback.url, callback.token)) |_| {
        custom_tools_ready = true;
    } else |_| {}
}

/// Starts the SDK bridge (or attaches) without creating an agent.
/// Used by `/model` so the picker can cache Cursor's ListModels catalog.
/// The returned buffer is owned by `alloc`; session lifetime state stays on `alloc_ref`.
pub fn listModelsJson(alloc: Allocator) Allocator.Error!?[]u8 {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const workspace = workspace_owned orelse ".";
    const client = ensureBridgeLocked(alloc_ref, workspace) catch return null;
    const raw = client.listModels() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer client.alloc.free(raw);
    return try alloc.dupe(u8, raw);
}

pub fn ensure(alloc: Allocator, workspace: []const u8, preferred_model: []const u8, resume_id: ?[]const u8) !Session {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    alloc_ref = alloc;

    const model = resolveModel(preferred_model);
    if (prepare_host_callback) |prepare| prepare();
    const client = try ensureBridgeLocked(alloc, workspace);
    registerCallbackIfNeededLocked();
    if (agent_id_owned == null) {
        const resolved = try resolveResumeIdLocked(alloc, workspace, resume_id);
        defer if (resolved.owned) alloc.free(resolved.id.?);
        if (resolved.id) |id| {
            agent_id_owned = try client.resumeAgentWithTools(id, workspace, model, custom_tools_ready);
        } else {
            agent_id_owned = try client.createAgentWithTools(workspace, model, custom_tools_ready);
        }
        persistLastAgentLocked(workspace, agent_id_owned.?) catch {};
    }
    try adoptModelLocked(alloc, model);

    return .{
        .client = client,
        .agent_id = agent_id_owned.?,
        .model = model_owned orelse model,
    };
}

fn adoptModelLocked(alloc: Allocator, model: []const u8) !void {
    if (model_owned) |old| {
        if (std.mem.eql(u8, old, model)) return;
        alloc.free(old);
    }
    model_owned = try alloc.dupe(u8, model);
}

const ResolvedResume = struct {
    id: ?[]const u8,
    owned: bool,
};

fn resolveResumeIdLocked(alloc: Allocator, workspace: []const u8, explicit: ?[]const u8) !ResolvedResume {
    if (explicit) |id| {
        if (id.len > 0) return .{ .id = id, .owned = false };
    }
    if (pending_resume_owned) |id| return .{ .id = id, .owned = false };
    if (io_mod.getenv("CURSOR_AGENT_ID")) |id| {
        if (id.len > 0) return .{ .id = id, .owned = false };
    }
    if (resume_last) {
        if (readPersistedAgentId(alloc, workspace)) |id| {
            return .{ .id = id, .owned = true };
        } else |_| {}
    }
    return .{ .id = null, .owned = false };
}

pub fn noteResumeLast() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    clearPendingLocked();
    resume_last = true;
    resetAgentLocked();
}

pub fn noteResumeId(alloc: Allocator, id: []const u8) !void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    alloc_ref = alloc;
    clearPendingLocked();
    resume_last = false;
    pending_resume_owned = try alloc.dupe(u8, id);
    resetAgentLocked();
}

pub fn noteResumeFromTarget(target: anytype) void {
    switch (target) {
        inline else => |payload, tag| {
            if (comptime std.mem.eql(u8, @tagName(tag), "id")) {
                noteResumeId(std.heap.c_allocator, payload) catch {};
            } else {
                noteResumeLast();
            }
        },
    }
}

pub fn beginNewAgent(workspace: []const u8) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    resume_last = false;
    clearPendingLocked();
    resetAgentLocked();
    deletePersistedAgentId(workspace);
}

pub fn persistLastAgent(workspace: []const u8, agent_id: []const u8) !void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    try persistLastAgentLocked(workspace, agent_id);
}

pub fn peekResumeId(alloc: Allocator, workspace: []const u8) ?[]u8 {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const resolved = resolveResumeIdLocked(alloc, workspace, null) catch return null;
    if (resolved.id == null) return null;
    if (resolved.owned) return @constCast(resolved.id);
    return alloc.dupe(u8, resolved.id.?) catch null;
}

fn persistLastAgentLocked(workspace: []const u8, agent_id: []const u8) !void {
    const dir_path = persistDirPath(alloc_ref, workspace) catch return;
    defer alloc_ref.free(dir_path);
    io_mod.makeDirRecursive(dir_path) catch return;
    const file_path = persistFilePath(alloc_ref, workspace) catch return;
    defer alloc_ref.free(file_path);
    try io_mod.writeFileAtomic(alloc_ref, file_path, agent_id);
}

fn readPersistedAgentId(alloc: Allocator, workspace: []const u8) ![]u8 {
    const file_path = try persistFilePath(alloc, workspace);
    defer alloc.free(file_path);
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, file_path, .{}) catch return error.PersistedAgentMissing;
    defer file.close(zio);
    const contents = io_mod.readFileToEnd(alloc, &file, 4096) catch return error.PersistedAgentMissing;
    defer alloc.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == 0) return error.PersistedAgentMissing;
    return alloc.dupe(u8, trimmed);
}

fn deletePersistedAgentId(workspace: []const u8) void {
    const file_path = persistFilePath(alloc_ref, workspace) catch return;
    defer alloc_ref.free(file_path);
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), file_path) catch {};
}

fn persistDirPath(alloc: Allocator, workspace: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ workspace, persist_dir_name });
}

fn persistFilePath(alloc: Allocator, workspace: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ workspace, persist_dir_name, persist_file_name });
}

fn clearPendingLocked() void {
    if (pending_resume_owned) |id| {
        alloc_ref.free(id);
        pending_resume_owned = null;
    }
}

pub fn resetAgent() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    resetAgentLocked();
}

fn resetAgentLocked() void {
    if (agent_id_owned) |id| {
        alloc_ref.free(id);
        agent_id_owned = null;
    }
}

pub fn shutdown() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (on_shutdown) |hook| {
        on_shutdown = null;
        hook();
    }
    if (client_mem) |client| client.shutdown();
    if (started) manager.stop();
    resetAgentLocked();
    clearPendingLocked();
    if (workspace_owned) |cwd| alloc_ref.free(cwd);
    if (api_key_owned) |key| alloc_ref.free(key);
    if (model_owned) |model| alloc_ref.free(model);
    if (bridge_bin_owned) |bin| alloc_ref.free(bin);
    workspace_owned = null;
    api_key_owned = null;
    model_owned = null;
    bridge_bin_owned = null;
    custom_tools_ready = false;
    host_callback_url = null;
    host_callback_token = null;
    client_mem = null;
    started = false;
    resume_last = false;
}

test "default model is grok-4.6" {
    try std.testing.expectEqualStrings("grok-4.6", default_model);
}

test "FX gateway model ids fall back to grok-4.6" {
    try std.testing.expectEqualStrings("grok-4.6", chooseModel("moonshotai/kimi-k3", null));
    try std.testing.expectEqualStrings("grok-4.6", chooseModel("auto", null));
    try std.testing.expectEqualStrings("grok-4.6", chooseModel("grok-4.6", null));
}

test "/model selection wins over CURSOR_MODEL" {
    try std.testing.expectEqualStrings("composer-2.5", chooseModel("composer-2.5", "grok-4.6"));
    try std.testing.expectEqualStrings("grok-4.6", chooseModel("cursor-grok-4-6", "composer-2.5"));
    try std.testing.expectEqualStrings("composer-2.5", chooseModel("auto", "composer-2.5"));
}

test "persist and resume last agent id without a bridge" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    shutdown();
    defer shutdown();

    try persistLastAgent(workspace, "agent_persisted");
    noteResumeLast();
    const peeked = peekResumeId(alloc, workspace) orelse return error.TestExpectedResumeId;
    defer alloc.free(peeked);
    try std.testing.expectEqualStrings("agent_persisted", peeked);

    beginNewAgent(workspace);
    try std.testing.expect(peekResumeId(alloc, workspace) == null);
}

test "noteResumeId wins over persisted last" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    shutdown();
    defer shutdown();

    try persistLastAgent(workspace, "agent_persisted");
    try noteResumeId(alloc, "agent_explicit");
    const peeked = peekResumeId(alloc, workspace) orelse return error.TestExpectedResumeId;
    defer alloc.free(peeked);
    try std.testing.expectEqualStrings("agent_explicit", peeked);
}
