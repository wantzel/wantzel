# lib/http.wz: when every slot is taken the server degrades in a way a client can see, and
# recovers the moment room comes back.
#   - every slot busy with a request: a new connection gets 503 with Retry-After, not a hang;
#   - every slot held by a QUIET connection (between requests, or nothing sent yet): one of
#     them is closed to make room, and the new request is served;
#   - every shared input chunk borrowed by a large request in progress: another large request
#     gets 503; a small one is still served.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(( 29800 + ($$ % 900) ))
port2=$((port + 900))
ulimit -Sn 4096 2>/dev/null

compile "$ROOT/tests/helpers/httpstat.wz" "$T/srv"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

"$T/srv" "$port" 20 0 5 0 0 >"$T/server.log" 2>&1 &        # at most 20 connections
pid=$!
"$T/srv" "$port2" 0 0 0 0 0 >"$T/server2.log" 2>&1 &
pid2=$!
holder=""
cleanup() { [ -n "$holder" ] && kill "$holder" 2>/dev/null; kill "$pid" "$pid2" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

for p in "$port" "$port2"; do
  ready=0
  for _ in $(seq 50); do
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then ready=1; break; fi
    sleep 0.1
  done
  [ $ready -eq 1 ] || { echo "a server did not come up on port $p"; cat "$T/server.log" "$T/server2.log"; exit 1; }
done

stat() { curl -s -m 5 "http://127.0.0.1:$1/stats" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
held() { for _ in $(seq 50); do grep -q held= "$T/hold.out" && return 0; sleep 0.1; done; echo "the holder did not start"; cat "$T/hold.out"; exit 1; }

# ---- 20 connections, each in the middle of a request line: nothing to evict
"$T/load" hold "$port" 20 1 >"$T/hold.out" 2>&1 &
holder=$!
held
sleep 0.3
code=$(curl -s -m 5 -D "$T/hdr" -o "$T/body" -w '%{http_code}' "http://127.0.0.1:$port/")
assert_eq "a connection beyond the limit gets 503" "$code" "503"
assert_contains "and a reason" "$(cat "$T/body")" "server at capacity"
assert_contains "and when to come back" "$(cat "$T/hdr")" "Retry-After: 1"

# ---- the busy clients leave: the next request is served at once
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
ok=0
for _ in $(seq 20); do
  if [ "$(curl -s -m 2 "http://127.0.0.1:$port/")" = "ok" ]; then ok=1; break; fi
  sleep 0.1
done
[ $ok -eq 1 ] || { echo "the server did not recover after the busy connections left"; exit 1; }
assert_eq "the 503 was counted" "$(stat "$port" refused)" "1"

# ---- 20 QUIET connections: one is closed to make room, the request is served
"$T/load" hold "$port" 20 0 >"$T/hold.out" 2>&1 &
holder=$!
held
sleep 0.3
body=$(curl -s -m 5 "http://127.0.0.1:$port/")
assert_eq "with every slot held by a quiet connection, a new request is still served" "$body" "ok"
ev=$(stat "$port" evicted)
[ "$ev" -ge 1 ] || { echo "no quiet connection was closed to make room (evicted=$ev)"; exit 1; }
assert_eq "no 503 when a quiet connection could make room" "$(stat "$port" refused)" "1"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""

# ---- every shared input chunk borrowed by a large request in progress
chunks=$(stat "$port2" chunkmax)
assert_eq "all chunks free at the start" "$(stat "$port2" chunks)" "$chunks"
"$T/load" bigpart "$port2" "$chunks" >"$T/hold.out" 2>&1 &
holder=$!
held
for _ in $(seq 50); do [ "$(stat "$port2" chunks)" = "0" ] && break; sleep 0.1; done
assert_eq "$chunks large requests in progress hold every chunk" "$(stat "$port2" chunks)" "0"
head -c 100000 /dev/zero > "$T/b100k"
code=$(curl -s -m 5 -o "$T/body" -w '%{http_code}' --data-binary "@$T/b100k" "http://127.0.0.1:$port2/x")
assert_eq "one more large request gets 503" "$code" "503"
assert_eq "a small request is still served" "$(curl -s -m 5 "http://127.0.0.1:$port2/")" "ok"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
for _ in $(seq 50); do [ "$(stat "$port2" chunks)" = "$chunks" ] && break; sleep 0.1; done
assert_eq "the chunks come back when those clients leave" "$(stat "$port2" chunks)" "$chunks"
body=$(curl -s -m 5 --data-binary "@$T/b100k" "http://127.0.0.1:$port2/x")
assert_eq "and the large request is served again" "$body" "got 100000"

echo "full slots answer 503 or make room from a quiet connection, full chunks answer 503, and both recover"
