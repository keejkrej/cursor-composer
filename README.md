# cursor-composer

FX-style terminal UI for Cursor agents. The installable binary is **`cc`** (Cursor Composer). The TUI is **copied from [Vercel fx](https://github.com/vercel-labs/fx)** (Zig). The agent loop is **not** implemented here — create, send, stream, wait, and cancel go to Cursor through the [SDK Bridge](https://cursor.com/docs/sdk/bridge).

```text
┌──────────────────────┐   Connect/JSON sdk.v1   ┌────────────────────┐   HTTPS   ┌────────────┐
│  cc (Cursor Composer)│ ──────────────────────► │  cursor-sdk-bridge │ ────────► │ Cursor API │
│  (fx Zig UI, copied) │ ◄────────────────────── │  (local process)   │           │            │
└──────────────────────┘                         └────────────────────┘           └────────────┘
```

## Requirements

- Zig 0.16.0+
- A Cursor user or service-account API key (`CURSOR_API_KEY`)
- The standalone `cursor-sdk-bridge` binary (see below)

Team Admin API keys are not supported by the bridge.

## Install and run

```bash
git clone https://github.com/keejkrej/cursor-composer.git
cd cursor-composer
./scripts/fetch-bridge.sh 1.0.30
export CURSOR_API_KEY="your-key"
zig build -Doptimize=ReleaseSafe
./zig-out/bin/cc
```

The current directory is the workspace passed to Cursor as `options.local.cwd`. Enter a prompt, or `/help`. While a run is active, Enter queues a follow-up (fx behavior). The model default is `composer-2.5`; override with `CURSOR_MODEL` or `/model`.

Create vs resume:

```bash
# New Cursor agent (CreateAgent). The agent id is stored in .cursor-composer/last-agent.
./zig-out/bin/cc

# Resume the last Cursor agent for this workspace
./zig-out/bin/cc --resume last
./zig-out/bin/cc ask --resume last "continue from the previous turn"

# Resume a specific Cursor agent id
./zig-out/bin/cc --resume bc-your-agent-id
CURSOR_AGENT_ID=bc-your-agent-id ./zig-out/bin/cc

# /resume in the TUI resumes the last Cursor agent; /new starts a new one
```

One-shot:

```bash
./zig-out/bin/cc ask "explain the changes in this repository"
```

## What this process owns

- The fx terminal: transcript, footer composer, slash completion, status line, resize, `ask`
- Bridge process lifecycle (spawn, ready-line handshake, bearer token, shutdown)
- Mapping Cursor `sdk.v1` stream envelopes onto fx presentation sinks

## What Cursor owns

- Agent create / resume
- The agent loop, tools, planning, and file edits
- Run streaming, cancellation, and usage

This repository does not implement tools, retries, or an orchestrator for model turns. The compiled TUI always delegates create/send/stream/wait/cancel to Cursor.

## Bridge

The wire contract is `sdk.v1` from [cursor/sdk-bridge](https://github.com/cursor/sdk-bridge) v1.0.30, vendored under `vendor/sdk-bridge/proto`. The adapter speaks Connect over HTTP/1.1 with JSON bodies (`application/json` unary, `application/connect+json` streams). Classic gRPC will not connect.

Environment:

| Variable | Meaning |
| --- | --- |
| `CURSOR_API_KEY` | Cursor API key (also accepted as `AI_GATEWAY_API_KEY` so the fx auth gate unlocks) |
| `CURSOR_MODEL` | Model id (default `composer-2.5`) |
| `CURSOR_AGENT_ID` | Resume this Cursor agent instead of creating one |
| `CURSOR_SDK_BRIDGE_BIN` | Path to `cursor-sdk-bridge` |
| `CURSOR_SDK_BRIDGE_URL` + `CURSOR_SDK_BRIDGE_TOKEN` | Attach to an already-running bridge |

## Build

```bash
zig build
zig build test
```

## License

Apache-2.0, same as fx. The TUI is derived from vercel-labs/fx; see `NOTICE` and `THIRD_PARTY_NOTICES.md`. The Cursor SDK Bridge protocol files under `vendor/sdk-bridge` are MIT.
