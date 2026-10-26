#!/usr/bin/env python3
"""Exercise the packaged stdio helper using the official independent Python MCP SDK.

Requires Python 3.10+ and `pip install mcp`. Run only against an enabled isolated
QA app socket and Tests/Fixtures/mcp_test_server.py, never a real browser profile.
"""
import argparse
import asyncio
import base64
import json
import struct
from pathlib import Path
from urllib.parse import urlparse

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def exercise(args):
    default_socket = Path.home() / ".local/share/NousBrowser/automation/bridge.sock"
    if Path(args.socket).resolve() == default_socket.resolve():
        raise ValueError("Use an isolated QA app socket, never the user's default browser socket.")
    parsed = urlparse(args.url)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1":
        raise ValueError("The fixture URL must be a loopback http://127.0.0.1 URL.")
    server = StdioServerParameters(command=args.command, args=["--socket", args.socket])
    exercised = set()

    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            initialized = await session.initialize()
            assert initialized.serverInfo.name == "nous-browser"
            tools = await session.list_tools()
            assert len(tools.tools) == 16
            assert len({tool.name for tool in tools.tools}) == 16
            await session.send_ping()

            async def call(name, arguments=None, expected_error=False):
                result = await session.call_tool(name, arguments or {})
                exercised.add(name)
                if expected_error:
                    assert result.isError, f"Expected {name} to fail"
                    return result
                assert not result.isError, f"{name}: {result.content}"
                if result.structuredContent is not None:
                    return result.structuredContent
                return json.loads(next(item.text for item in result.content if item.type == "text"))

            async def snapshot(tab_id, title=None):
                # Retry only observable loading/not-ready states, not actions.
                for attempt in range(40):
                    result = await session.call_tool("browser_snapshot", {"tab_id": tab_id})
                    exercised.add("browser_snapshot")
                    if not result.isError:
                        value = result.structuredContent
                        if value is None:
                            value = json.loads(next(item.text for item in result.content if item.type == "text"))
                        if title is None or title in value.get("title", ""):
                            return value
                    await asyncio.sleep(0.1)
                raise AssertionError("Fixture page did not become ready")

            def element(snap, name):
                matches = [item for item in snap["elements"] if item.get("name") == name]
                assert len(matches) == 1, f"Expected one fixture control {name}, got {len(matches)}"
                return matches[0]["ref"]

            def target(tab_id, snap, name):
                return {"tab_id": tab_id, "snapshot_id": snap["snapshot_id"], "ref": element(snap, name)}

            initial = await call("browser_list_tabs")
            original_ids = {tab["tab_id"] for tab in initial["tabs"]}
            created_ids = []
            await call("browser_list_windows")
            try:
                page = await call("browser_new_window", {"url": args.url})
                tab_id, window_id = page["tab_id"], page["window_id"]
                created_ids.append(tab_id)
                first = await snapshot(tab_id, "Fixture One")
                assert "synthetic, disposable" in first["text"]
                assert "HIDDEN_FIXTURE_TEXT" not in first["text"]
                assert "FIXTURE_ONLY_NOT_A_REAL_PASSWORD" not in json.dumps(first)

                fresh = await snapshot(tab_id)
                await call("browser_click", target(tab_id, first, "Increment"), expected_error=True)
                await call("browser_fill", {**target(tab_id, fresh, "Message"), "text": "MCP smoke 中文"})
                filled = await snapshot(tab_id)
                assert "Input event: MCP smoke 中文" in filled["text"]
                await call("browser_press_key", {**target(tab_id, filled, "Message"), "key": "Enter"})
                keyed = await snapshot(tab_id)
                assert "Key: Enter" in keyed["text"]
                await call("browser_click", target(tab_id, keyed, "Increment"))
                counted = await snapshot(tab_id)
                assert "Counter: 1" in counted["text"]
                await call("browser_fill", {**target(tab_id, counted, "Synthetic password"), "text": "not-allowed"}, expected_error=True)
                await call("browser_click", target(tab_id, counted, "Disabled fixture button"), expected_error=True)
                await call("browser_navigate", {"tab_id": tab_id, "url": "file:///etc/hosts"}, expected_error=True)
                await call("browser_navigate", {"tab_id": tab_id, "url": args.url.rstrip("/") + "/page2"})
                await snapshot(tab_id, "Fixture Two")
                await call("browser_back", {"tab_id": tab_id})
                await snapshot(tab_id, "Fixture One")
                await call("browser_forward", {"tab_id": tab_id})
                await snapshot(tab_id, "Fixture Two")
                await call("browser_reload", {"tab_id": tab_id, "bypass_cache": True})
                await snapshot(tab_id, "Fixture Two")
                await call("browser_scroll", {"tab_id": tab_id, "x": 0, "y": 300})
                scrolled = await snapshot(tab_id)
                assert scrolled["viewport"]["scroll_y"] > 0
                await call("browser_scroll", {"tab_id": tab_id, "x": 0, "y": -10000})
                picture = await session.call_tool("browser_screenshot", {"tab_id": tab_id})
                exercised.add("browser_screenshot")
                assert not picture.isError
                image = next(item for item in picture.content if item.type == "image")
                assert image.mimeType == "image/png"
                data = base64.b64decode(image.data, validate=True)
                assert data.startswith(b"\x89PNG\r\n\x1a\n")
                width, height = struct.unpack(">II", data[16:24])
                assert 0 < width <= 2000 and height > 0

                second = await call("browser_new_tab", {"window_id": window_id, "after_tab_id": tab_id, "url": args.url})
                second_id = second["tab_id"]
                created_ids.append(second_id)
                await snapshot(second_id, "Fixture One")
                tabs = await call("browser_list_tabs", {"window_id": window_id})
                assert [tab["tab_id"] for tab in tabs["tabs"]] == [tab_id, second_id]
                await call("browser_select_tab", {"tab_id": tab_id})
                windows = await call("browser_list_windows")
                assert next(window for window in windows["windows"] if window["window_id"] == window_id)["selected_tab_id"] == tab_id
            finally:
                for created_id in reversed(created_ids):
                    await call("browser_close_tab", {"tab_id": created_id})
                remaining = await call("browser_list_tabs")
                assert {tab["tab_id"] for tab in remaining["tabs"]} == original_ids, "QA cleanup changed pre-existing tabs"
            assert exercised == {tool.name for tool in tools.tools}, f"Unexercised tools: {set(tool.name for tool in tools.tools) - exercised}"
            print(json.dumps({"status": "passed", "client": "official Python MCP SDK", "server": initialized.serverInfo.name,
                              "version": initialized.serverInfo.version, "protocol": initialized.protocolVersion,
                              "tools_exercised": sorted(exercised), "original_tabs_preserved": len(original_ids)}, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", required=True, help="Absolute path to the built NousBrowserMCP executable")
    parser.add_argument("--socket", required=True, help="Explicit isolated QA socket, never the default socket")
    parser.add_argument("--url", required=True, help="Loopback URL printed by mcp_test_server.py")
    args = parser.parse_args()
    asyncio.run(exercise(args))


if __name__ == "__main__":
    main()
