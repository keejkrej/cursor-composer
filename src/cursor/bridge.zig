const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const READY_PREFIX = "cursor-sdk-bridge ready ";

pub const Discovery = struct {
    schema_version: i64,
    transport: []u8,
    protocol: []u8,
    url: []u8,
    auth_token_file: []u8,
    server_version: []u8,
    pid: i64,

    pub fn deinit(self: *Discovery, alloc: Allocator) void {
        alloc.free(self.transport);
        alloc.free(self.protocol);
        alloc.free(self.url);
        alloc.free(self.auth_token_file);
        alloc.free(self.server_version);
        self.* = undefined;
    }
};

pub const Endpoint = struct {
    url: []u8,
    token: []u8,

    pub fn deinit(self: *Endpoint, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.token);
        self.* = undefined;
    }
};

pub const Manager = struct {
    alloc: Allocator,
    child: ?std.process.Child = null,
    endpoint: ?Endpoint = null,
    stderr_thread: ?std.Thread = null,
    stderr_done: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Manager {
        return .{ .alloc = alloc };
    }

    pub fn attach(self: *Manager, url: []const u8, token: []const u8) !Endpoint {
        const endpoint = Endpoint{
            .url = try self.alloc.dupe(u8, url),
            .token = try self.alloc.dupe(u8, token),
        };
        self.endpoint = endpoint;
        return endpoint;
    }

    pub fn start(self: *Manager, binary: []const u8, workspace: []const u8, api_key: ?[]const u8) !Endpoint {
        if (self.endpoint) |existing| return existing;

        const zio = io_mod.getIo();
        var env_map = io_mod.cloneEnvironMap(self.alloc) catch std.process.Environ.Map.init(self.alloc);
        defer env_map.deinit();
        try env_map.put("CURSOR_SDK_CLIENT_LANGUAGE", "zig");
        if (api_key) |key| try env_map.put("CURSOR_API_KEY", key);

        var child = std.process.spawn(zio, .{
            .argv = &.{ binary, "--workspace", workspace },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
            .environ_map = &env_map,
        }) catch |err| {
            return switch (err) {
                error.FileNotFound => error.BridgeBinaryMissing,
                else => err,
            };
        };

        const stderr = child.stderr orelse {
            child.kill(zio);
            return error.BridgeHandshakeFailed;
        };
        var discovery = waitReadyLine(self.alloc, stderr) catch |err| {
            child.kill(zio);
            return err;
        };
        defer discovery.deinit(self.alloc);

        if (discovery.schema_version != 1 or
            !std.mem.eql(u8, discovery.transport, "tcp") or
            !std.mem.eql(u8, discovery.protocol, "connect"))
        {
            child.kill(zio);
            return error.UnsupportedBridgeDiscovery;
        }

        const token = readTokenFile(self.alloc, discovery.auth_token_file) catch |err| {
            child.kill(zio);
            return err;
        };
        errdefer self.alloc.free(token);

        const endpoint = Endpoint{
            .url = try self.alloc.dupe(u8, discovery.url),
            .token = token,
        };
        self.child = child;
        self.endpoint = endpoint;

        self.stderr_thread = try std.Thread.spawn(.{}, drainStderr, .{ self, stderr });
        return endpoint;
    }

    pub fn stop(self: *Manager) void {
        self.stderr_done.store(true, .seq_cst);
        const zio = io_mod.getIo();
        if (self.child) |*child| {
            child.kill(zio);
            self.child = null;
        }
        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }
        if (self.endpoint) |*endpoint| {
            endpoint.deinit(self.alloc);
            self.endpoint = null;
        }
    }
};

fn drainStderr(self: *Manager, file: std.Io.File) void {
    const zio = io_mod.getIo();
    var read_buf: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;
    var reader = file.reader(zio, &read_buf);
    while (!self.stderr_done.load(.seq_cst)) {
        _ = reader.interface.readSliceShort(&scratch) catch break;
    }
}

pub fn parseReadyLine(alloc: Allocator, line: []const u8) !Discovery {
    const json_start = std.mem.indexOf(u8, line, READY_PREFIX) orelse return error.BridgeHandshakeFailed;
    const json_text = std.mem.trim(u8, line[json_start + READY_PREFIX.len ..], " \r\n");
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.BridgeHandshakeFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BridgeHandshakeFailed;
    const obj = parsed.value.object;

    const schema = obj.get("schemaVersion") orelse return error.BridgeHandshakeFailed;
    const schema_version: i64 = switch (schema) {
        .integer => |n| n,
        else => return error.UnsupportedBridgeDiscovery,
    };
    if (schema_version != 1) return error.UnsupportedBridgeDiscovery;

    return .{
        .schema_version = schema_version,
        .transport = try alloc.dupe(u8, asString(obj.get("transport")) orelse return error.UnsupportedBridgeDiscovery),
        .protocol = try alloc.dupe(u8, asString(obj.get("protocol")) orelse return error.UnsupportedBridgeDiscovery),
        .url = try alloc.dupe(u8, asString(obj.get("url")) orelse return error.BridgeHandshakeFailed),
        .auth_token_file = try alloc.dupe(u8, asString(obj.get("authTokenFile")) orelse return error.BridgeHandshakeFailed),
        .server_version = try alloc.dupe(u8, asString(obj.get("serverVersion")) orelse ""),
        .pid = switch (obj.get("pid") orelse .null) {
            .integer => |n| n,
            else => 0,
        },
    };
}

fn asString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return switch (item) {
        .string => |text| text,
        else => null,
    };
}

fn waitReadyLine(alloc: Allocator, stderr: std.Io.File) !Discovery {
    const zio = io_mod.getIo();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    const deadline = io_mod.milliTimestamp() + 30_000;
    var read_buf: [512]u8 = undefined;
    var reader = stderr.reader(zio, &read_buf);
    var byte: [1]u8 = undefined;
    while (io_mod.milliTimestamp() < deadline) {
        const n = reader.interface.readSliceShort(&byte) catch return error.BridgeExitedBeforeReady;
        if (n == 0) return error.BridgeExitedBeforeReady;
        if (byte[0] == '\n') {
            if (std.mem.indexOf(u8, line.items, READY_PREFIX) != null) {
                return parseReadyLine(alloc, line.items);
            }
            line.clearRetainingCapacity();
            continue;
        }
        try line.append(alloc, byte[0]);
    }
    return error.BridgeStartupTimeout;
}

fn readTokenFile(alloc: Allocator, path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return error.BridgeAuthTokenUnreadable;
    defer file.close(zio);
    const contents = io_mod.readFileToEnd(alloc, &file, 16 * 1024) catch return error.BridgeAuthTokenUnreadable;
    defer alloc.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == 0) return error.BridgeAuthTokenUnreadable;
    return alloc.dupe(u8, trimmed);
}

test "ready line parse rejects bad schema" {
    try std.testing.expectError(error.UnsupportedBridgeDiscovery, parseReadyLine(
        std.testing.allocator,
        "cursor-sdk-bridge ready {\"schemaVersion\":2,\"transport\":\"tcp\",\"protocol\":\"connect\",\"url\":\"http://127.0.0.1:1\",\"authTokenFile\":\"/tmp/t\"}",
    ));
}

test "ready line parse accepts discovery json" {
    var discovery = try parseReadyLine(
        std.testing.allocator,
        "noise\ncursor-sdk-bridge ready {\"schemaVersion\":1,\"serverVersion\":\"1.0.30\",\"pid\":9,\"transport\":\"tcp\",\"protocol\":\"connect\",\"url\":\"http://127.0.0.1:49152\",\"authTokenFile\":\"/tmp/token\"}\n",
    );
    defer discovery.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), discovery.schema_version);
    try std.testing.expectEqualStrings("tcp", discovery.transport);
    try std.testing.expectEqualStrings("connect", discovery.protocol);
    try std.testing.expectEqualStrings("http://127.0.0.1:49152", discovery.url);
}
