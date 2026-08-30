const std = @import("std");
const types = @import("../core/shared/types.zig");
const json_util = @import("json_util.zig");
const host_tools = @import("host_tools.zig");

/// Presentation actions the FX TUI already knows how to paint.
/// Produced only from Cursor `sdk.v1` stream JSON — no agent loop.
pub const Action = union(enum) {
    assistant_text: []const u8,
    thinking_text: []const u8,
    tool_started: struct {
        call_id: []const u8,
        name: []const u8,
        args_json: ?[]const u8 = null,
    },
    tool_finished: struct {
        call_id: []const u8,
        name: []const u8,
        ok: bool,
        result_json: ?[]const u8 = null,
    },
    status: []const u8,
    usage: []const u8,
    terminal_result: struct {
        status: []const u8,
        text: ?[]const u8 = null,
        error_message: ?[]const u8 = null,
    },
    ignore,
};

pub fn classifyToolActivity(name: []const u8) types.ToolActivityKind {
    return host_tools.classifyActivity(name);
}

pub fn actionFromEnvelope(alloc: std.mem.Allocator, payload: []const u8) !Action {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return .ignore;
    defer parsed.deinit();
    return actionFromValue(alloc, parsed.value);
}

pub fn actionFromValue(alloc: std.mem.Allocator, value: std.json.Value) !Action {
    if (value != .object) return .ignore;

    if (json_util.objectGet(value, "sdkMessage")) |message| {
        return try actionFromSdkMessage(alloc, message);
    }
    if (json_util.objectGet(value, "sdk_message")) |message| {
        return try actionFromSdkMessage(alloc, message);
    }
    if (json_util.objectGet(value, "interactionUpdate") orelse json_util.objectGet(value, "interaction_update")) |update| {
        return try actionFromInteractionUpdate(alloc, update);
    }
    if (json_util.objectGet(value, "result")) |result| {
        return .{ .terminal_result = .{
            .status = json_util.stringGet(result, "status") orelse
                json_util.stringGet(result, "lifecycleStatus") orelse
                "FINISHED",
            .text = json_util.stringGet(result, "result") orelse json_util.stringGet(result, "text"),
            .error_message = json_util.stringGet(result, "errorCode") orelse json_util.stringGet(result, "error_code"),
        } };
    }
    if (json_util.objectGet(value, "done") != null) return .ignore;
    return .ignore;
}

fn actionFromSdkMessage(alloc: std.mem.Allocator, message: std.json.Value) !Action {
    const kind = json_util.stringGet(message, "type") orelse return .ignore;
    const payload = json_util.objectGet(message, "message") orelse message;

    if (std.mem.eql(u8, kind, "assistant")) {
        if (assistantText(payload)) |text| {
            if (text.len == 0) return .ignore;
            return .{ .assistant_text = try alloc.dupe(u8, text) };
        }
        return .ignore;
    }
    if (std.mem.eql(u8, kind, "thinking")) {
        const text = json_util.stringGet(payload, "text") orelse json_util.stringGet(message, "text") orelse return .ignore;
        if (text.len == 0) return .ignore;
        return .{ .thinking_text = try alloc.dupe(u8, text) };
    }
    if (std.mem.eql(u8, kind, "tool_call")) {
        const call_id = json_util.stringGet(payload, "call_id") orelse
            json_util.stringGet(payload, "callId") orelse
            json_util.stringGet(message, "call_id") orelse
            json_util.stringGet(message, "callId") orelse
            "tool";
        const name = json_util.stringGet(payload, "name") orelse
            json_util.stringGet(message, "name") orelse
            "tool";
        const status = json_util.stringGet(payload, "status") orelse
            json_util.stringGet(message, "status") orelse
            "running";
        if (std.mem.eql(u8, status, "running")) {
            var args_json: ?[]const u8 = null;
            if (json_util.objectGet(payload, "args") orelse json_util.objectGet(message, "args")) |args| {
                args_json = try json_util.stringifyAlloc(alloc, args);
            }
            return .{ .tool_started = .{
                .call_id = try alloc.dupe(u8, call_id),
                .name = try alloc.dupe(u8, host_tools.canonicalName(name)),
                .args_json = args_json,
            } };
        }
        var result_json: ?[]const u8 = null;
        if (json_util.objectGet(payload, "result") orelse json_util.objectGet(message, "result")) |result| {
            result_json = try json_util.stringifyAlloc(alloc, result);
        }
        return .{ .tool_finished = .{
            .call_id = try alloc.dupe(u8, call_id),
            .name = try alloc.dupe(u8, host_tools.canonicalName(name)),
            .ok = !std.mem.eql(u8, status, "error"),
            .result_json = result_json,
        } };
    }
    if (std.mem.eql(u8, kind, "status")) {
        const status = json_util.stringGet(payload, "status") orelse
            json_util.stringGet(message, "status") orelse
            "RUNNING";
        const detail = json_util.stringGet(payload, "message") orelse
            json_util.stringGet(message, "message") orelse
            "";
        if (detail.len > 0) {
            return .{ .status = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ status, detail }) };
        }
        return .{ .status = try alloc.dupe(u8, status) };
    }
    if (std.mem.eql(u8, kind, "usage")) {
        return .{ .usage = try alloc.dupe(u8, "usage") };
    }
    return .ignore;
}

fn assistantText(payload: std.json.Value) ?[]const u8 {
    if (json_util.arrayGet(payload, "content")) |blocks| {
        for (blocks.items) |block| {
            const typ = json_util.stringGet(block, "type") orelse continue;
            if (std.mem.eql(u8, typ, "text")) {
                return json_util.stringGet(block, "text");
            }
        }
    }
    const nested = json_util.objectGet(payload, "message") orelse return json_util.stringGet(payload, "text");
    if (json_util.arrayGet(nested, "content")) |blocks| {
        for (blocks.items) |block| {
            const typ = json_util.stringGet(block, "type") orelse continue;
            if (std.mem.eql(u8, typ, "text")) {
                return json_util.stringGet(block, "text");
            }
        }
    }
    return json_util.stringGet(nested, "text");
}

fn actionFromInteractionUpdate(alloc: std.mem.Allocator, update: std.json.Value) !Action {
    const typ = json_util.stringGet(update, "type") orelse return .ignore;
    if (std.mem.eql(u8, typ, "text-delta") or std.mem.eql(u8, typ, "text_delta")) {
        const text = json_util.stringGet(update, "text") orelse return .ignore;
        if (text.len == 0) return .ignore;
        return .{ .assistant_text = try alloc.dupe(u8, text) };
    }
    if (std.mem.eql(u8, typ, "thinking-delta") or std.mem.eql(u8, typ, "thinking_delta")) {
        const text = json_util.stringGet(update, "text") orelse return .ignore;
        if (text.len == 0) return .ignore;
        return .{ .thinking_text = try alloc.dupe(u8, text) };
    }
    return .ignore;
}

test "assistant envelope maps to text" {
    const payload =
        \\{"sdkMessage":{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}}
    ;
    const action = try actionFromEnvelope(std.testing.allocator, payload);
    defer freeAction(std.testing.allocator, action);
    try std.testing.expectEqualStrings("hello", action.assistant_text);
}

test "tool_call running and completed map to lifecycle" {
    const start = try actionFromEnvelope(std.testing.allocator,
        \\{"sdkMessage":{"type":"tool_call","call_id":"c1","name":"Read","status":"running","args":{"path":"a"}}}
    );
    defer freeAction(std.testing.allocator, start);
    try std.testing.expectEqualStrings("read_file", start.tool_started.name);
    try std.testing.expectEqual(.read, classifyToolActivity(start.tool_started.name));

    const done = try actionFromEnvelope(std.testing.allocator,
        \\{"sdkMessage":{"type":"tool_call","callId":"c1","name":"Read","status":"completed","result":{"ok":true}}}
    );
    defer freeAction(std.testing.allocator, done);
    try std.testing.expect(done.tool_finished.ok);
}

test "AskQuestion stream events map to ask_user_question" {
    const start = try actionFromEnvelope(std.testing.allocator,
        \\{"sdkMessage":{"type":"tool_call","call_id":"q1","name":"AskQuestion","status":"running","args":{"question":"Ship?"}}}
    );
    defer freeAction(std.testing.allocator, start);
    try std.testing.expectEqualStrings("ask_user_question", start.tool_started.name);
    try std.testing.expectEqual(.ask, classifyToolActivity(start.tool_started.name));
}

test "empty envelope is keepalive ignore" {
    const action = try actionFromEnvelope(std.testing.allocator, "{}");
    try std.testing.expect(action == .ignore);
}

test "unknown envelope is ignored" {
    const action = try actionFromEnvelope(std.testing.allocator, "{\"futureCase\":{}}");
    try std.testing.expect(action == .ignore);
}

pub fn freeAction(alloc: std.mem.Allocator, action: Action) void {
    switch (action) {
        .assistant_text => |text| if (owned(text)) alloc.free(text),
        .thinking_text => |text| if (owned(text)) alloc.free(text),
        .status, .usage => |text| alloc.free(text),
        .tool_started => |tool| {
            alloc.free(tool.call_id);
            alloc.free(tool.name);
            if (tool.args_json) |json| alloc.free(json);
        },
        .tool_finished => |tool| {
            alloc.free(tool.call_id);
            alloc.free(tool.name);
            if (tool.result_json) |json| alloc.free(json);
        },
        .terminal_result, .ignore => {},
    }
}

fn owned(_: []const u8) bool {
    return true;
}
