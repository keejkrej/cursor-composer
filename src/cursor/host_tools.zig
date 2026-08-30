const std = @import("std");
const types = @import("../core/shared/types.zig");
const ask_question = @import("ask_question.zig");

const Allocator = std.mem.Allocator;

/// Cursor-facing custom tool. The fx picker is an implementation detail.
pub const advertised_name = ask_question.name;

/// Tools the host executes. Cursor built-ins (Read/Write/Shell/…) stay in the
/// bridge; `AskQuestion` is advertised so the model can reach the TUI picker.
pub const advertised = [_][]const u8{
    advertised_name,
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
    const entry = try ask_question.definitionJson(alloc);
    defer alloc.free(entry);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    try out.writer.writeAll(entry);
    try out.writer.writeByte('}');
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

test "custom tools JSON advertises Cursor AskQuestion schema only" {
    const json = try customToolsJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqual(@as(usize, 1), advertised.len);
    try std.testing.expectEqualStrings(advertised_name, advertised[0]);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"AskQuestion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ask_user_question\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allowMultiple\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, ask_question.description) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "When NOT to use") == null);
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.object.count());
        const tool = parsed.value.object.get("AskQuestion").?;
        try std.testing.expectEqualStrings(ask_question.description, tool.object.get("description").?.string);
        const schema = tool.object.get("inputSchema").?.object;
        try std.testing.expect(schema.get("properties").?.object.get("questions") != null);
        try std.testing.expect(schema.get("properties").?.object.get("title") != null);
    }
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
