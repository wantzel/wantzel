# MCP over stdio carries requests and results of tens of megabytes, and past a limit
# answers with a JSON-RPC error that names it -- never a cut-off reply, never a dead server.
#
# TOETSGROEP: lib
# DEKT: lib/mcp.wz lib/toolsmcp.wz
#
# The static buffers are 4 MB (request, reply) and 1 MB (tool result); everything here is
# larger, so every message below goes through the mappings lib/mcp.wz and lib/toolsmcp.wz
# make when a message outgrows them.  Each reply is compared byte for byte with the one
# the shell builds on its own (sha256 of the whole line), so a byte lost or doubled
# anywhere -- in the escaping, at a move between buffers -- shows.  The payload contains a
# quote and a backslash every 16 bytes, so both escaping paths run at size.
#
# The probe tool reports the mappings the library holds, the process's VmSize from
# /proc/self/status, and (mincore) the resident pages of the mapping tool results are
# written into -- the last two counted by the kernel, not by the library.  After the large
# calls and 200 small ones all three must be back where they started, or memory leaked.
. "$ROOT/tests/helpers.sh"

compile "$ROOT/tests/lib/progs/mcpbig.wz" "$T/mcpbig"

MB=1048576

# the payload: n bytes of 0123456789abcd"\ repeated
pat() { yes '0123456789abcd"\' | tr -d '\n' | head -c "$1"; }
# escape stdin (one line, no newline) as the inside of a JSON string
esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }

call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }
digest() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"digest","arguments":{"payload":"' "$1"; pat "$2" | esc; printf '"}}}\n'; }

# sha256 of the exact reply to blob(n) with id
blob_expect() {
  { printf '{"data":"'; pat "$2" | esc; printf '"}'; } > "$T/j"
  { printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"' "$1"
    esc < "$T/j"
    printf '"}],"structuredContent":'; cat "$T/j"; printf ',"isError":false}}'; } | sha256sum | cut -c1-64
}
line() { sed -n "$2p" "$1" | tr -d '\n'; }                        # by line number
reply() { grep "^{\"jsonrpc\":\"2.0\",\"id\":$2," "$1" | tr -d '\n'; }  # by id
replyshort() { reply "$1" "$2" | head -c 400; }
probe_of() { reply "$1" "$2" | sed 's/.*"structuredContent":\({[^}]*}\).*/\1/'; }

# ---- 1. default limits: 10 and 40 MB each way, then 200 small calls -------------------
{
  call 0 digest '{"payload":"abc"}'        # first a small call, so the probe sees what
  call 1 probe '{}'                         # a small call leaves behind
  digest 2 $((10 * MB))
  digest 3 $((40 * MB))
  call 4 blob "{\"size\":$((10 * MB))}"
  call 5 blob "{\"size\":$((40 * MB))}"
  i=0; while [ $i -lt 200 ]; do call $((100 + i)) digest '{"payload":"abc"}'; i=$((i + 1)); done
  call 9 probe '{}'
} > "$T/in1"
"$T/mcpbig" < "$T/in1" > "$T/out1" 2> "$T/err1" || { echo "the server exited non-zero"; cat "$T/err1"; exit 1; }
assert_eq "one reply per request" "$(wc -l < "$T/out1" | tr -d ' ')" "207"

for spec in "2 10" "3 40"; do
  set -- $spec
  want=$(pat $(($2 * MB)) | sha256sum | cut -c1-64)
  got=$(replyshort "$T/out1" "$1")
  assert_contains "digest of $2 MB: length" "$got" "\"bytes\":$(($2 * MB)),"
  assert_contains "digest of $2 MB: sha256" "$got" "\"sha256\":\"$want\""
done
for spec in "4 4 10" "5 5 40"; do
  set -- $spec
  assert_eq "blob of $3 MB: the whole reply, byte for byte" \
    "$(reply "$T/out1" "$1" | sha256sum | cut -c1-64)" "$(blob_expect "$2" $(($3 * MB)))"
done
assert_contains "small calls after the large ones still answer" "$(reply "$T/out1" 299)" '"bytes":3,'
first=$(probe_of "$T/out1" 1); last=$(probe_of "$T/out1" 9)
assert_contains "the probe answered" "$first" '"vmsize":'
assert_eq "no memory left behind (library count, VmSize, resident result pages)" "$last" "$first"
echo "10/40 MB in and out, byte-exact; after 200 small calls: $last"

# ---- 2. lowered limits: 8 MB request, 20 MB reply, 8 MB result -------------------------
{
  digest 10 $((9 * MB))                     # over maxin: dropped, answered with id null
  call 11 probe '{}'                        # and the next line is a request again
  call 12 blob "{\"size\":$((9 * MB))}"      # result over tool.maxout
  call 13 blob "{\"size\":$((7 * MB))}"      # fits all three
  call 14 probe '{}'
} > "$T/in2"
"$T/mcpbig" $((8 * MB)) $((20 * MB)) $((8 * MB)) < "$T/in2" > "$T/out2" 2> "$T/err2" \
  || { echo "the server exited non-zero"; cat "$T/err2"; exit 1; }
assert_eq "one reply per request, the dropped line included once" "$(wc -l < "$T/out2" | tr -d ' ')" "5"
assert_eq "an over-long request is a JSON-RPC error that names the limit" "$(line "$T/out2" 1)" \
  '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"the request is larger than the maximum of 8388608 bytes","data":{"limit":8388608}}}'
assert_contains "the server reads on after it" "$(replyshort "$T/out2" 11)" '"id":11,"result"'
assert_eq "a result over tool.maxout is a JSON-RPC error with the caller's id" "$(line "$T/out2" 3)" \
  '{"jsonrpc":"2.0","id":12,"error":{"code":-32603,"message":"the tool result is larger than the maximum of 8388608 bytes","data":{"limit":8388608}}}'
assert_eq "blob of 7 MB under lowered limits: whole reply" \
  "$(line "$T/out2" 4 | sha256sum | cut -c1-64)" "$(blob_expect 13 $((7 * MB)))"
assert_eq "no mapping left behind after the refusals" "$(probe_of "$T/out2" 14)" "$(probe_of "$T/out2" 11)"

# ---- 3. a reply over mcp.maxout -------------------------------------------------------
{
  call 20 blob "{\"size\":$((7 * MB))}"     # a 7.9 MB result is an 18 MB reply
  call 21 probe '{}'
} > "$T/in3"
"$T/mcpbig" 0 $((12 * MB)) 0 < "$T/in3" > "$T/out3" 2> "$T/err3" \
  || { echo "the server exited non-zero"; cat "$T/err3"; exit 1; }
assert_eq "a reply over mcp.maxout is a JSON-RPC error with the caller's id" "$(line "$T/out3" 1)" \
  '{"jsonrpc":"2.0","id":20,"error":{"code":-32603,"message":"the reply is larger than the maximum of 12582912 bytes","data":{"limit":12582912}}}'
assert_contains "and the reply mapping went back" "$(probe_of "$T/out3" 21)" '"mapped":1,'

echo "over each limit: one JSON-RPC error naming it, and the server answers the next call"

# ---- 4. and the limits cost no static memory -------------------------------------------
# The declared memory of the smallest stdio MCP server (the ELF LOAD segment's MemSiz: this
# compiler emits no section headers for `size` to read) was 10.1 MB before messages could
# be 64 MB -- mcp.in and mcp.buf of 4 MB, tool.out and tool.vbuf of 1 MB.  A 64 MB static
# buffer would add 64 MB here; the ceiling leaves room for code, not for that.
cat > "$T/min.wz" <<'WZ'
include "json.wz";
type AddArgs = schema
  a: int;
  b: int;
end;
type AddResult = schema
  sum: int;
end;
tools
  add(AddArgs): AddResult "Add two whole numbers.";
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
compile "$T/min.wz" "$T/min"
memsz=$(printf '%d' "$(readelf -lW "$T/min" | awk '/LOAD/{print $6}')")
[ "$memsz" -gt 0 ] || { echo "could not read the LOAD segment of the minimal server"; exit 1; }
if [ "$memsz" -gt $((11 * MB)) ]; then
  echo "the smallest MCP server declares $memsz bytes of memory, more than 11 MB:"
  echo "  a buffer for large messages belongs in a mapping made when one arrives, not in bss"
  exit 1
fi
echo "static memory of the smallest MCP server: $memsz bytes"
