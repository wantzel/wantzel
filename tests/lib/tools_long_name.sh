# A tool name longer than 62 characters is accepted, listed and callable.
#
# The name of a tool is also its wire name over MCP and REST, so an application that
# mirrors an existing service cannot shorten it.  Real names reach 71 characters; the
# limit is 126.  The test uses a 100-character name, and checks that 127 is refused with
# the compiler's own message rather than truncated.
#
# TOETSGROEP: schema
# DEKT: src/wantzel.wz bootstrap/boot.c lib/toolsmcp.wz
. "$ROOT/tests/helpers.sh"

long=total_installed_peak_power_of_a_photovoltaic_system_across_every_roof_surface_in_kilowatt_peak_today
[ ${#long} -eq 100 ] || { echo "the test name is ${#long} characters, not 100"; exit 1; }

cat > "$T/long.wz" <<WZ
include "json.wz";
type AddArgs = schema
  a: int;
  b: int;
end;
type AddResult = schema
  sum: int;
end;
tools
  $long(AddArgs): AddResult "Add two whole numbers under a long name.";
end;
include "toolsmcp.wz";
function tool.$long(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;
end;
begin
  mcp.stdio;
end.
WZ

compile "$T/long.wz" "$T/long"

out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$long\",\"arguments\":{\"a\":19,\"b\":23}}}" \
  | "$T/long" 2>&1) || { echo "the server exited non-zero:"; printf '%s\n' "$out"; exit 1; }

assert_contains "tools/list names the full 100-character tool" "$out" "\"name\":\"$long\""
assert_contains "the tool runs under its full name" "$out" '"sum":42'

# 127 characters is one past the limit: refused, with the message, not truncated
over=${long}${long}
over=$(printf '%s' "$over" | cut -c1-127)
sed "s/$long/$over/g" "$T/long.wz" > "$T/over.wz"
if "$WANTZEL" "$T/over.wz" "$T/over" 2>"$T/err"; then
  echo "a 127-character tool name compiled"; exit 1
fi
assert_contains "127 characters is refused by name" "$(cat "$T/err")" "tool name too long"

echo "a 100-character tool name compiles, lists and runs; 127 is refused"
