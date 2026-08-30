const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");

pub const name = "ask_user_question";

pub const description =
    "Ask the user 1-4 multiple-choice questions in interactive runs only when a concrete decision blocks progress after local files, git state, or tool output cannot answer it. When to use: choose among precise, mutually exclusive paths before acting, especially user-preference decisions. When NOT to use: safety-review escalation, discoverable facts, GitHub handles unless account/private-access specific, gh/auth/tool blockers, trivial yes/no checks, open-ended discussion, or noninteractive runs; noninteractive runs should surface a blocker in freeform text instead.";

pub const option_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "label", .json_type = .string, .description = "Short precise action label, 1-5 words." },
        .{ .name = "description", .json_type = .string, .description = "Optional one-line consequence or scope of this option." },
    },
    .required = &.{"label"},
};

pub const question_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "question", .json_type = .string, .description = "Specific blocking decision shown to the user; do not ask for facts tools can inspect." },
        .{ .name = "options", .json_type = .array, .bounds = &.{ .min_items = 2, .max_items = 6 }, .shape = &.{ .array_objects = &option_schema } },
    },
    .required = &.{ "question", "options" },
};

pub const input_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "questions", .json_type = .array, .bounds = &.{ .min_items = 1, .max_items = 4 }, .shape = &.{ .array_objects = &question_schema } },
    },
    .required = &.{"questions"},
};

pub const function_schema = model_tool_schema.FunctionSchema{
    .name = name,
    .description = description,
    .input_schema = input_schema,
};
