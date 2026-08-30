#!/usr/bin/env python3
"""Minimal Connect/JSON sdk.v1 stand-in for cursor-composer adapter tests."""

from __future__ import annotations

import json
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "test-bridge-token"
AGENT_CREATE = "agent_created_1"
AGENT_RESUME = "agent_resumed_1"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mock-sdk-bridge/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("mock-bridge: " + (fmt % args) + "\n")

    def do_POST(self) -> None:  # noqa: N802
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"code":"unauthenticated"}')
            return

        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        if "connect+json" in ctype and len(raw) >= 5:
            payload_len = struct.unpack(">I", raw[1:5])[0]
            body = raw[5 : 5 + payload_len]
        else:
            body = raw

        path = self.path
        if path.endswith("/Ping"):
            self._unary({"message": "pong"})
        elif path.endswith("/SetToolCallback"):
            self._unary({})
        elif path.endswith("/CreateAgent"):
            self._unary({"agentId": AGENT_CREATE})
        elif path.endswith("/ResumeAgent"):
            req = json.loads(body or b"{}")
            agent_id = req.get("agentId") or req.get("agent_id") or AGENT_RESUME
            self._unary({"agentId": agent_id})
        elif path.endswith("/CancelRun"):
            self._unary({})
        elif path.endswith("/WaitLiveRun"):
            self._unary({"result": {"status": "FINISHED"}})
        elif path.endswith("/Shutdown"):
            self._unary({})
        elif path.endswith("/Me"):
            self._unary({"user": {"id": "user_mock"}})
        elif path.endswith("/ListModels"):
            # Proto ListModelsResponse.repeated SdkModel items. Include a
            # mock-only id so tests can tell live catalog from the static six.
            self._unary(
                {
                    "items": [
                        {"id": "mock-live-model", "displayName": "Mock Live"},
                        {"id": "composer-2.5"},
                        {"id": "grok-4.6"},
                    ]
                }
            )
        elif path.endswith("/Send"):
            self._stream(
                [
                    {
                        "sdkMessage": {
                            "type": "status",
                            "status": "RUNNING",
                            "runId": "run_mock_1",
                            "message": {"runId": "run_mock_1"},
                        }
                    },
                    {
                        "sdkMessage": {
                            "type": "assistant",
                            "message": {"content": [{"type": "text", "text": "hello from mock"}]},
                        }
                    },
                    {
                        "sdkMessage": {
                            "type": "tool_call",
                            "call_id": "c1",
                            "name": "Read",
                            "status": "running",
                            "args": {"path": "README.md"},
                        }
                    },
                    {
                        "sdkMessage": {
                            "type": "tool_call",
                            "callId": "c1",
                            "name": "Read",
                            "status": "completed",
                            "result": {"ok": True},
                        }
                    },
                    {"result": {"status": "FINISHED", "result": "hello from mock"}},
                ]
            )
        else:
            self.send_error(404)

    def _unary(self, obj: dict) -> None:
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _stream(self, messages: list[dict]) -> None:
        chunks = bytearray()
        for message in messages:
            payload = json.dumps(message).encode()
            chunks.extend(struct.pack(">BI", 0, len(payload)))
            chunks.extend(payload)
        chunks.extend(struct.pack(">BI", 0x02, 0))
        self.send_response(200)
        self.send_header("Content-Type", "application/connect+json")
        self.send_header("Content-Length", str(len(chunks)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(chunks)


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    host, port = server.server_address
    print(f"READY http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
