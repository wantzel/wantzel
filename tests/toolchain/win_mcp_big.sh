# The large-message paths of lib/mcp.wz and lib/toolsmcp.wz work on Windows. Behind
# --windows: it runs an .exe under Wine.
#
# A message that outgrows the static buffers moves into an anonymous mapping, which the
# Windows runtime makes with CreateFileMapping/MapViewOfFile and gives back with
# UnmapViewOfFile. Whether that mapping is usable at 10 MB, whether a pipe delivers a line of
# that size through ReadFile, and whether the mapping really goes back are questions about
# what the program DOES; the bytes of the .exe do not answer them. So: the same server as
# tests/lib/mcp_big_stdio.sh, a 10 MB request, a 10 MB result compared byte for byte, a
# result over the limit, and the library's mapping count back where it started.
. "$ROOT/tests/helpers.sh"
[ -x "${WINE:-/usr/lib/wine/wine64}" ] || command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || { echo "wine is missing"; exit 1; }

compile_win "$ROOT/tests/lib/progs/mcpbig.wz" "$T/mcpbig.exe"

MB=1048576
pat() { yes '0123456789abcd"\' | tr -d '\n' | head -c "$1"; }
esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }
digest() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"digest","arguments":{"payload":"' "$1"; pat "$2" | esc; printf '"}}}\n'; }
blob_expect() {
  { printf '{"data":"'; pat "$2" | esc; printf '"}'; } > "$T/j"
  { printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"' "$1"
    esc < "$T/j"
    printf '"}],"structuredContent":'; cat "$T/j"; printf ',"isError":false}}'; } | sha256sum | cut -c1-64
}
reply() { grep "^{\"jsonrpc\":\"2.0\",\"id\":$2," "$1" | tr -d '\n\r'; }
probe_of() { reply "$1" "$2" | sed 's/.*"structuredContent":\({[^}]*}\).*/\1/'; }

{
  call 1 probe '{}'
  digest 2 $((10 * MB))
  call 3 blob "{\"size\":$((10 * MB))}"
  call 4 blob "{\"size\":$((15 * MB))}"     # 16.9 MB of result over a 16 MB limit
  call 5 probe '{}'
} > "$T/in"
# a 16 MB result limit: above TOOLBUF, so results go through the mapping
(cd "$T" && run_win "$T/mcpbig.exe" 0 0 $((16 * MB)) < "$T/in" > "$T/out" 2> "$T/err") \
  || { echo "the .exe exited non-zero:"; head -c 500 "$T/err"; exit 1; }

want=$(pat $((10 * MB)) | sha256sum | cut -c1-64)
assert_contains "a 10 MB request reaches the tool whole" "$(reply "$T/out" 2)" "\"bytes\":$((10 * MB)),\"sha256\":\"$want\""
assert_eq "a 10 MB result comes back byte for byte" \
  "$(reply "$T/out" 3 | sha256sum | cut -c1-64)" "$(blob_expect 3 $((10 * MB)))"
assert_eq "a result over the limit is a JSON-RPC error" "$(reply "$T/out" 4)" \
  '{"jsonrpc":"2.0","id":4,"error":{"code":-32603,"message":"the tool result is larger than the maximum of 16777216 bytes","data":{"limit":16777216}}}'
first=$(probe_of "$T/out" 1)
assert_contains "the probe answered" "$first" '"mapped":1,'
assert_eq "every mapping went back" "$(probe_of "$T/out" 5)" "$first"
echo "on Windows: 10 MB in and out, over-limit error, mappings back to $first"
