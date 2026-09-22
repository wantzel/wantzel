# The smallest MCP server that can exist must answer, not crash.
#
# A program with a tools block, a handler and mcp.stdio is a complete server; mcp.name and
# mcp.version are globals the application MAY set. One that did not set them used to
# segfault on its first request, because an unset str is (address 0, length 0) and slen
# read the eight bytes before that address.
#
# This test is the shape a newcomer writes, and it is here because that is exactly the
# program nobody had written: every example in the repository sets both globals.
. "$ROOT/tests/helpers.sh"

cat > "$T/minimal.wz" <<'WZ'
include "json.wz";
type AddArgs = schema
  a: int "the left operand";
  b: int "the right operand";
end;
type AddResult = schema
  sum: int;
end;
tools
  add(AddArgs): AddResult "Add two whole numbers." readonly idempotent;
end;
include "tools.wz";
function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;
end;
// lib/tools.wz includes http.wz, so even a stdio-only server needs this
procedure app.request;
begin
end;
begin
  mcp.stdio;
end.
WZ

compile "$T/minimal.wz" "$T/minimal"

out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23}}}' \
  | "$T/minimal" 2>&1) || { echo "the minimal server exited non-zero:"; printf '%s\n' "$out"; exit 1; }

assert_contains "it answers the handshake" "$out" '"protocolVersion":"2025-03-26"'
# a name it never set: the library fills one in, because an empty name is a reply a client
# cannot use
assert_contains "and names itself, without being told to" "$out" '"name":"wantzel-mcp"'
assert_contains "the tool runs" "$out" '"sum":42'

# and an application that DOES set them still wins
assert_contains "an application's own name is used" \
  "$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' \
     | { compile "$ROOT/examples/mcptools.wz" "$T/mcptools"; "$T/mcptools"; } 2>&1)" \
  '"name":"wantzel-tools"'

echo "a server that sets nothing answers, and one that sets a name keeps it"
