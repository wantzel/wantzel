# Connect to a Wantzel MCP server with the official MCP SDK over Streamable HTTP.
import asyncio, sys
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8099/mcp"

async def main():
    async with streamable_http_client(URL) as (read, write):
        async with ClientSession(read, write) as s:
            init = await s.initialize()
            print("initialize   ->", init.server_info.name, init.protocol_version)
            tools = await s.list_tools()
            print("tools/list   ->", ", ".join(t.name for t in tools.tools))
            r = await s.call_tool("list_dir", {})
            print("list_dir     ->", r.content[0].text.split("\n")[0], "...")
            r = await s.call_tool("search", {"query": "SO_REUSEPORT", "max": 2})
            for line in r.content[0].text.strip().split("\n"):
                if line.strip(): print("search       ->", line)

asyncio.run(main())
