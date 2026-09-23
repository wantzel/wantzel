# A stdio-only MCP server with a tools block compiles WITHOUT defining app.request.
#
# lib/tools.wz carries the REST half of the tool glue and so brings lib/http.wz, which
# declares app.request forward: a program that includes it must define that hook even when
# it never serves HTTP.  lib/toolsmcp.wz is the MCP half on its own.  This test is the
# program a newcomer writes for stdio -- tools, a handler, mcp.stdio, nothing else -- and
# it must compile and answer tools/list and tools/call, on both targets.
#
# TOETSGROEP: schema
# DEKT: lib/toolsmcp.wz lib/tools.wz
. "$ROOT/tests/helpers.sh"

cat > "$T/stdio.wz" <<'WZ'
include "json.wz";                     // a schema needs it before the first type
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
include "toolsmcp.wz";
function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;
end;
begin
  mcp.stdio;
end.
WZ

compile "$T/stdio.wz" "$T/stdio"
compile_win "$T/stdio.wz" "$T/stdio.exe"

out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23}}}' \
  | "$T/stdio" 2>&1) || { echo "the stdio server exited non-zero:"; printf '%s\n' "$out"; exit 1; }

assert_contains "it answers the handshake" "$out" '"protocolVersion":"2025-03-26"'
assert_contains "tools/list names the tool" "$out" '"name":"add"'
assert_contains "tools/list carries its input schema" "$out" '"inputSchema"'
assert_contains "the tool runs" "$out" '"sum":42'

# The REST half is still one include away: the same program with lib/tools.wz and without
# app.request must keep failing on the missing hook, so the split did not quietly drop it.
sed 's/include "toolsmcp.wz";/include "tools.wz";/' "$T/stdio.wz" > "$T/whole.wz"
if "$WANTZEL" "$T/whole.wz" "$T/whole" 2>"$T/werr"; then
  echo "lib/tools.wz compiled without app.request -- it no longer brings lib/http.wz"; exit 1
fi
assert_contains "lib/tools.wz still asks for app.request" "$(cat "$T/werr")" "forward"

echo "a stdio MCP server with a tools block needs no app.request; lib/tools.wz still brings REST"
