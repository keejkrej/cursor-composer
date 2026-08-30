const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const ConnectError = error{
    ConnectUnaryFailed,
    ConnectStreamFailed,
    ConnectEndStreamError,
    ConnectTruncatedFrame,
    Unauthenticated,
};

pub fn encodeEnvelope(alloc: Allocator, payload: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, 5 + payload.len);
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], @intCast(payload.len), .big);
    @memcpy(out[5..], payload);
    return out;
}

pub fn decodeFrame(bytes: []const u8) !struct { flags: u8, payload: []const u8, rest: []const u8 } {
    if (bytes.len < 5) return error.ConnectTruncatedFrame;
    const flags = bytes[0];
    const length = std.mem.readInt(u32, bytes[1..5], .big);
    if (bytes.len < 5 + length) return error.ConnectTruncatedFrame;
    return .{
        .flags = flags,
        .payload = bytes[5 .. 5 + length],
        .rest = bytes[5 + length ..],
    };
}

pub fn isEndStream(flags: u8) bool {
    return flags & 0x02 != 0;
}

var last_error_buf: [256]u8 = undefined;
var last_error_len: usize = 0;

pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

fn rememberError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch blk: {
        break :blk last_error_buf[0..];
    };
    last_error_len = written.len;
}

pub const Transport = struct {
    alloc: Allocator,
    base_url: []const u8,
    token: []const u8,

    pub fn unaryJson(
        self: Transport,
        service: []const u8,
        method: []const u8,
        request_json: []const u8,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/sdk.v1.{s}/{s}",
            .{ self.base_url, service, method },
        );
        defer self.alloc.free(url);

        const auth = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.token});
        defer self.alloc.free(auth);

        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const body_buffer = try self.alloc.alloc(u8, 8 * 1024 * 1024);
        defer self.alloc.free(body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = request_json,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &.{
                .{ .name = "Connect-Protocol-Version", .value = "1" },
                .{ .name = "accept", .value = "application/json" },
            },
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            rememberError("unary {s} {s} fetch={s}", .{ service, method, @errorName(err) });
            return error.ConnectUnaryFailed;
        };

        const body = try self.alloc.dupe(u8, response_writer.buffered());
        if (result.status == .unauthorized) {
            self.alloc.free(body);
            rememberError("unary {s} {s} status=401", .{ service, method });
            return error.Unauthenticated;
        }
        if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) > 299) {
            rememberError("unary {s} {s} status={d} body={s}", .{
                service,
                method,
                @intFromEnum(result.status),
                body[0..@min(body.len, 180)],
            });
            self.alloc.free(body);
            return error.ConnectUnaryFailed;
        }
        return body;
    }

    pub fn streamJson(
        self: Transport,
        service: []const u8,
        method: []const u8,
        request_json: []const u8,
        on_message: *const fn (ctx: *anyopaque, payload: []const u8) anyerror!void,
        ctx: *anyopaque,
    ) !void {
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/sdk.v1.{s}/{s}",
            .{ self.base_url, service, method },
        );
        defer self.alloc.free(url);
        const uri = try std.Uri.parse(url);

        const auth = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.token});
        defer self.alloc.free(auth);

        const framed = try encodeEnvelope(self.alloc, request_json);
        defer self.alloc.free(framed);

        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();

        var request = try client.request(.POST, uri, .{
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = .{ .override = "application/connect+json" },
            },
            .extra_headers = &.{
                .{ .name = "Connect-Protocol-Version", .value = "1" },
            },
        });
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = framed.len };
        var send_buffer: [8192]u8 = undefined;
        var body_writer = try request.sendBodyUnflushed(&send_buffer);
        try body_writer.writer.writeAll(framed);
        try body_writer.end();
        if (request.connection) |connection| try connection.flush();

        var response = try request.receiveHead(&.{});
        if (response.head.status == .unauthorized) return error.Unauthenticated;
        if (response.head.status != .ok) return error.ConnectStreamFailed;

        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        while (true) {
            var header: [5]u8 = undefined;
            readExact(reader, &header) catch |err| switch (err) {
                error.EndOfStream => return error.ConnectTruncatedFrame,
                else => return err,
            };
            const flags = header[0];
            const length = std.mem.readInt(u32, header[1..5], .big);
            const payload = try self.alloc.alloc(u8, length);
            defer self.alloc.free(payload);
            if (length > 0) {
                readExact(reader, payload) catch return error.ConnectTruncatedFrame;
            }
            if (isEndStream(flags)) {
                if (payload.len == 0) return;
                const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch return error.ConnectEndStreamError;
                defer parsed.deinit();
                if (parsed.value == .object and parsed.value.object.get("error") != null) {
                    return error.ConnectEndStreamError;
                }
                return;
            }
            try on_message(ctx, payload);
        }
    }
};

fn readExact(reader: anytype, dest: []u8) !void {
    var filled: usize = 0;
    while (filled < dest.len) {
        const n = try reader.readSliceShort(dest[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

test "connect envelope round-trip" {
    const framed = try encodeEnvelope(std.testing.allocator, "{\"ok\":true}");
    defer std.testing.allocator.free(framed);
    const decoded = try decodeFrame(framed);
    try std.testing.expectEqual(@as(u8, 0), decoded.flags);
    try std.testing.expectEqualStrings("{\"ok\":true}", decoded.payload);
    try std.testing.expectEqual(@as(usize, 0), decoded.rest.len);
    try std.testing.expect(!isEndStream(0));
    try std.testing.expect(isEndStream(0x02));
}
