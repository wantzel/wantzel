# lib/http.wz: requests pipelined on one keep-alive connection are all answered, in order --
# also when the first reply is too large for the socket to take at once, so the second has
# to wait for it.  Before, every byte after the first request of a read was thrown away and a
# pipelining client waited for ever for the rest of its answers.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(( 31600 + ($$ % 900) ))

compile "$ROOT/tests/helpers/httpstat.wz" "$T/srv"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

"$T/srv" "$port" 0 0 0 0 0 >"$T/server.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

out=$("$T/load" pipe "$port" 50)
assert_eq "50 requests in one write get 50 answers" "$out" "pipelined=50 answered=50"

# 500000 bytes of body plus two sets of headers; "ok" is the second reply's body
out=$("$T/load" pipebig "$port" 1)
bytes=$(echo "$out" | sed -n 's/^bytes=\([0-9]*\).*/\1/p')
assert_contains "the request behind a queued large reply is answered after it" "$out" "last=ok"
[ "$bytes" -gt 500000 ] || { echo "only $bytes bytes arrived: the large reply was cut short"; exit 1; }

# keep-alive: 20 connections, a second of back-to-back requests, not one closed
out=$("$T/load" bench "$port" 20 1000)
echo "$out"
assert_contains "keep-alive connections stay open across requests" "$out" "conns=20"

echo "pipelined requests are answered in order, also behind a reply that had to wait"
