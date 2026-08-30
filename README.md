# cursor-composer

FX-style terminal UI for Cursor agents. The installable binary is **`cc`** (Cursor Composer). The TUI is **copied from [Vercel fx](https://github.com/vercel-labs/fx)** (Zig). The agent loop is **not** implemented here — create, send, stream, wait, and cancel go to Cursor through the [SDK Bridge](https://cursor.com/docs/sdk/bridge).

```text
┌──────────────────────┐   Connect/JSON sdk.v1   ┌────────────────────┐   HTTPS   ┌────────────┐
│  cc (Cursor Composer)│ ──────────────────────► │  cursor-sdk-bridge │ ────────► │ Cursor API │
│  (fx Zig UI, copied) │ ◄────────────────────── │  (local process)   │           │            │
└──────────────────────┘                         └────────────────────┘           └────────────┘
```

## Install

macOS / Linux:

```bash
curl -fsSL https://github.com/keejkrej/cursor-composer/releases/latest/download/install | bash
```

Windows (PowerShell):

```powershell
irm https://github.com/keejkrej/cursor-composer/releases/latest/download/install.ps1 | iex
```

That installs `cc` and `cursor-sdk-bridge` into `~/.cc/bin`. Override with `CC_INSTALL_DIR` or `XDG_BIN_DIR`. Pin a release with `CC_VERSION=0.1.0`. Then:

```bash
export CURSOR_API_KEY="your-key"
cc
```

GitHub publishes archives for linux-x64/arm64, darwin-x64/arm64, and windows-x64/arm64 on each `v*` tag (or via the Release workflow dispatch). After a release exists, the installer above downloads it.

## Requirements

- A Cursor user or service-account API key (`CURSOR_API_KEY`)
- The standalone `cursor-sdk-bridge` binary (bundled by the installer)

Team Admin API keys are not supported by the bridge.

## Build from source

```bash
git clone https://github.com/keejkrej/cursor-composer.git
cd cursor-composer
./scripts/fetch-bridge.sh 1.0.30
export CURSOR_API_KEY="your-key"
zig build -Doptimize=ReleaseSafe
./zig-out/bin/cc
```

Requires Zig 0.16.0+.

The current directory is the workspace passed to Cursor as `options.local.cwd`. Enter a prompt, or `/help`. While a run is active, Enter queues a follow-up (fx behavior). The model default is `grok-4.6` (Cursor Grok 4.6). Switch with `/model` (picker) or `/model <id>` — same as fx. `CURSOR_MODEL` is the fallback when `/model` has not selected a Cursor id.

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
| `CURSOR_MODEL` | Fallback model when `/model` has not picked a Cursor id (default `grok-4.6`) |
| `CURSOR_AGENT_ID` | Resume this Cursor agent instead of creating one |
| `CURSOR_SDK_BRIDGE_BIN` | Path to `cursor-sdk-bridge` (otherwise `cc` looks next to itself, then `~/.cc/bin`, then `cursor-sdk-bridge/bin/cursor-sdk-bridge`) |
| `CURSOR_SDK_BRIDGE_URL` + `CURSOR_SDK_BRIDGE_TOKEN` | Attach to an already-running bridge |

## Build

```bash
zig build
zig build test
```

## License

Apache-2.0, same as fx. The TUI is derived from vercel-labs/fx; see `NOTICE` and `THIRD_PARTY_NOTICES.md`. The Cursor SDK Bridge protocol files under `vendor/sdk-bridge` are MIT.
