const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;
pub const has_termios = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding, .other => false,
    else => true,
};
pub const has_posix_signals = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding, .other => false,
    else => true,
};

pub fn stdinHandle() std.posix.fd_t {
    return std.Io.File.stdin().handle;
}

pub fn stdoutHandle() std.posix.fd_t {
    return std.Io.File.stdout().handle;
}

pub fn stderrHandle() std.posix.fd_t {
    return std.Io.File.stderr().handle;
}

pub fn isTty(handle: std.posix.fd_t) bool {
    if (comptime is_windows) {
        var mode: std.os.windows.DWORD = undefined;
        return kernel32.GetConsoleMode(handle, &mode).toBool();
    }
    return std.c.isatty(handle) != 0;
}

pub const pollfd = if (is_windows)
    extern struct {
        fd: std.os.windows.HANDLE,
        events: i16,
        revents: i16,
    }
else
    std.posix.pollfd;

pub const POLL = if (is_windows) struct {
    pub const ERR: i16 = 0x0001;
    pub const HUP: i16 = 0x0002;
    pub const NVAL: i16 = 0x0004;
    pub const OUT: i16 = 0x0010;
    pub const IN: i16 = 0x0100;
} else std.posix.POLL;

pub const PollError = if (is_windows)
    error{SystemResources} || std.posix.UnexpectedError
else
    std.posix.PollError;

pub fn poll(fds: []pollfd, timeout_ms: i32) PollError!usize {
    if (comptime !is_windows) {
        return std.posix.poll(fds, timeout_ms);
    }
    if (fds.len == 0) return 0;
    if (fds.len == 1 and isConsoleHandle(fds[0].fd)) {
        return pollConsole(fds[0..1], timeout_ms);
    }
    return pollSockets(fds, timeout_ms);
}

pub fn read(handle: std.posix.fd_t, buf: []u8) !usize {
    if (comptime !is_windows) {
        return std.posix.read(handle, buf);
    }
    if (buf.len == 0) return 0;
    var read_count: std.os.windows.DWORD = 0;
    const ok = kernel32.ReadFile(
        handle,
        buf.ptr,
        @intCast(@min(buf.len, std.math.maxInt(std.os.windows.DWORD))),
        &read_count,
        null,
    );
    if (!ok.toBool()) {
        const err = std.os.windows.GetLastError();
        return switch (err) {
            .BROKEN_PIPE, .NO_DATA => 0,
            else => error.Unexpected,
        };
    }
    return read_count;
}

/// Windows UTF-8 console code page. OEM pages such as CP437 decode the TUI's
/// UTF-8 banner (`𝒇x`, `·`, `⚠`) as mojibake (`≡¥Æçx`, `┬┐`, `ΓùÅ`).
const utf8_code_page: u32 = 65001;

const CodePageSnapshot = struct {
    input: u32 = 0,
    output: u32 = 0,

    fn isAttached(self: CodePageSnapshot) bool {
        return self.input != 0 or self.output != 0;
    }
};

const CodePageSession = struct {
    original: CodePageSnapshot = .{},
    active: bool = false,

    fn enable(self: *CodePageSession, current: CodePageSnapshot) ?CodePageSnapshot {
        if (self.active or !current.isAttached()) return null;
        self.original = current;
        self.active = true;
        return .{ .input = utf8_code_page, .output = utf8_code_page };
    }

    fn takeRestore(self: *CodePageSession) ?CodePageSnapshot {
        if (!self.active) return null;
        const original = self.original;
        self.* = .{};
        return original;
    }
};

var process_code_pages = CodePageSession{};

/// Interpret console bytes as UTF-8 for the rest of this process. No-op when
/// stdout is not a Windows console. Safe to call more than once.
pub fn enableUtf8Console() void {
    if (comptime !is_windows) return;
    applyCodePages(process_code_pages.enable(readCodePages()) orelse return);
}

/// Restore the console code pages captured by `enableUtf8Console`. Safe to call
/// when UTF-8 was never enabled or after a previous restore.
pub fn restoreUtf8Console() void {
    if (comptime !is_windows) return;
    applyCodePages(process_code_pages.takeRestore() orelse return);
}

pub const ConsoleState = struct {
    in_handle: std.posix.fd_t,
    out_handle: std.posix.fd_t,
    original_in: std.os.windows.DWORD = 0,
    original_out: std.os.windows.DWORD = 0,
    code_pages: CodePageSession = .{},
    active: bool = false,
};

pub fn captureConsole(in_handle: std.posix.fd_t) !ConsoleState {
    var state = ConsoleState{
        .in_handle = in_handle,
        .out_handle = stdoutHandle(),
    };
    if (!kernel32.GetConsoleMode(state.in_handle, &state.original_in).toBool()) {
        return error.NotATerminal;
    }
    if (!kernel32.GetConsoleMode(state.out_handle, &state.original_out).toBool()) {
        return error.NotATerminal;
    }
    return state;
}

pub fn enableRawConsole(state: *ConsoleState) !void {
    const enable_vt_input: std.os.windows.DWORD = 0x0200;
    const enable_window_input: std.os.windows.DWORD = 0x0008;
    const enable_processed_input: std.os.windows.DWORD = 0x0001;
    const enable_line_input: std.os.windows.DWORD = 0x0002;
    const enable_echo_input: std.os.windows.DWORD = 0x0004;
    const enable_processed_output: std.os.windows.DWORD = 0x0001;
    const enable_wrap: std.os.windows.DWORD = 0x0002;
    const enable_vt_output: std.os.windows.DWORD = 0x0004;
    const disable_newline_auto_return: std.os.windows.DWORD = 0x0008;

    var in_mode = state.original_in;
    in_mode &= ~(enable_line_input | enable_echo_input | enable_processed_input);
    in_mode |= enable_vt_input | enable_window_input;
    if (!kernel32.SetConsoleMode(state.in_handle, in_mode).toBool()) {
        return error.NotATerminal;
    }

    var out_mode = state.original_out;
    out_mode |= enable_processed_output | enable_vt_output | disable_newline_auto_return;
    out_mode &= ~enable_wrap;
    if (!kernel32.SetConsoleMode(state.out_handle, out_mode).toBool()) {
        _ = kernel32.SetConsoleMode(state.in_handle, state.original_in);
        return error.NotATerminal;
    }
    if (state.code_pages.enable(readCodePages())) |pages| applyCodePages(pages);
    state.active = true;
}

pub fn restoreConsole(state: *ConsoleState) void {
    if (!state.active) return;
    _ = kernel32.SetConsoleMode(state.in_handle, state.original_in);
    _ = kernel32.SetConsoleMode(state.out_handle, state.original_out);
    if (state.code_pages.takeRestore()) |pages| applyCodePages(pages);
    state.active = false;
}

pub fn queryConsoleSize() !struct { rows: u16, cols: u16 } {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (!kernel32.GetConsoleScreenBufferInfo(stdoutHandle(), &info).toBool()) {
        return error.UnableToReadTerminalSize;
    }
    const cols_i = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
    const rows_i = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
    if (cols_i <= 0 or rows_i <= 0) return error.UnableToReadTerminalSize;
    return .{
        .rows = @intCast(rows_i),
        .cols = @intCast(cols_i),
    };
}

pub fn handlePathAlloc(alloc: std.mem.Allocator, handle: std.posix.fd_t) ![]u8 {
    if (comptime !is_windows) return error.HandlePathUnavailable;

    var wbuf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const flags: std.os.windows.DWORD = 0; // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
    const n = kernel32.GetFinalPathNameByHandleW(
        handle,
        &wbuf,
        wbuf.len,
        flags,
    );
    if (n == 0 or n >= wbuf.len) return error.HandlePathUnavailable;

    var utf8: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(utf8[0..], wbuf[0..n]);
    const path = utf8[0..len];
    if (std.mem.startsWith(u8, path, "\\\\?\\UNC\\")) {
        return std.fmt.allocPrint(alloc, "\\\\{s}", .{path["\\\\?\\UNC\\".len..]});
    }
    if (std.mem.startsWith(u8, path, "\\\\?\\")) {
        return alloc.dupe(u8, path["\\\\?\\".len..]);
    }
    return alloc.dupe(u8, path);
}

pub fn msgNoSignal() u32 {
    if (comptime is_windows) return 0;
    return @intCast(std.posix.MSG.NOSIGNAL);
}

pub fn currentPid() u64 {
    if (comptime is_windows) {
        return std.os.windows.GetCurrentProcessId();
    }
    return @intCast(std.c.getpid());
}

pub fn parsePidText(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 10) catch null;
}

pub fn formatPid(pid: anytype) u64 {
    const T = @TypeOf(pid);
    return switch (@typeInfo(T)) {
        .optional => if (pid) |value| formatPid(value) else 0,
        .pointer => windowsProcessId(pid),
        .int, .comptime_int => @intCast(pid),
        else => @compileError("unsupported pid type"),
    };
}

pub const SetSockOptError = if (is_windows)
    error{Unexpected}
else
    std.posix.SetSockOptError;

pub fn setsockopt(
    fd: std.posix.socket_t,
    level: i32,
    optname: u32,
    opt: []const u8,
) SetSockOptError!void {
    if (comptime !is_windows) {
        return std.posix.setsockopt(fd, level, optname, opt);
    }
    const rc = ws2_32.setsockopt(
        @intFromPtr(fd),
        level,
        @intCast(optname),
        opt.ptr,
        @intCast(opt.len),
    );
    if (rc == 0) return;
    return error.Unexpected;
}

pub fn cSetsockopt(
    fd: std.posix.socket_t,
    level: i32,
    optname: u32,
    opt: *const anyopaque,
    optlen: u32,
) c_int {
    if (comptime !is_windows) {
        return std.c.setsockopt(fd, level, optname, opt, optlen);
    }
    return ws2_32.setsockopt(
        @intFromPtr(fd),
        level,
        @intCast(optname),
        @ptrCast(opt),
        @intCast(optlen),
    );
}

const kernel32 = struct {
    pub extern "kernel32" fn GetConsoleMode(
        handle: std.os.windows.HANDLE,
        mode: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    pub extern "kernel32" fn SetConsoleMode(
        handle: std.os.windows.HANDLE,
        mode: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    pub extern "kernel32" fn GetConsoleScreenBufferInfo(
        handle: std.os.windows.HANDLE,
        info: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) std.os.windows.BOOL;

    pub extern "kernel32" fn ReadFile(
        handle: std.os.windows.HANDLE,
        buffer: [*]u8,
        n: std.os.windows.DWORD,
        read: *std.os.windows.DWORD,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;

    pub extern "kernel32" fn WaitForSingleObject(
        handle: std.os.windows.HANDLE,
        ms: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.DWORD;

    pub extern "kernel32" fn GetFinalPathNameByHandleW(
        handle: std.os.windows.HANDLE,
        buf: [*]u16,
        len: std.os.windows.DWORD,
        flags: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.DWORD;

    pub extern "kernel32" fn GetProcessId(
        handle: std.os.windows.HANDLE,
    ) callconv(.winapi) std.os.windows.DWORD;

    pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    pub extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) std.os.windows.BOOL;
};

fn readCodePages() CodePageSnapshot {
    if (comptime !is_windows) return .{};
    return .{
        .input = kernel32.GetConsoleCP(),
        .output = kernel32.GetConsoleOutputCP(),
    };
}

fn applyCodePages(pages: CodePageSnapshot) void {
    if (comptime !is_windows) return;
    _ = kernel32.SetConsoleCP(pages.input);
    _ = kernel32.SetConsoleOutputCP(pages.output);
}

const ws2_32 = struct {
    pub extern "ws2_32" fn WSAPoll(
        fds: [*]pollfd,
        count: std.os.windows.ULONG,
        timeout: c_int,
    ) callconv(.winapi) c_int;

    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

    pub extern "ws2_32" fn setsockopt(
        s: usize,
        level: c_int,
        optname: c_int,
        optval: [*]const u8,
        optlen: c_int,
    ) callconv(.winapi) c_int;
};

const COORD = std.os.windows.COORD;
const SMALL_RECT = extern struct {
    Left: std.os.windows.SHORT,
    Top: std.os.windows.SHORT,
    Right: std.os.windows.SHORT,
    Bottom: std.os.windows.SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: std.os.windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

fn windowsProcessId(handle: std.os.windows.HANDLE) u64 {
    if (comptime !is_windows) return @intFromPtr(handle);
    const current = std.os.windows.GetCurrentProcess();
    if (handle == current) return std.os.windows.GetCurrentProcessId();
    const pid = kernel32.GetProcessId(handle);
    if (pid == 0) return @intFromPtr(handle);
    return pid;
}

fn isConsoleHandle(handle: std.posix.fd_t) bool {
    var mode: std.os.windows.DWORD = undefined;
    return kernel32.GetConsoleMode(handle, &mode).toBool();
}

fn pollConsole(fds: []pollfd, timeout_ms: i32) PollError!usize {
    const wait_ms: std.os.windows.DWORD = if (timeout_ms < 0)
        0xffffffff
    else
        @intCast(timeout_ms);
    const rc = kernel32.WaitForSingleObject(fds[0].fd, wait_ms);
    fds[0].revents = 0;
    return switch (rc) {
        0 => { // WAIT_OBJECT_0
            fds[0].revents = POLL.IN;
            return 1;
        },
        0x00000102 => 0, // WAIT_TIMEOUT
        else => error.Unexpected,
    };
}

fn pollSockets(fds: []pollfd, timeout_ms: i32) PollError!usize {
    const rc = ws2_32.WSAPoll(fds.ptr, @intCast(fds.len), timeout_ms);
    if (rc >= 0) return @intCast(rc);
    return error.Unexpected;
}

test "utf8 console code page is Windows CP_UTF8" {
    try std.testing.expectEqual(@as(u32, 65001), utf8_code_page);
}

test "code page session switches an OEM console to UTF-8 and restores it" {
    var session = CodePageSession{};
    const oem = CodePageSnapshot{ .input = 437, .output = 437 };

    const enabled = session.enable(oem) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(utf8_code_page, enabled.input);
    try std.testing.expectEqual(utf8_code_page, enabled.output);
    try std.testing.expect(session.active);
    try std.testing.expectEqual(@as(?CodePageSnapshot, null), session.enable(oem));

    const restored = session.takeRestore() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(oem.input, restored.input);
    try std.testing.expectEqual(oem.output, restored.output);
    try std.testing.expect(!session.active);
    try std.testing.expectEqual(@as(?CodePageSnapshot, null), session.takeRestore());
}

test "code page session ignores a detached console and a second enable" {
    var session = CodePageSession{};
    try std.testing.expectEqual(@as(?CodePageSnapshot, null), session.enable(.{}));
    try std.testing.expect(!session.active);

    const utf8 = CodePageSnapshot{ .input = utf8_code_page, .output = utf8_code_page };
    const enabled = session.enable(utf8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(utf8_code_page, enabled.input);
    try std.testing.expectEqual(utf8_code_page, enabled.output);

    const restored = session.takeRestore() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(utf8_code_page, restored.input);
    try std.testing.expectEqual(utf8_code_page, restored.output);
}

test "utf8 console wrappers are safe when no Windows console is attached" {
    enableUtf8Console();
    restoreUtf8Console();
    restoreUtf8Console();
}
