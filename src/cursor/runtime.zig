const std = @import("std");
const builtin = @import("builtin");
const agent_runtime = @import("../core/agent/agent_runtime.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const runtime_deps = @import("../core/agent/runtime/deps.zig");
const runtime_config = @import("../core/agent/runtime/config.zig");
const runtime_assistant_stream = @import("../core/agent/runtime/assistant_stream.zig");
const runtime_lifecycle = @import("../core/agent/runtime/lifecycle.zig");
const io_mod = @import("../core/shared/io.zig");
const session = @import("session.zig");
const turn = @import("turn.zig");

const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const Config = runtime_config.Config;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const LifecycleContext = runtime_lifecycle.LifecycleContext;

/// Production binaries always delegate the agent loop to Cursor.
/// Vendored FX unit tests keep exercising the original orchestrator unless a
/// Cursor key or attached bridge is present.
pub fn usesCursorRuntime() bool {
    if (!builtin.is_test) return true;
    return session.resolveApiKey() != null or io_mod.getenv("CURSOR_SDK_BRIDGE_URL") != null;
}

pub fn processQueuedPrompt(
    deps: *const AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: QueuedPrompt,
) !void {
    if (usesCursorRuntime()) {
        return turn.processQueuedPrompt(deps, semantic_presentation, lifecycle, config, job);
    }
    return agent_runtime.processQueuedPrompt(deps, semantic_presentation, lifecycle, config, job);
}

test "production path is Cursor-only outside unit tests" {
    if (!builtin.is_test) {
        try std.testing.expect(usesCursorRuntime());
    }
}
