# lib/mcp.wz answers a REALISTIC initialize -- one that carries capabilities and
# clientInfo beside protocolVersion, the way every actual MCP client sends it.
#
# WHY THIS EXISTS.  When an undeclared key became a refusal, schema Init
# still declared protocolVersion only. Init.parse then returned -1 for every genuine
# handshake, the version the client asked for was ignored, and the server answered with
# the oldest one it supports. No error anywhere: a wrong answer that refuses nothing,
# which is exactly the failure this language exists to prevent.
#
# The whole suite stayed green through that, because nothing tested a handshake with the
# fields a real client sends. A protocol test has to use the real shape, not the minimum
# the parser happens to need.
. "$ROOT/tests/helpers.sh"

compile "$ROOT/examples/mcpfiles.wz" "$T/mcpfiles"
mkdir -p "$T/proj"
printf 'content\n' > "$T/proj/readme.txt"

ask() { printf '%s\n' "$1" | "$T/mcpfiles" "$T/proj" 2>/dev/null | head -1; }

# the version the client asks for is the version it gets back
got=$(ask '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}')
assert_contains "a full initialize echoes the requested protocol version" "$got" '"protocolVersion":"2025-03-26"'

got=$(ask '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"probe","version":"1"}}}')
assert_contains "the older version is echoed as well" "$got" '"protocolVersion":"2024-11-05"'

# a tools/call with _meta beside the arguments, which MCP puts there for progress tokens
got=$(ask '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"readme.txt"},"_meta":{"progressToken":1}}}')
assert_contains "a tools/call carrying _meta is answered" "$got" 'content'

# and a genuinely unknown member in the params IS refused: strictness is the point, the
# protocol fields are declared because the protocol carries them, not to open the door
got=$(ask '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"readme.txt"},"nosuchfield":1}}')
assert_contains "an undeclared member of params is still refused" "$got" 'error'

echo "initialize negotiates, tools/call takes _meta, an unknown member is refused"
