const std = @import("std");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const ask_description =
    "Ask the user 1-4 multiple-choice questions in the interactive cc TUI when a concrete decision blocks progress after local files, git state, or tool output cannot answer it.";

const ask_input_schema =
    \\{"type":"object","properties":{"questions":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object","properties":{"question":{"type":"string","description":"Specific blocking decision shown to the user"},"options":{"type":"array","minItems":2,"maxItems":6,"items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"]}}},"required":["question","options"]}}},"required":["questions"]}
;

/// Tools the host executes. Cursor built-ins (Read/Write/Shell/…) stay in the
/// bridge; these names are advertised so the model can reach the fx TUI.
pub const advertised = [_][]const u8{
    "AskQuestion",
    "ask_user_question",
};

pub fn isQuestionTool(name: []const u8) bool {
    return eqlAny(name, &.{
        "AskQuestion",
        "ask_user_question",
        "askUserQuestion",
        "ask_question",
    });
}

pub fn canonicalName(name: []const u8) []const u8 {
    if (isQuestionTool(name)) return "ask_user_question";
    if (eqlAny(name, &.{ "Read", "read_file" })) return "read_file";
    if (eqlAny(name, &.{ "Write", "write_file" })) return "write_file";
    if (eqlAny(name, &.{ "StrReplace", "Edit", "edit_file", "ApplyPatch" })) return "edit_file";
    if (eqlAny(name, &.{ "Glob", "glob_files" })) return "glob_files";
    if (eqlAny(name, &.{ "Grep", "grep_files" })) return "grep_files";
    if (eqlAny(name, &.{ "Shell", "Bash", "terminal" })) return "terminal";
    if (eqlAny(name, &.{ "WebSearch", "web_search" })) return "web_search";
    if (eqlAny(name, &.{ "WebFetch", "web_fetch" })) return "web_fetch";
    if (eqlAny(name, &.{ "Task", "subagent" })) return "subagent";
    return name;
}

pub fn classifyActivity(name: []const u8) types.ToolActivityKind {
    const canonical = canonicalName(name);
    if (std.mem.eql(u8, canonical, "ask_user_question")) return .ask;
    if (std.mem.eql(u8, canonical, "read_file")) return .read;
    if (std.mem.eql(u8, canonical, "write_file")) return .write;
    if (std.mem.eql(u8, canonical, "edit_file")) return .edit;
    if (std.mem.eql(u8, canonical, "glob_files") or std.mem.eql(u8, canonical, "grep_files")) return .list;
    if (std.mem.eql(u8, canonical, "subagent")) return .subagent;
    return .command;
}

/// JSON object for `LocalAgentOptions.custom_tools`.
pub fn customToolsJson(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (advertised, 0..) |name, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(name, .{}, &out.writer);
        try out.writer.writeAll(":{\"description\":");
        try std.json.Stringify.value(ask_description, .{}, &out.writer);
        try out.writer.writeAll(",\"inputSchema\":");
        try out.writer.writeAll(ask_input_schema);
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Rewrites Cursor-style or shorthand question args into fx `{questions:[…]}`.
pub fn normalizeQuestionArgs(alloc: Allocator, args_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch
        return alloc.dupe(u8, args_json);
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, args_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"questions\":[");

    if (parsed.value.object.get("questions")) |questions| {
        if (questions != .array) return alloc.dupe(u8, args_json);
        for (questions.array.items, 0..) |item, index| {
            if (index > 0) try out.writer.writeByte(',');
            writeNormalizedQuestion(&out.writer, item) catch return alloc.dupe(u8, args_json);
        }
    } else if (parsed.value.object.get("question")) |question| {
        writeNormalizedQuestion(&out.writer, parsed.value) catch return alloc.dupe(u8, args_json);
        _ = question;
    } else {
        return alloc.dupe(u8, args_json);
    }

    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

/// CallCustomTool `result` must be a JSON object. Arrays become `{answers:[…]}`
/// and scalars become `{value:"…"}`.
pub fn wrapCustomToolResult(alloc: Allocator, body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') return alloc.dupe(u8, trimmed);
    if (trimmed.len > 0 and trimmed[0] == '[') {
        return std.fmt.allocPrint(alloc, "{{\"answers\":{s}}}", .{trimmed});
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"value\":");
    try std.json.Stringify.value(trimmed, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeNormalizedQuestion(writer: *std.Io.Writer, value: std.json.Value) !void {
    if (value != .object) return error.InvalidArguments;
    const question = switch (value.object.get("question") orelse return error.InvalidArguments) {
        .string => |text| text,
        else => return error.InvalidArguments,
    };
    const options = value.object.get("options") orelse return error.InvalidArguments;
    if (options != .array) return error.InvalidArguments;

    try writer.writeAll("{\"question\":");
    try std.json.Stringify.value(question, .{}, writer);
    try writer.writeAll(",\"options\":[");
    for (options.array.items, 0..) |option, index| {
        if (index > 0) try writer.writeByte(',');
        switch (option) {
            .string => |label| {
                try writer.writeAll("{\"label\":");
                try std.json.Stringify.value(label, .{}, writer);
                try writer.writeByte('}');
            },
            .object => {
                const label = switch (option.object.get("label") orelse return error.InvalidArguments) {
                    .string => |text| text,
                    else => return error.InvalidArguments,
                };
                try writer.writeAll("{\"label\":");
                try std.json.Stringify.value(label, .{}, writer);
                if (option.object.get("description")) |desc| {
                    if (desc == .string) {
                        try writer.writeAll(",\"description\":");
                        try std.json.Stringify.value(desc.string, .{}, writer);
                    }
                }
                try writer.writeByte('}');
            },
            else => return error.InvalidArguments,
        }
    }
    try writer.writeAll("]}");
}

fn eqlAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

test "question tool aliases map to ask_user_question" {
    try std.testing.expect(isQuestionTool("AskQuestion"));
    try std.testing.expect(isQuestionTool("ask_user_question"));
    try std.testing.expectEqualStrings("ask_user_question", canonicalName("AskQuestion"));
    try std.testing.expectEqual(types.ToolActivityKind.ask, classifyActivity("AskQuestion"));
}

test "Cursor built-in names map to fx tools" {
    try std.testing.expectEqualStrings("read_file", canonicalName("Read"));
    try std.testing.expectEqualStrings("write_file", canonicalName("Write"));
    try std.testing.expectEqualStrings("edit_file", canonicalName("StrReplace"));
    try std.testing.expectEqualStrings("terminal", canonicalName("Shell"));
    try std.testing.expectEqual(types.ToolActivityKind.read, classifyActivity("Read"));
    try std.testing.expectEqual(types.ToolActivityKind.command, classifyActivity("Shell"));
}

test "custom tools JSON advertises both AskQuestion names" {
    const json = try customToolsJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"AskQuestion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ask_user_question\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inputSchema\"") != null);
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
    }
}

test "normalize accepts string options and a single question" {
    const alloc = std.testing.allocator;
    const out = try normalizeQuestionArgs(
        alloc,
        "{\"question\":\"Ship it?\",\"options\":[\"Yes\",\"No\"]}",
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"questions\":[{\"question\":\"Ship it?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}",
        out,
    );
}

test "wrapCustomToolResult boxes arrays and sentinels" {
    const alloc = std.testing.allocator;
    const answers = try wrapCustomToolResult(alloc, "[{\"question\":\"Q?\",\"answer\":\"Yes\"}]");
    defer alloc.free(answers);
    try std.testing.expectEqualStrings("{\"answers\":[{\"question\":\"Q?\",\"answer\":\"Yes\"}]}", answers);

    const sentinel = try wrapCustomToolResult(alloc, "(user cancelled the question)");
    defer alloc.free(sentinel);
    try std.testing.expectEqualStrings("{\"value\":\"(user cancelled the question)\"}", sentinel);

    const object = try wrapCustomToolResult(alloc, "{\"ok\":true}");
    defer alloc.free(object);
    try std.testing.expectEqualStrings("{\"ok\":true}", object);
}
