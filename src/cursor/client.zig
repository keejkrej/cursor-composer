const std = @import("std");
const connect = @import("connect.zig");
const json_util = @import("json_util.zig");

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
        const key = try quoted(self.alloc, self.api_key);
        defer self.alloc.free(key);
        const model_q = try quoted(self.alloc, model);
        defer self.alloc.free(model_q);
        const cwd_q = try quoted(self.alloc, cwd);
        defer self.alloc.free(cwd_q);
        const req = try std.fmt.allocPrint(
            self.alloc,
            "{{\"options\":{{\"apiKey\":{s},\"model\":{{\"id\":{s}}},\"local\":{{\"cwd\":[{s}]}}}}}}",
            .{ key, model_q, cwd_q },
        );
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
        const key = try quoted(self.alloc, self.api_key);
        defer self.alloc.free(key);
        const id_q = try quoted(self.alloc, agent_id);
        defer self.alloc.free(id_q);
        const model_q = try quoted(self.alloc, model);
        defer self.alloc.free(model_q);
        const cwd_q = try quoted(self.alloc, cwd);
        defer self.alloc.free(cwd_q);
        const req = try std.fmt.allocPrint(
            self.alloc,
            "{{\"agentId\":{s},\"options\":{{\"apiKey\":{s},\"model\":{{\"id\":{s}}},\"local\":{{\"cwd\":[{s}]}}}}}}",
            .{ id_q, key, model_q, cwd_q },
        );
        defer self.alloc.free(req);
        const body = try self.transport.unaryJson("SdkAgentService", "ResumeAgent", req);
        defer self.alloc.free(body);
        return self.alloc.dupe(u8, agent_id);
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
