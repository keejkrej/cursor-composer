const std = @import("std");

const Allocator = std.mem.Allocator;

const cancel_sentinel = "(user cancelled the question)";

pub const name = "AskQuestion";

pub const description =
    "Ask the user one or more multiple-choice questions. Prefer this over listing choices in text. Each question needs a unique id, a prompt, and at least two options with id and label. Set allowMultiple when more than one option can apply.";

/// Cursor ACP `cursor/ask_question` input schema (model-facing).
pub const input_schema =
    \\{"type":"object","properties":{"title":{"type":"string","description":"Optional heading for this round of questions"},"questions":{"type":"array","minItems":1,"items":{"type":"object","properties":{"id":{"type":"string","description":"Stable id for this question"},"prompt":{"type":"string","description":"Question shown to the user"},"options":{"type":"array","minItems":2,"items":{"type":"object","properties":{"id":{"type":"string"},"label":{"type":"string"}},"required":["id","label"]}},"allowMultiple":{"type":"boolean","description":"When true, more than one option may be selected"}},"required":["id","prompt","options"]}}},"required":["questions"]}
;

pub fn definitionJson(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(name, .{}, &out.writer);
    try out.writer.writeAll(":{\"description\":");
    try std.json.Stringify.value(description, .{}, &out.writer);
    try out.writer.writeAll(",\"inputSchema\":");
    try out.writer.writeAll(input_schema);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Rewrites Cursor AskQuestion args into fx `{questions:[{question, options:[{label}]}]}`.
pub fn toFxArgs(alloc: Allocator, args_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch
        return alloc.dupe(u8, args_json);
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, args_json);

    const questions = parsed.value.object.get("questions") orelse {
        if (parsed.value.object.get("prompt") != null or parsed.value.object.get("question") != null) {
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            try out.writer.writeAll("{\"questions\":[");
            writeFxQuestion(&out.writer, parsed.value) catch return alloc.dupe(u8, args_json);
            try out.writer.writeAll("]}");
            return out.toOwnedSlice();
        }
        return alloc.dupe(u8, args_json);
    };
    if (questions != .array) return alloc.dupe(u8, args_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"questions\":[");
    for (questions.array.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        writeFxQuestion(&out.writer, item) catch return alloc.dupe(u8, args_json);
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

/// Maps an fx picker result onto Cursor's AskQuestion outcome object.
pub fn encodeResult(alloc: Allocator, cursor_args_json: []const u8, fx_body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, fx_body, " \t\r\n");
    if (std.mem.eql(u8, trimmed, cancel_sentinel)) {
        return alloc.dupe(u8, "{\"outcome\":\"cancelled\"}");
    }
    if (trimmed.len > 0 and trimmed[0] == '(') {
        const reason: []const u8 = if (std.mem.indexOf(u8, trimmed, "only available") != null)
            "AskQuestion is only available in the interactive shell"
        else
            "AskQuestion arguments were invalid";
        return skippedJson(alloc, reason);
    }
    if (trimmed.len == 0 or (trimmed[0] != '[' and trimmed[0] != '{')) {
        return skippedJson(alloc, trimmed);
    }

    const parsed_body = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch
        return skippedJson(alloc, trimmed);
    defer parsed_body.deinit();

    const answer_items: []const std.json.Value = switch (parsed_body.value) {
        .array => |array| array.items,
        .object => |object| blk: {
            if (object.get("outcome")) |_| return alloc.dupe(u8, trimmed);
            const answers = object.get("answers") orelse return skippedJson(alloc, trimmed);
            if (answers != .array) return skippedJson(alloc, trimmed);
            break :blk answers.array.items;
        },
        else => return skippedJson(alloc, trimmed),
    };

    const parsed_args = std.json.parseFromSlice(std.json.Value, alloc, cursor_args_json, .{}) catch
        return skippedJson(alloc, trimmed);
    defer parsed_args.deinit();

    var one_buf: [1]std.json.Value = undefined;
    const cursor_questions: []const std.json.Value = blk: {
        if (parsed_args.value != .object) break :blk &.{};
        if (parsed_args.value.object.get("questions")) |questions| {
            if (questions == .array) break :blk questions.array.items;
            break :blk &.{};
        }
        if (parsed_args.value.object.get("prompt") != null or parsed_args.value.object.get("question") != null) {
            one_buf[0] = parsed_args.value;
            break :blk one_buf[0..1];
        }
        break :blk &.{};
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"outcome\":\"answered\",\"answers\":[");

    for (answer_items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        const answer_label = answerLabel(item) orelse "";
        const cursor_question: ?std.json.Value = if (index < cursor_questions.len) cursor_questions[index] else null;
        const question_id = questionId(cursor_question, index);
        const option_id = selectedOptionId(cursor_question, answer_label) orelse answer_label;

        try out.writer.writeAll("{\"questionId\":");
        try std.json.Stringify.value(question_id, .{}, &out.writer);
        try out.writer.writeAll(",\"selectedOptionIds\":[");
        try std.json.Stringify.value(option_id, .{}, &out.writer);
        try out.writer.writeAll("]}");
    }

    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn skippedJson(alloc: Allocator, reason: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"outcome\":\"skipped\",\"reason\":");
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeFxQuestion(writer: *std.Io.Writer, value: std.json.Value) !void {
    if (value != .object) return error.InvalidArguments;
    const prompt = stringField(value.object, &.{ "prompt", "question" }) orelse return error.InvalidArguments;
    const options = value.object.get("options") orelse return error.InvalidArguments;
    if (options != .array) return error.InvalidArguments;

    try writer.writeAll("{\"question\":");
    try std.json.Stringify.value(prompt, .{}, writer);
    try writer.writeAll(",\"options\":[");
    for (options.array.items, 0..) |option, index| {
        if (index > 0) try writer.writeByte(',');
        const label = optionLabel(option) orelse return error.InvalidArguments;
        try writer.writeAll("{\"label\":");
        try std.json.Stringify.value(label, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn questionId(question: ?std.json.Value, index: usize) []const u8 {
    if (question) |value| {
        if (value == .object) {
            if (stringField(value.object, &.{"id"})) |id| return id;
        }
    }
    return switch (index) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        else => "0",
    };
}

fn selectedOptionId(question: ?std.json.Value, answer_label: []const u8) ?[]const u8 {
    const value = question orelse return null;
    if (value != .object) return null;
    const options = value.object.get("options") orelse return null;
    if (options != .array) return null;
    for (options.array.items) |option| {
        const label = optionLabel(option) orelse continue;
        if (std.ascii.eqlIgnoreCase(label, answer_label)) {
            return optionId(option) orelse label;
        }
    }
    return null;
}

fn optionLabel(option: std.json.Value) ?[]const u8 {
    return switch (option) {
        .string => |label| label,
        .object => stringField(option.object, &.{"label"}),
        else => null,
    };
}

fn optionId(option: std.json.Value) ?[]const u8 {
    return switch (option) {
        .string => |label| label,
        .object => stringField(option.object, &.{"id"}),
        else => null,
    };
}

fn answerLabel(item: std.json.Value) ?[]const u8 {
    if (item != .object) return null;
    return stringField(item.object, &.{"answer"});
}

fn stringField(object: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name_field| {
        if (object.get(name_field)) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return null;
}

test "toFxArgs maps Cursor prompt and option ids onto fx labels" {
    const alloc = std.testing.allocator;
    const out = try toFxArgs(
        alloc,
        \\{"title":"Need input","questions":[{"id":"q1","prompt":"Which mode?","options":[{"id":"agent","label":"Agent"},{"id":"plan","label":"Plan"}],"allowMultiple":false}]}
    ,
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"questions\":[{\"question\":\"Which mode?\",\"options\":[{\"label\":\"Agent\"},{\"label\":\"Plan\"}]}]}",
        out,
    );
}

test "encodeResult maps selected labels onto Cursor option ids" {
    const alloc = std.testing.allocator;
    const args =
        \\{"questions":[{"id":"q1","prompt":"Which mode?","options":[{"id":"agent","label":"Agent"},{"id":"plan","label":"Plan"}]}]}
    ;
    const encoded = try encodeResult(alloc, args, "[{\"question\":\"Which mode?\",\"answer\":\"Plan\"}]");
    defer alloc.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"outcome\":\"answered\",\"answers\":[{\"questionId\":\"q1\",\"selectedOptionIds\":[\"plan\"]}]}",
        encoded,
    );
}

test "encodeResult maps cancel and skipped sentinels" {
    const alloc = std.testing.allocator;
    const cancelled = try encodeResult(alloc, "{}", cancel_sentinel);
    defer alloc.free(cancelled);
    try std.testing.expectEqualStrings("{\"outcome\":\"cancelled\"}", cancelled);

    const skipped = try encodeResult(alloc, "{}", "(ask_user_question is only available in the interactive shell; ask the user freeform instead)");
    defer alloc.free(skipped);
    try std.testing.expectEqualStrings(
        "{\"outcome\":\"skipped\",\"reason\":\"AskQuestion is only available in the interactive shell\"}",
        skipped,
    );
}
