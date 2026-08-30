const std = @import("std");
const builtin = @import("builtin");

/// POSIX-shaped `File.Permissions` that also satisfies Windows `chmod`
/// (`toAttributes`). Declared as `std_options_FilePermissions` from root so
/// Zig 0.16's Windows `enum(DWORD)` (no `fromMode`/`toMode`) is replaced.
pub const Permissions = enum(u32) {
    default_file = 0o666,
    default_dir = 0o777,
    _,

    pub const has_executable_bit = builtin.os.tag != .wasi;
    pub const executable_file: @This() = .default_dir;

    pub fn toMode(self: @This()) std.posix.mode_t {
        return @intCast(@intFromEnum(self));
    }

    pub fn fromMode(mode: std.posix.mode_t) @This() {
        return @enumFromInt(@as(u32, @intCast(mode)));
    }

    pub fn toAttributes(self: @This()) std.os.windows.FILE.ATTRIBUTE {
        return .{
            .READONLY = self.readOnly(),
            .NORMAL = !self.readOnly(),
        };
    }

    pub fn readOnly(self: @This()) bool {
        return @intFromEnum(self) & 0o222 == 0;
    }

    pub fn setReadOnly(self: @This(), read_only: bool) @This() {
        const mode = @intFromEnum(self);
        const o222: u32 = 0o222;
        return @enumFromInt(if (read_only) mode & ~o222 else mode | o222);
    }
};
