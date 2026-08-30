const std = @import("std");
const connect = @import("connect.zig");
const json_util = @import("json_util.zig");
const host_tools = @import("host_tools.zig");

const Allocator = std.mem.Allocator;

pub const Client = struct {
    alloc: Allocator,
    transport: connect.Transport,
    api_key: []const u8,

    pub fn init(alloc: Allocator, url: []const u8, token: []const u8, api_key: []const u8) Client {
        return .{
            .alloc = alloc,
            .transport = .{ .alloc = alloc, .base_url = url, .token = token },
            .api_key = api_key,
        };
    }

    pub fn ping(self: Client) !void {
        const body = try self.transport.unaryJson("SdkBridgeControlService", "Ping", "{}");
        defer self.alloc.free(body);
    }

    pub fn shutdown(self: Client) void {
        const body = self.transport.unaryJson("SdkBridgeControlService", "Shutdown", "{\"graceSeconds\":0}") catch return;
        self.alloc.free(body);
    }

    pub fn me(self: Client) ![]u8 {
        const req = try std.fmt.allocPrint(self.alloc, "{{\"options\":{{\"apiKey\":{s}}}}}", .{try quoted(self.alloc, self.api_key)});
        defer self.alloc.free(req);
        return self.transport.unaryJson("SdkCursorService", "Me", req);
    }

    pub fn listModels(self: Client) ![]u8 {
        const key = try quoted(self.alloc, self.api_key);
        defer self.alloc.free(key);
        const req = try std.fmt.allocPrint(self.alloc, "{{\"options\":{{\"apiKey\":{s}}}}}", .{key});
        defer self.alloc.free(req);
        return self.transport.unaryJson("SdkCursorService", "ListModels", req);
    }

    pub fn createAgent(self: Client, cwd: []const u8, model: []const u8) ![]u8 {
        return self.createAgentWithTools(cwd, model, true);
    }

    pub fn createAgentWithTools(self: Client, cwd: []const u8, model: []const u8, advertise_tools: bool) ![]u8 {
        const req = try agentRequestJson(self.alloc, self.api_key, cwd, model, null, advertise_tools);
        defer self.alloc.free(req);
        const body = try self.transport.unaryJson("SdkAgentService", "CreateAgent", req);
        defer self.alloc.free(body);
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch return error.CreateAgentFailed;
        defer parsed.deinit();
        const id = json_util.stringGet(parsed.value, "agentId") orelse
            json_util.stringGet(parsed.value, "agent_id") orelse
            return error.CreateAgentFailed;
        return self.alloc.dupe(u8, id);
    }

    pub fn resumeAgent(self: Client, agent_id: []const u8, cwd: []const u8, model: []const u8) ![]u8 {
        return self.resumeAgentWithTools(agent_id, cwd, model, true);
    }

    pub fn resumeAgentWithTools(
        self: Client,
        agent_id: []const u8,
        cwd: []const u8,
        model: []const u8,
        advertise_tools: bool,
    ) ![]u8 {
        const req = try agentRequestJson(self.alloc, self.api_key, cwd, model, agent_id, advertise_tools);
        defer self.alloc.free(req);
        const body = try self.transport.unaryJson("SdkAgentService", "ResumeAgent", req);
        defer self.alloc.free(body);
        return self.alloc.dupe(u8, agent_id);
    }

    pub fn setToolCallback(self: Client, url: []const u8, auth_token: []const u8) !void {
        const url_q = try quoted(self.alloc, url);
        defer self.alloc.free(url_q);
        const token_q = try quoted(self.alloc, auth_token);
        defer self.alloc.free(token_q);
        const req = try std.fmt.allocPrint(
            self.alloc,
            "{{\"url\":{s},\"authToken\":{s}}}",
            .{ url_q, token_q },
        );
        defer self.alloc.free(req);
        const body = try self.transport.unaryJson("SdkBridgeControlService", "SetToolCallback", req);
        self.alloc.free(body);
    }

    pub fn waitLiveRun(self: Client, run_id: []const u8) !void {
        const run_q = try quoted(self.alloc, run_id);
        defer self.alloc.free(run_q);
        const req = try std.fmt.allocPrint(self.alloc, "{{\"runId\":{s}}}", .{run_q});
        defer self.alloc.free(req);
        const body = try self.transport.unaryJson("SdkAgentService", "WaitLiveRun", req);
        self.alloc.free(body);
    }

    pub fn cancelRun(self: Client, run_id: []const u8, agent_id: []const u8) !void {
        const run_q = try quoted(self.alloc, run_id);
        defer self.alloc.free(run_q);
        const agent_q = try quoted(self.alloc, agent_id);
        defer self.alloc.free(agent_q);
        const req = try std.fmt.allocPrint(
            self.alloc,
            "{{\"runId\":{s},\"agentId\":{s}}}",
            .{ run_q, agent_q },
        );
        defer self.alloc.free(req);
        const body = try self.transport.unaryJson("SdkAgentService", "CancelRun", req);
        self.alloc.free(body);
    }

    pub fn send(
        self: Client,
        agent_id: []const u8,
        text: []const u8,
        model: []const u8,
        on_message: *const fn (ctx: *anyopaque, payload: []const u8) anyerror!void,
        ctx: *anyopaque,
    ) !void {
        const id_q = try quoted(self.alloc, agent_id);
        defer self.alloc.free(id_q);
        const text_q = try quoted(self.alloc, text);
        defer self.alloc.free(text_q);
        const model_q = try quoted(self.alloc, model);
        defer self.alloc.free(model_q);
        const req = try std.fmt.allocPrint(
            self.alloc,
            "{{\"agentId\":{s},\"message\":{{\"text\":{s}}},\"options\":{{\"model\":{{\"id\":{s}}},\"enableDeltas\":true}}}}",
            .{ id_q, text_q, model_q },
        );
        defer self.alloc.free(req);
        try self.transport.streamJson("SdkAgentService", "Send", req, on_message, ctx);
    }
};

pub fn agentRequestJson(
    alloc: Allocator,
    api_key: []const u8,
    cwd: []const u8,
    model: []const u8,
    agent_id: ?[]const u8,
    advertise_tools: bool,
) ![]u8 {
    const key = try quoted(alloc, api_key);
    defer alloc.free(key);
    const model_q = try quoted(alloc, model);
    defer alloc.free(model_q);
    const cwd_q = try quoted(alloc, cwd);
    defer alloc.free(cwd_q);
    const local = if (advertise_tools) blk: {
        const tools = try host_tools.customToolsJson(alloc);
        defer alloc.free(tools);
        break :blk try std.fmt.allocPrint(
            alloc,
            "{{\"cwd\":[{s}],\"customTools\":{s}}}",
            .{ cwd_q, tools },
        );
    } else try std.fmt.allocPrint(alloc, "{{\"cwd\":[{s}]}}", .{cwd_q});
    defer alloc.free(local);
    if (agent_id) |id| {
        const id_q = try quoted(alloc, id);
        defer alloc.free(id_q);
        return std.fmt.allocPrint(
            alloc,
            "{{\"agentId\":{s},\"options\":{{\"apiKey\":{s},\"model\":{{\"id\":{s}}},\"local\":{s}}}}}",
            .{ id_q, key, model_q, local },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "{{\"options\":{{\"apiKey\":{s},\"model\":{{\"id\":{s}}},\"local\":{s}}}}}",
        .{ key, model_q, local },
    );
}

fn quoted(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(text, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "json string quoting escapes" {
    const q = try quoted(std.testing.allocator, "say \"hi\"\n");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\n\"", q);
}

test "create and resume agent JSON include customTools" {
    const alloc = std.testing.allocator;
    const created = try agentRequestJson(alloc, "k", "/tmp/ws", "grok-4.6", null, true);
    defer alloc.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"customTools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"AskQuestion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"ask_user_question\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"agentId\"") == null);
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, created, .{});
        defer parsed.deinit();
    }

    const resumed = try agentRequestJson(alloc, "k", "/tmp/ws", "grok-4.6", "agent_1", true);
    defer alloc.free(resumed);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"agentId\":\"agent_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"customTools\"") != null);
}

test "agent JSON can omit customTools" {
    const alloc = std.testing.allocator;
    const created = try agentRequestJson(alloc, "k", "/tmp/ws", "grok-4.6", null, false);
    defer alloc.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "customTools") == null);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"cwd\"") != null);
}
