#!/usr/bin/env python3
"""Black-box stdio protocol checks; never connects to a running browser."""
import argparse
import json
from pathlib import Path
import selectors
import subprocess


def check(command, version):
    process = subprocess.Popen([command, "--socket", str(Path.home() / ".nous-mcp-missing-qa/bridge.sock")],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def send(message):
        process.stdin.write((message if isinstance(message, str) else json.dumps(message)) + "\n")
        process.stdin.flush()

    def receive():
        assert selector.select(5), "MCP stdout response timed out"
        response = json.loads(process.stdout.readline())
        assert response["jsonrpc"] == "2.0"
        return response

    try:
        send("{invalid-json")
        malformed = receive()
        assert malformed["error"]["code"] == -32700 and malformed["id"] is None
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "stdlib-protocol-qa", "version": "1"}}})
        initialized = receive()
        assert initialized["id"] == 1
        negotiated = initialized["result"]["protocolVersion"]
        assert negotiated == (version if version != "1900-01-01" else "2025-11-25")
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "unknown/method", "params": {}})
        unknown = receive()
        assert unknown["id"] == 2 and unknown["error"]["code"] == -32601
        send({"jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": {"cursor": "invalid"}})
        cursor = receive()
        assert cursor["id"] == 3 and cursor["error"]["code"] == -32602
        # Cancellation of an unknown request is advisory and produces no response.
        send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 999, "reason": "QA"}})
        send({"jsonrpc": "2.0", "id": 4, "method": "ping"})
        assert receive()["id"] == 4
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert not process.stdout.read(), "Unexpected extra protocol response"
        return {"requested": version, "negotiated": negotiated, "status": "passed"}
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", required=True)
    args = parser.parse_args()
    results = [check(args.command, version) for version in ("2024-11-05", "2025-03-26", "2025-11-25", "1900-01-01")]
    print(json.dumps({"stdio_protocol_checks": results, "checks": ["malformed JSON null ID", "version negotiation", "unknown method", "invalid cursor", "unknown cancellation", "EOF shutdown"]}, indent=2))
