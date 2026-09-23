# examples/httpd.wz answers a request bigger than INBUF (256 kB) with a clean 413,
# not a bare connection reset.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
#
# Found 23-09-2026: a body of about 2.1 MB (and one of 400 kB) got 'connection reset' with
# no status code -- the client had no way to tell that apart from a crash. http.readable
# used to answer a full INBUF with a bare http.drop whatever the reason; now it answers
# with 413 once the headers are known and the body will not fit, and only falls through to
# a reset-equivalent drop when even the HEADERS do not fit, which is a different and
# genuinely malformed request.
#
# httpd.wz has no http.maxbody call, so this exercises the plain case: no overflow region
# configured at all, every oversized body gets 413.  tests/lib/http_bigbody.sh covers the
# configured case.
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(( 21000 + ($$ % 900) ))
compile "$ROOT/examples/httpd.wz" "$T/httpd"
sed "s/http.serve(8080, 8)/http.serve($port, 2)/" "$ROOT/examples/httpd.wz" > "$T/httpd_t.wz"
compile "$T/httpd_t.wz" "$T/httpd_t"

"$T/httpd_t" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

# A body bigger than INBUF (256 kB): about 2.1 MB, a deterministic payload instead of real
# JSON -- the size is what matters here, not the shape.
dd if=/dev/zero of="$T/big.bin" bs=1024 count=2148 status=none

code=$(curl -s -o "$T/big_body_out" -w '%{http_code}' -X POST --data-binary "@$T/big.bin" "http://127.0.0.1:$port/big")
assert_eq "an oversized body gets 413, not a reset" "$code" "413"
assert_contains "the 413 body says why" "$(cat "$T/big_body_out")" "too large"

# A smaller but still-oversized body (400 kB): still bigger than INBUF, still answered,
# not reset.
dd if=/dev/zero of="$T/mid.bin" bs=1024 count=400 status=none
code2=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary "@$T/mid.bin" "http://127.0.0.1:$port/mid")
assert_eq "a 400 kB body also gets 413" "$code2" "413"

# The connection this closed on must not have wedged the worker: a plain request right
# after is still served normally.
body=$(curl -s "http://127.0.0.1:$port/after")
assert_contains "the server still serves after a 413" "$body" "path: /after"

echo "a request larger than INBUF gets 413 Payload Too Large, not a reset"
