# examples/httpd.wz really answers HTTP.
#
# This is the one example that proves the event loop works, and until 13-09-2026
# nothing ran it -- so "the server still serves" rested on the fact that it compiled.
# It does not need anything the other network examples need: no client library, no
# protocol handshake, just a socket on loopback, which docs/testing.md allows.
#
# The port comes from $$ so two runs of the suite cannot collide, and a trap kills the
# server whatever happens -- a leftover process listening on a port is exactly the kind
# of thing that makes the NEXT run fail for no visible reason.
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(( 20000 + ($$ % 20000) ))
compile "$ROOT/examples/httpd.wz" "$T/httpd"

# httpd.wz has the port compiled in, so serve on it by rewriting the source: the example
# is the thing under test and must not be changed to suit the test.
sed "s/http.serve(8080, 8)/http.serve($port, 2)/" "$ROOT/examples/httpd.wz" > "$T/httpd_t.wz"
compile "$T/httpd_t.wz" "$T/httpd_t"

"$T/httpd_t" >"$T/server.log" 2>&1 &
pid=$!
# http.serve forks workers, so killing the parent alone leaves them holding the socket
# and the next run of the suite finds the port busy. Kill the children first, by parent
# pid, then the parent -- never a process group, which could reach beyond this test.
cleanup() { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

# Wait for the socket instead of sleeping a fixed time: a fixed sleep is either slow or
# flaky, and on a loaded machine it is both.
ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

body=$(curl -s "http://127.0.0.1:$port/hello")
assert_contains "GET is answered"        "$body" "hello from wantzel"
assert_contains "the path is echoed"     "$body" "path: /hello"
assert_contains "requests are counted"   "$body" "request number:"

# The counter is per-worker, so the number itself is not fixed -- but a second request
# must still be answered, which is what the loop is for.
body2=$(curl -s "http://127.0.0.1:$port/second")
assert_contains "a second request is served" "$body2" "path: /second"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/")
assert_eq "POST is refused with 405" "$code" "405"

echo "httpd.wz serves GET, echoes the path, counts, and refuses POST"
