const std = @import("std");
const types = @import("../core/shared/types.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const runtime_deps = @import("../core/agent/runtime/deps.zig");
const runtime_config = @import("../core/agent/runtime/config.zig");
const runtime_finalization = @import("../core/agent/runtime/finalization.zig");
const runtime_assistant_stream = @import("../core/agent/runtime/assistant_stream.zig");
const runtime_lifecycle = @import("../core/agent/runtime/lifecycle.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const client_mod = @import("client.zig");
const events = @import("events.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const Config = runtime_config.Config;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const LifecycleContext = runtime_lifecycle.LifecycleContext;
const TurnFinalizationGuard = runtime_finalization.TurnFinalizationGuard;

/// Replaces FX's local agent/tool loop. The Cursor SDK Bridge owns create/send/stream/wait/cancel.
pub fn processQueuedPrompt(
    deps: *const AgentRuntimeDeps,
    _: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: QueuedPrompt,
) !void {
    var effective_job = job;
    if (effective_job.turn_id == 0) {
        effective_job.turn_id = debug_trace.nextTurnId();
    }
    var finalization = TurnFinalizationGuard.init(deps, effective_job.turn_id, lifecycle);
    defer finalization.deinit();

    processQueuedPromptInner(deps, config, effective_job) catch |err| {
        if (finalization.state == .open) {
            finalization.finish(.failed, null, null) catch |finalization_err| return finalization_err;
        }
        return err;
    };
    if (finalization.state == .open) {
        try finalization.finish(.completed, null, null);
    }
}

fn processQueuedPromptInner(
    deps: *const AgentRuntimeDeps,
    config: Config,
    job: QueuedPrompt,
) !void {
    const workspace = if (config.workspace_root.len > 0) config.workspace_root else ".";
    const resume_hint = session.peekResumeId(std.heap.c_allocator, workspace);
    defer if (resume_hint) |id| std.heap.c_allocator.free(id);
    const handle = session.ensure(
        std.heap.c_allocator,
        workspace,
        job.model,
        resume_hint,
    ) catch |err| {
        const message = switch (err) {
            error.MissingCursorApiKey => "Set CURSOR_API_KEY to call the Cursor Agent API via the SDK Bridge.",
            error.BridgeBinaryMissing => "cursor-sdk-bridge not found. Run scripts/fetch-bridge.sh or set CURSOR_SDK_BRIDGE_BIN.",
            else => blk: {
                const detail = @import("connect.zig").lastError();
                if (detail.len > 0) break :blk detail;
                break :blk @errorName(err);
            },
        };
        try deps.push_system_notice(deps.ctx, message);
        return err;
    };

    var stream = StreamState{
        .alloc = std.heap.c_allocator,
        .deps = deps,
        .turn_id = job.turn_id,
        .cancel_flag = config.cancel_flag,
        .agent_id = handle.agent_id,
        .client = handle.client,
        .run_id = null,
    };
    defer if (stream.run_id) |run_id| stream.alloc.free(run_id);

    if (resume_hint != null) {
        try deps.push_system_notice(deps.ctx, "Resuming Cursor agent via the SDK Bridge.");
    } else {
        try deps.push_system_notice(deps.ctx, "Created Cursor agent via the SDK Bridge.");
    }

    handle.client.send(
        handle.agent_id,
        job.prompt,
        handle.model,
        onStreamMessage,
        @ptrCast(&stream),
    ) catch |err| {
        if (config.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const detail = @import("connect.zig").lastError();
        try deps.push_system_notice(deps.ctx, if (detail.len > 0) detail else @errorName(err));
        return err;
    };

    try deps.push_tool_lifecycle(deps.ctx, .{
        .turn_finished = .{
            .turn_id = job.turn_id,
            .outcome = .completed,
        },
    });
}

const StreamState = struct {
    alloc: Allocator,
    deps: *const AgentRuntimeDeps,
    turn_id: u64,
    cancel_flag: *std.atomic.Value(bool),
    agent_id: []const u8,
    client: client_mod.Client,
    run_id: ?[]u8,
};

fn onStreamMessage(raw: *anyopaque, payload: []const u8) anyerror!void {
    const stream: *StreamState = @ptrCast(@alignCast(raw));
    if (stream.cancel_flag.load(.seq_cst)) {
        if (stream.run_id) |run_id| {
            stream.client.cancelRun(run_id, stream.agent_id) catch {};
        }
        return error.Cancelled;
    }

    rememberRunId(stream, payload);

    const action = try events.actionFromEnvelope(stream.alloc, payload);
    defer events.freeAction(stream.alloc, action);
    try present(stream, action);
}

fn rememberRunId(stream: *StreamState, payload: []const u8) void {
    if (stream.run_id != null) return;
    const parsed = std.json.parseFromSlice(std.json.Value, stream.alloc, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const message = parsed.value.object.get("sdkMessage") orelse parsed.value.object.get("sdk_message") orelse return;
    const run_id = switch (message) {
        .object => |obj| blk: {
            if (obj.get("run_id")) |value| if (value == .string) break :blk value.string;
            if (obj.get("runId")) |value| if (value == .string) break :blk value.string;
            if (obj.get("message")) |inner| {
                if (inner == .object) {
                    if (inner.object.get("run_id")) |value| if (value == .string) break :blk value.string;
                    if (inner.object.get("runId")) |value| if (value == .string) break :blk value.string;
                }
            }
            break :blk null;
        },
        else => null,
    } orelse return;
    stream.run_id = stream.alloc.dupe(u8, run_id) catch null;
}

fn present(stream: *StreamState, action: events.Action) !void {
    const deps = stream.deps;
    switch (action) {
        .assistant_text => |text| {
            try deps.push_text(deps.ctx, .{ .assistant_source = text });
            try deps.push_text(deps.ctx, .{ .assistant_rendered = text });
        },
        .thinking_text => |text| try deps.push_text(deps.ctx, .{ .operational = text }),
        .status => |text| try deps.push_system_notice(deps.ctx, text),
        .usage, .ignore => {},
        .terminal_result => |result| {
            if (result.error_message) |err_text| {
                try deps.push_system_notice(deps.ctx, err_text);
            }
        },
        .tool_started => |tool| {
            const kind: types.ToolActivityKind = switch (events.classifyToolActivity(tool.name)) {
                .read => .read,
                .list => .list,
                .write => .write,
                .edit => .edit,
                .command => .command,
            };
            try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
                .id = .{ .turn_id = stream.turn_id, .call_id = tool.call_id },
                .reconciles_provisional_call_id = null,
                .tool_name = tool.name,
                .activity_kind = kind,
                .arguments_json = tool.args_json,
            } });
        },
        .tool_finished => |tool| {
            try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
                .id = .{ .turn_id = stream.turn_id, .call_id = tool.call_id },
                .outcome = .{
                    .kind = if (tool.ok) .completed else .failed,
                    .summary = tool.name,
                },
                .result = tool.result_json,
            } });
        },
    }
}
