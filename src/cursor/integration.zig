const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const client_mod = @import("client.zig");
const events = @import("events.zig");
const session = @import("session.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");

const Allocator = std.mem.Allocator;

var persistent_environ: std.process.Environ.Map = undefined;
var persistent_environ_ready = false;

fn installBridgeEnviron(url: []const u8) !void {
    if (persistent_environ_ready) persistent_environ.deinit();
    persistent_environ = std.process.Environ.Map.init(std.heap.c_allocator);
    persistent_environ_ready = true;
    try persistent_environ.put("CURSOR_API_KEY", "test-cursor-key");
    try persistent_environ.put("CURSOR_SDK_BRIDGE_URL", url);
    try persistent_environ.put("CURSOR_SDK_BRIDGE_TOKEN", "test-bridge-token");
    io_mod.setEnvironMap(&persistent_environ);
}

fn clearBridgeEnviron() void {
    if (!persistent_environ_ready) return;
    persistent_environ.deinit();
    persistent_environ = std.process.Environ.Map.init(std.heap.c_allocator);
    io_mod.setEnvironMap(&persistent_environ);
}

const MockBridge = struct {
    child: std.process.Child,
    url: []u8,
    alloc: Allocator,

    fn spawn(alloc: Allocator) !MockBridge {
        const zio = io_mod.getIo();
        var child = std.process.spawn(zio, .{
            .argv = &.{ "python3", "scripts/mock-sdk-bridge.py" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.MockBridgeMissing;
        errdefer child.kill(zio);

        const stdout = child.stdout orelse return error.MockBridgeHandshakeFailed;
        const line = try readLine(alloc, stdout);
        defer alloc.free(line);
        const prefix = "READY ";
        if (!std.mem.startsWith(u8, line, prefix)) return error.MockBridgeHandshakeFailed;
        return .{
            .child = child,
            .url = try alloc.dupe(u8, std.mem.trim(u8, line[prefix.len..], " \r\n")),
            .alloc = alloc,
        };
    }

    fn stop(self: *MockBridge) void {
        const zio = io_mod.getIo();
        self.child.kill(zio);
        self.alloc.free(self.url);
        self.* = undefined;
    }
};

fn readLine(alloc: Allocator, file: std.Io.File) ![]u8 {
    const zio = io_mod.getIo();
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    var read_buf: [256]u8 = undefined;
    var reader = file.reader(zio, &read_buf);
    var byte: [1]u8 = undefined;
    const deadline = io_mod.milliTimestamp() + 10_000;
    while (io_mod.milliTimestamp() < deadline) {
        const n = reader.interface.readSliceShort(&byte) catch return error.MockBridgeHandshakeFailed;
        if (n == 0) return error.MockBridgeHandshakeFailed;
        if (byte[0] == '\n') return line.toOwnedSlice(alloc);
        try line.append(alloc, byte[0]);
    }
    return error.MockBridgeHandshakeFailed;
}

const Collected = struct {
    alloc: Allocator,
    messages: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Collected) void {
        for (self.messages.items) |item| self.alloc.free(item);
        self.messages.deinit(self.alloc);
    }
};

fn collectMessage(raw: *anyopaque, payload: []const u8) anyerror!void {
    const collected: *Collected = @ptrCast(@alignCast(raw));
    try collected.messages.append(collected.alloc, try collected.alloc.dupe(u8, payload));
}

test "mock bridge create send stream resume and cancel" {
    const alloc = std.testing.allocator;
    var mock = try MockBridge.spawn(alloc);
    defer mock.stop();

    const client = client_mod.Client.init(alloc, mock.url, "test-bridge-token", "test-cursor-key");
    try client.ping();
    try client.setToolCallback("http://127.0.0.1:9", "callback-token");

    const created = try client.createAgent("/tmp/workspace", "composer-2.5");
    defer alloc.free(created);
    try std.testing.expectEqualStrings("agent_created_1", created);

    var collected = Collected{ .alloc = alloc };
    defer collected.deinit();
    try client.send(created, "hello", "composer-2.5", collectMessage, @ptrCast(&collected));
    try client.waitLiveRun("run_mock_1");
    try std.testing.expect(collected.messages.items.len >= 3);

    var saw_assistant = false;
    var saw_tool = false;
    for (collected.messages.items) |payload| {
        const action = try events.actionFromEnvelope(alloc, payload);
        defer events.freeAction(alloc, action);
        switch (action) {
            .assistant_text => |text| {
                try std.testing.expectEqualStrings("hello from mock", text);
                saw_assistant = true;
            },
            .tool_started => |tool| {
                try std.testing.expectEqualStrings("read_file", tool.name);
                saw_tool = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_assistant);
    try std.testing.expect(saw_tool);

    const resumed = try client.resumeAgent("agent_prior", "/tmp/workspace", "composer-2.5");
    defer alloc.free(resumed);
    try std.testing.expectEqualStrings("agent_prior", resumed);

    try client.cancelRun("run_mock_1", created);
}

test "ListModels live catalog is not the baked-in six" {
    const alloc = std.testing.allocator;
    const catalog = @import("catalog.zig");

    var mock = try MockBridge.spawn(alloc);
    defer mock.stop();

    try installBridgeEnviron(mock.url);
    defer clearBridgeEnviron();

    session.shutdown();
    defer session.shutdown();

    const attached = (try session.listModelsJson(alloc)) orelse return error.ExpectedListModels;
    defer alloc.free(attached);
    var from_session = try catalog.parseListModels(alloc, attached);
    defer model_catalog.freeModelCatalog(alloc, &from_session);
    try std.testing.expect(containsId(from_session.items, "mock-live-model"));
    try std.testing.expect(from_session.items.len != catalog.known_ids.len);

    catalog.list_models_fn = session.listModelsJson;
    defer catalog.list_models_fn = null;
    const hooked = try catalog.provider.fetch(alloc, .{ .endpoint = "/v1/models" });
    var from_hook = switch (hooked) {
        .catalog => |entries| entries,
        .failure => return error.TestUnexpectedResult,
    };
    defer model_catalog.freeModelCatalog(alloc, &from_hook);
    try std.testing.expect(containsId(from_hook.items, "mock-live-model"));
    try std.testing.expect(from_hook.items.len != catalog.known_ids.len);

    catalog.list_models_fn = null;
    const via_env = try catalog.provider.fetch(alloc, .{ .endpoint = "/v1/models" });
    var from_env = switch (via_env) {
        .catalog => |entries| entries,
        .failure => return error.TestUnexpectedResult,
    };
    defer model_catalog.freeModelCatalog(alloc, &from_env);
    try std.testing.expect(containsId(from_env.items, "mock-live-model"));
}

fn containsId(entries: []const model_catalog.ModelCatalogEntry, id: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return true;
    }
    return false;
}

test "session ensure creates then resumes last persisted agent" {
    const alloc = std.testing.allocator;
    var mock = try MockBridge.spawn(alloc);
    defer mock.stop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    try installBridgeEnviron(mock.url);
    defer clearBridgeEnviron();

    session.shutdown();
    defer session.shutdown();

    const created = try session.ensure(alloc, workspace, "composer-2.5", null);
    try std.testing.expectEqualStrings("agent_created_1", created.agent_id);

    session.noteResumeLast();
    const resumed = try session.ensure(alloc, workspace, "composer-2.5", null);
    try std.testing.expectEqualStrings("agent_created_1", resumed.agent_id);
}
