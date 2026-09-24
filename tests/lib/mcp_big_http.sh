# MCP over HTTP: a request of megabytes reaches the tool whole, one over mcp.maxin is a
# JSON-RPC error with the caller's id, a reply of megabytes goes out whole within
# http.maxreply, and one larger than that is a JSON-RPC error too -- never the plain-text
# 500 an MCP client cannot read.
#
# TOETSGROEP: lib
# DEKT: lib/mcphttp.wz lib/mcp.wz lib/tools.wz
#
# A body larger than the HTTP input buffer lands in a region of its connection's
# (http.maxbody), not in http.inbuf; before mcp.http looked there, such a request was parsed
# from the wrong buffer. The server allows replies up to 4 MB (http.maxreply).
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }
compile "$ROOT/tests/lib/progs/mcpbig.wz" "$T/mcpbig"

MB=1048576
port=$(( 23000 + ($$ % 900) ))

pat() { yes '0123456789abcd"\' | tr -d '\n' | head -c "$1"; }
esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }
digest() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"digest","arguments":{"payload":"' "$1"; pat "$2" | esc; printf '"}}}'; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
blob_expect() {
  { printf '{"data":"'; pat "$2" | esc; printf '"}'; } > "$T/j"
  { printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"' "$1"
    esc < "$T/j"
    printf '"}],"structuredContent":'; cat "$T/j"; printf ',"isError":false}}'; } | sha256sum | cut -c1-64
}
post() {   # post <body file> <reply file>: prints the status
  curl -s --max-time 60 -o "$2" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary @"$1" "http://127.0.0.1:$port/mcp"
}
probe_of() { sed 's/.*"structuredContent":\({[^}]*}\).*/\1/' "$1"; }

# a 12 MB request limit; results and replies at their defaults
"$T/mcpbig" $((12 * MB)) 0 0 "$port" > "$T/server.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT

call 1 probe '{}' > "$T/probe.json"
ready=0
for _ in $(seq 50); do
  if [ "$(post "$T/probe.json" "$T/r0" 2>/dev/null)" = 200 ]; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

# ---- 10 MB in: the body is in the http.maxbody region --------------------------------
digest 2 $((10 * MB)) > "$T/d10"
assert_eq "a 10 MB request is answered" "$(post "$T/d10" "$T/r1")" 200
want=$(pat $((10 * MB)) | sha256sum | cut -c1-64)
assert_contains "the tool saw every byte" "$(cat "$T/r1")" "\"bytes\":$((10 * MB)),\"sha256\":\"$want\""

# ---- over mcp.maxin: the error carries the id ----------------------------------------
digest 3 $((11 * MB)) > "$T/d11"
assert_eq "an over-long request is still answered with 200" "$(post "$T/d11" "$T/r2")" 200
assert_eq "as a JSON-RPC error with the caller's id" "$(cat "$T/r2")" \
  '{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"the request is larger than the maximum of 12582912 bytes","data":{"limit":12582912}}}'

# ---- a reply of about 2.5 MB goes out whole --------------------------------------------
call 4 blob "{\"size\":$MB}" > "$T/b1"
assert_eq "a large reply is answered with 200" "$(post "$T/b1" "$T/r3")" 200
assert_eq "the whole reply, byte for byte" "$(sha256sum < "$T/r3" | cut -c1-64)" "$(blob_expect 4 "$MB")"

# ---- one of about 5 MB is past http.maxreply: a JSON-RPC error that says why -------------
call 5 blob "{\"size\":$((2 * MB))}" > "$T/b2"
assert_eq "a reply past http.maxreply is answered with 200" "$(post "$T/b2" "$T/r5")" 200
assert_contains "as a JSON-RPC error naming the limit" "$(head -c 300 "$T/r5")" \
  '{"jsonrpc":"2.0","id":5,"error":{"code":-32603,"message":"the reply is larger than the maximum of '

# ---- and the next call finds everything given back -----------------------------------
assert_eq "the server still answers" "$(post "$T/probe.json" "$T/r4")" 200
assert_eq "no mapping left behind" "$(probe_of "$T/r4")" "$(probe_of "$T/r0")"
echo "over HTTP: 10 MB request and 2.5 MB reply whole, over-limit request and reply answered as JSON-RPC errors"
