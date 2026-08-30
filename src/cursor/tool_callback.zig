const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const ask_user_question = @import("../tools/agent/ask_user_question.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const core_types = @import("../core/shared/types.zig");
const json_util = @import("json_util.zig");
const host_tools = @import("host_tools.zig");

const Allocator = std.mem.Allocator;
const WorkerRuntime = worker_runtime.WorkerRuntime;

const call_path = "/sdk.v1.SdkCustomToolCallbackService/CallCustomTool";
const max_header_bytes = 64 * 1024;
const max_body_bytes = 1024 * 1024;

pub const Endpoint = struct {
    url: []const u8,
    token: []const u8,
};

pub const Bind = struct {
    worker: ?*WorkerRuntime = null,
    interactive: bool = false,
    request: ?tool_dispatch.AskQuestionBatchFn = null,
    request_ctx: ?*anyopaque = null,
};

var mutex: std.Io.Mutex = .init;
var started = false;
var stop_flag = std.atomic.Value(bool).init(false);
var bind_state: Bind = .{};
var listener_mem: ?std.Io.net.Server = null;
var thread_mem: ?std.Thread = null;
var url_owned: ?[]u8 = null;
var token_owned: ?[]u8 = null;
var alloc_ref: Allocator = std.heap.c_allocator;

pub fn bindHost(bind: Bind) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    bind_state = bind;
}

fn snapshotBind() Bind {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return bind_state;
}

pub fn endpoint() ?Endpoint {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const url = url_owned orelse return null;
    const token = token_owned orelse return null;
    return .{ .url = url, .token = token };
}

pub fn ensure(alloc: Allocator) !Endpoint {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (started) {
        return .{
            .url = url_owned orelse return error.ToolCallbackUnavailable,
            .token = token_owned orelse return error.ToolCallbackUnavailable,
        };
    }
    return startLocked(alloc);
}

pub fn start(alloc: Allocator) !Endpoint {
    stop();
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return startLocked(alloc);
}

fn startLocked(alloc: Allocator) !Endpoint {
    alloc_ref = alloc;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io_mod.getIo(), .{ .reuse_address = true });
    errdefer listener.deinit(io_mod.getIo());

    const port = listener.socket.address.getPort();
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    errdefer alloc.free(url);
    const token = try randomToken(alloc);
    errdefer alloc.free(token);

    stop_flag.store(false, .seq_cst);
    listener_mem = listener;
    url_owned = url;
    token_owned = token;
    errdefer {
        listener_mem = null;
        url_owned = null;
        token_owned = null;
    }
    thread_mem = try std.Thread.spawn(.{}, serveLoop, .{});
    started = true;
    return .{ .url = url, .token = token };
}

pub fn stop() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    if (!started) {
        mutex.unlock(zio);
        return;
    }
    stop_flag.store(true, .seq_cst);
    var port: ?u16 = null;
    if (listener_mem) |*listener| {
        const poke = std.Io.net.Stream{ .socket = listener.socket };
        poke.shutdown(io_mod.getIo(), .both) catch {};
        port = listener.socket.address.getPort();
    }
    const thread = thread_mem;
    thread_mem = null;
    mutex.unlock(zio);
    if (port) |value| wakeAccept(value);
    if (thread) |joinable| joinable.join();

    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    if (listener_mem) |*listener| {
        listener.deinit(io_mod.getIo());
        listener_mem = null;
    }
    if (url_owned) |url| alloc_ref.free(url);
    if (token_owned) |token| alloc_ref.free(token);
    url_owned = null;
    token_owned = null;
    started = false;
    bind_state = .{};
}

fn wakeAccept(port: u16) void {
    var wake_backend: std.Io.Threaded = .init_single_threaded;
    const zio = wake_backend.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var stream = address.connect(zio, .{ .mode = .stream }) catch return;
    stream.close(zio);
}

fn randomToken(alloc: Allocator) ![]u8 {
    var entropy: [24]u8 = undefined;
    try io_mod.getIo().randomSecure(&entropy);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(entropy.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &entropy);
    return encoded;
}

fn serveLoop() void {
    while (!stop_flag.load(.seq_cst)) {
        const listener = if (listener_mem) |*server| server else break;
        var stream = listener.accept(io_mod.getIo()) catch {
            if (stop_flag.load(.seq_cst)) break;
            continue;
        };
        if (stop_flag.load(.seq_cst)) {
            stream.close(io_mod.getIo());
            break;
        }
        handleConnection(stream);
    }
}

fn handleConnection(stream: std.Io.net.Stream) void {
    defer stream.close(io_mod.getIo());
    const alloc = std.heap.c_allocator;
    handleConnectionAlloc(alloc, stream) catch {
        writeJson(stream, 500, "{\"code\":\"internal\",\"message\":\"callback failed\"}") catch {};
    };
}

fn handleConnectionAlloc(alloc: Allocator, stream: std.Io.net.Stream) !void {
    var request = readHttpRequest(alloc, stream) catch |err| switch (err) {
        error.Unauthenticated => {
            try writeJson(stream, 401, "{\"code\":\"unauthenticated\"}");
            return;
        },
        error.NotFound => {
            try writeJson(stream, 404, "{\"code\":\"not_found\"}");
            return;
        },
        else => return err,
    };
    defer request.deinit(alloc);

    const result = executeCall(alloc, request.body) catch |err| {
        const message = try std.fmt.allocPrint(
            alloc,
            "{{\"value\":\"custom tool failed: {s}\"}}",
            .{@errorName(err)},
        );
        defer alloc.free(message);
        const envelope = try std.fmt.allocPrint(alloc, "{{\"result\":{s}}}", .{message});
        defer alloc.free(envelope);
        try writeJson(stream, 200, envelope);
        return;
    };
    defer alloc.free(result);
    const envelope = try std.fmt.allocPrint(alloc, "{{\"result\":{s}}}", .{result});
    defer alloc.free(envelope);
    try writeJson(stream, 200, envelope);
}

const HttpRequest = struct {
    body: []u8,

    fn deinit(self: *HttpRequest, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

fn readHttpRequest(alloc: Allocator, stream: std.Io.net.Stream) !HttpRequest {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var header_buf: [max_header_bytes]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < header_buf.len) {
        header_buf[header_len] = reader.interface.takeByte() catch return error.InvalidRequest;
        header_len += 1;
        if (std.mem.endsWith(u8, header_buf[0..header_len], "\r\n\r\n")) break;
    }
    if (!std.mem.endsWith(u8, header_buf[0..header_len], "\r\n\r\n")) return error.InvalidRequest;

    const line_end = std.mem.find(u8, header_buf[0..header_len], "\r\n") orelse return error.InvalidRequest;
    const request_line = header_buf[0..line_end];
    const method_end = std.mem.findScalar(u8, request_line, ' ') orelse return error.InvalidRequest;
    const target_start = method_end + 1;
    const target_end = std.mem.findScalarPos(u8, request_line, target_start, ' ') orelse return error.InvalidRequest;
    const method = request_line[0..method_end];
    const target = request_line[target_start..target_end];
    if (!std.mem.eql(u8, method, "POST")) return error.NotFound;
    if (!isCallPath(target)) return error.NotFound;

    const headers = header_buf[line_end + 2 .. header_len];
    const auth = headerValue(headers, "authorization") orelse return error.Unauthenticated;
    const expected = expectedAuthHeader();
    defer if (expected.owned) std.heap.c_allocator.free(expected.value);
    if (!std.mem.eql(u8, auth, expected.value)) return error.Unauthenticated;

    const transfer = headerValue(headers, "transfer-encoding");
    const chunked = if (transfer) |value| std.ascii.eqlIgnoreCase(value, "chunked") else false;
    const content_type = headerValue(headers, "content-type") orelse "application/json";

    const raw_body = if (chunked)
        try readChunkedBody(alloc, &reader.interface)
    else blk: {
        const length_text = headerValue(headers, "content-length") orelse "0";
        const length = std.fmt.parseInt(usize, length_text, 10) catch return error.InvalidRequest;
        if (length > max_body_bytes) return error.InvalidRequest;
        const body = try alloc.alloc(u8, length);
        errdefer alloc.free(body);
        if (length > 0) try reader.interface.readSliceAll(body);
        break :blk body;
    };
    defer alloc.free(raw_body);
    const payload = unwrapConnectJson(raw_body, content_type);
    return .{ .body = try alloc.dupe(u8, payload) };
}

fn expectedAuthHeader() struct { value: []u8, owned: bool } {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const token = token_owned orelse return .{ .value = &.{}, .owned = false };
    const value = std.fmt.allocPrint(std.heap.c_allocator, "Bearer {s}", .{token}) catch
        return .{ .value = &.{}, .owned = false };
    return .{ .value = value, .owned = true };
}

fn isCallPath(target: []const u8) bool {
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    return std.mem.eql(u8, path, call_path) or std.mem.endsWith(u8, path, "/CallCustomTool");
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn unwrapConnectJson(body: []const u8, content_type: []const u8) []const u8 {
    if (std.ascii.indexOfIgnoreCase(content_type, "connect+json") == null) return body;
    if (body.len < 5) return body;
    const length = std.mem.readInt(u32, body[1..5], .big);
    if (body.len < 5 + length) return body;
    return body[5 .. 5 + length];
}

fn readChunkedBody(alloc: Allocator, reader: *std.Io.Reader) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    while (true) {
        const size_line = try readLineAlloc(alloc, reader);
        defer alloc.free(size_line);
        const size_text = if (std.mem.indexOfScalar(u8, size_line, ';')) |semi|
            std.mem.trim(u8, size_line[0..semi], " \t")
        else
            std.mem.trim(u8, size_line, " \t");
        const size = std.fmt.parseInt(usize, size_text, 16) catch return error.InvalidRequest;
        if (size == 0) {
            while (true) {
                const trailer = try readLineAlloc(alloc, reader);
                defer alloc.free(trailer);
                if (trailer.len == 0) break;
            }
            break;
        }
        if (body.items.len + size > max_body_bytes) return error.InvalidRequest;
        const offset = body.items.len;
        try body.resize(alloc, offset + size);
        try reader.readSliceAll(body.items[offset..]);
        var crlf: [2]u8 = undefined;
        try reader.readSliceAll(&crlf);
        if (!std.mem.eql(u8, &crlf, "\r\n")) return error.InvalidRequest;
    }
    return body.toOwnedSlice(alloc);
}

fn readLineAlloc(alloc: Allocator, reader: *std.Io.Reader) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    while (true) {
        const byte = reader.takeByte() catch return error.InvalidRequest;
        try line.append(alloc, byte);
        if (line.items.len >= 2 and
            line.items[line.items.len - 2] == '\r' and
            line.items[line.items.len - 1] == '\n')
        {
            _ = line.pop();
            _ = line.pop();
            return line.toOwnedSlice(alloc);
        }
        if (line.items.len > 4096) return error.InvalidRequest;
    }
}

fn writeJson(stream: std.Io.net.Stream, status: u16, body: []const u8) !void {
    const reason: []const u8 = switch (status) {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        else => "Internal Server Error",
    };
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nConnect-Protocol-Version: 1\r\n\r\n",
        .{ status, reason, body.len },
    );
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

fn executeCall(alloc: Allocator, request_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch
        return host_tools.wrapCustomToolResult(alloc, "(invalid CallCustomTool request)");
    defer parsed.deinit();
    const root = json_util.objectGet(parsed.value, "request") orelse parsed.value;
    const name = json_util.stringGet(root, "toolName") orelse
        json_util.stringGet(root, "tool_name") orelse
        "unknown";
    const args_value = json_util.objectGet(root, "args") orelse
        json_util.objectGet(root, "params") orelse
        json_util.objectGet(root, "arguments");
    const args_json = if (args_value) |value|
        try json_util.stringifyAlloc(alloc, value)
    else
        try alloc.dupe(u8, "{}");
    defer alloc.free(args_json);
    return executeNamedTool(alloc, name, args_json);
}

fn executeNamedTool(alloc: Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    if (host_tools.isQuestionTool(name)) return executeQuestion(alloc, args_json);

    const message = try std.fmt.allocPrint(
        alloc,
        "cc host callback does not implement {s}. Cursor built-ins (Read, Write, Shell, Grep, Glob, WebSearch, WebFetch, Task) stay in the SDK Bridge.",
        .{name},
    );
    defer alloc.free(message);
    return host_tools.wrapCustomToolResult(alloc, message);
}

fn executeQuestion(alloc: Allocator, args_json: []const u8) ![]u8 {
    const normalized = try host_tools.normalizeQuestionArgs(alloc, args_json);
    defer alloc.free(normalized);
    const bind = snapshotBind();
    const requester: ask_user_question.Requester = if (bind.request) |request_fn|
        .{
            .ctx = bind.request_ctx,
            .response_alloc = alloc,
            .request = request_fn,
        }
    else if (bind.interactive and bind.worker != null)
        .{
            .ctx = bind.worker,
            .response_alloc = alloc,
            .request = requestViaWorker,
        }
    else
        return host_tools.wrapCustomToolResult(alloc, ask_user_question.not_available_sentinel);

    const body = try ask_user_question.executeWithRequester(alloc, normalized, requester);
    defer alloc.free(body);
    return host_tools.wrapCustomToolResult(alloc, body);
}

fn requestViaWorker(
    raw: ?*anyopaque,
    response_alloc: Allocator,
    entries: []const core_types.QuestionBatchEntry,
) anyerror!?[][]u8 {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw.?));
    const worker_alloc = std.heap.c_allocator;
    const worker_answers = try worker.requestQuestionBatchAnswerBlocking(worker_alloc, entries);
    defer freeAnswers(worker_alloc, worker_answers);
    const answers = worker_answers orelse return null;
    return try dupeAnswers(response_alloc, answers);
}

fn freeAnswers(alloc: Allocator, answers: ?[][]u8) void {
    const items = answers orelse return;
    for (items) |answer| alloc.free(answer);
    alloc.free(items);
}

fn dupeAnswers(alloc: Allocator, answers: []const []const u8) ![][]u8 {
    const copy = try alloc.alloc([]u8, answers.len);
    errdefer alloc.free(copy);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |answer| alloc.free(answer);
    }
    while (filled < answers.len) : (filled += 1) {
        copy[filled] = try alloc.dupe(u8, answers[filled]);
    }
    return copy;
}

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn postCall(
    alloc: Allocator,
    url: []const u8,
    token: []const u8,
    body: []const u8,
    chunked: bool,
) !HttpResponse {
    const target = try std.fmt.allocPrint(alloc, "{s}{s}", .{ url, call_path });
    defer alloc.free(target);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth);

    if (chunked) return postChunked(alloc, url, token, body);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const body_buffer = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(body_buffer);
    var response_writer = std.Io.Writer.fixed(body_buffer);
    const result = try client.fetch(.{
        .location = .{ .url = target },
        .method = .POST,
        .payload = body,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "Connect-Protocol-Version", .value = "1" },
        },
        .response_writer = &response_writer,
        .redirect_behavior = .unhandled,
    });
    return .{
        .status = @intFromEnum(result.status),
        .body = try alloc.dupe(u8, response_writer.buffered()),
    };
}

fn postChunked(
    alloc: Allocator,
    url: []const u8,
    token: []const u8,
    body: []const u8,
) !HttpResponse {
    const uri = try std.Uri.parse(url);
    const port = uri.port orelse 80;
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var stream = try address.connect(io_mod.getIo(), .{ .mode = .stream });
    defer stream.close(io_mod.getIo());

    var write_buf: [2048]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &write_buf);
    try writer.interface.print(
        "POST {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnect-Protocol-Version: 1\r\nConnection: close\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n",
        .{ call_path, port, token, body.len, body },
    );
    try writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &read_buf);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    while (true) {
        var tmp: [512]u8 = undefined;
        const n = reader.interface.readSliceShort(&tmp) catch break;
        if (n == 0) break;
        try raw.appendSlice(alloc, tmp[0..n]);
        if (raw.items.len > max_body_bytes) break;
    }

    const header_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.InvalidRequest;
    const status_line_end = std.mem.indexOf(u8, raw.items, "\r\n") orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, raw.items[0..status_line_end], ' ');
    _ = parts.next();
    const status_text = parts.next() orelse return error.InvalidRequest;
    const status = try std.fmt.parseInt(u16, status_text, 10);
    return .{
        .status = status,
        .body = try alloc.dupe(u8, raw.items[header_end + 4 ..]),
    };
}

fn firstLabelRequester(
    _: ?*anyopaque,
    alloc: Allocator,
    entries: []const core_types.QuestionBatchEntry,
) anyerror!?[][]u8 {
    const answers = try alloc.alloc([]u8, entries.len);
    errdefer alloc.free(answers);
    var filled: usize = 0;
    errdefer {
        for (answers[0..filled]) |answer| alloc.free(answer);
    }
    while (filled < entries.len) : (filled += 1) {
        answers[filled] = try alloc.dupe(u8, entries[filled].options[0].label);
    }
    return answers;
}

test "CallCustomTool AskQuestion returns answers object" {
    const alloc = std.testing.allocator;
    const ep = try start(alloc);
    defer stop();
    bindHost(.{ .interactive = true, .request = firstLabelRequester });
    defer bindHost(.{});

    const payload =
        \\{"toolName":"AskQuestion","args":{"question":"Ship it?","options":["Yes","No"]}}
    ;
    const response = try postCall(alloc, ep.url, ep.token, payload, false);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"answers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"Yes\"") != null);
}

test "CallCustomTool rejects a missing bearer token" {
    const alloc = std.testing.allocator;
    const ep = try start(alloc);
    defer stop();

    const response = try postCall(alloc, ep.url, "wrong-token", "{}", false);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 401), response.status);
}

test "CallCustomTool accepts chunked AskQuestion bodies" {
    const alloc = std.testing.allocator;
    const ep = try start(alloc);
    defer stop();
    bindHost(.{ .interactive = true, .request = firstLabelRequester });
    defer bindHost(.{});

    const payload =
        \\{"tool_name":"ask_user_question","args":{"questions":[{"question":"Go?","options":[{"label":"Yes"},{"label":"No"}]}]}}
    ;
    const response = try postCall(alloc, ep.url, ep.token, payload, true);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"answers\"") != null);
}

test "CallCustomTool headless AskQuestion returns the interactive sentinel" {
    const alloc = std.testing.allocator;
    const ep = try start(alloc);
    defer stop();
    bindHost(.{});

    const payload =
        \\{"toolName":"AskQuestion","args":{"questions":[{"question":"Go?","options":[{"label":"Yes"},{"label":"No"}]}]}}
    ;
    const response = try postCall(alloc, ep.url, ep.token, payload, false);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "interactive shell") != null);
}

test "unknown custom tool stays an object result" {
    const alloc = std.testing.allocator;
    const ep = try start(alloc);
    defer stop();
    const response = try postCall(alloc, ep.url, ep.token, "{\"toolName\":\"memory\"}", false);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "memory") != null);
}
