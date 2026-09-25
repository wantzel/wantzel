# lib/http.wz: connections that make no progress are closed by their deadline, and do not
# stop anyone else from being served meanwhile.  A slowloris client -- a request line, then a
# header byte every half second, never finishing -- is closed by the header deadline, which
# no trickle of bytes extends.  A body that stops coming is closed by the body deadline, and a
# keep-alive connection that goes quiet by the idle deadline -- after that deadline, not
# before, so keep-alive itself still works.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(free_port)
ulimit -Sn 4096 2>/dev/null

compile "$ROOT/tests/helpers/httpstat.wz" "$T/srv"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

# every deadline 2 seconds
"$T/srv" "$port" 0 2 2 2 2 >"$T/server.log" 2>&1 &
pid=$!
holder=""
cleanup() { [ -n "$holder" ] && kill "$holder" 2>/dev/null; kill "$pid" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

stat() { curl -s -m 5 "http://127.0.0.1:$port/stats" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

# ---- slowloris: 300 connections, one header byte every 500 ms, for at most 9 seconds
"$T/load" slow "$port" 300 500 9000 >"$T/slow.out" 2>&1 &
slow=$!
sleep 1
t=$(curl -s -m 3 -o "$T/body" -w '%{time_total}' "http://127.0.0.1:$port/")
assert_eq "a normal request is served while 300 slow clients are connected" "$(cat "$T/body")" "ok"
echo "normal request during the slowloris run took ${t}s"
wait "$slow"
out=$(cat "$T/slow.out")
echo "$out"
assert_contains "the server closed every slow connection" "$out" "slow=300 closed=300"
last=$(echo "$out" | sed -n 's/.*lastms=\([0-9]*\).*/\1/p')
# 2 s deadline, checked once a second: all gone within 3 s; 5 s leaves room for a busy machine
[ "$last" -le 5000 ] || { echo "the last slow connection was closed after ${last} ms, deadline 2000 ms"; exit 1; }

# ---- a body that stops coming: 20 connections send 10 of 100 announced bytes
"$T/load" hold "$port" 20 2 >"$T/hold.out" 2>&1 &
holder=$!
for _ in $(seq 50); do grep -q held= "$T/hold.out" && break; sleep 0.1; done
before=$(stat timedout)
gone=0
for _ in $(seq 60); do
  sleep 0.1
  if [ "$(stat open)" = "1" ]; then gone=1; break; fi
done
[ $gone -eq 1 ] || { echo "connections with a stalled body are still open after 6 s: $(stat open)"; exit 1; }
after=$(stat timedout)
[ $((after - before)) -ge 20 ] || { echo "expected 20 more deadline closes, counted $((after - before))"; exit 1; }
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""

# ---- idle keep-alive: one request each, then quiet; closed after the idle deadline
out=$("$T/load" idle "$port" 50 8000)
echo "$out"
assert_contains "every keep-alive connection is answered, then closed when idle" "$out" "idle=50 served=50 closed=50"
last=$(echo "$out" | sed -n 's/.*lastms=\([0-9]*\).*/\1/p')
[ "$last" -ge 1500 ] || { echo "idle connections were closed after ${last} ms: sooner than the 2 s deadline, so keep-alive is broken"; exit 1; }
[ "$last" -le 5000 ] || { echo "idle connections were closed only after ${last} ms, deadline 2000 ms"; exit 1; }

assert_eq "no slot is left behind" "$(stat open)" "1"
echo "slow headers, a stalled body and idle keep-alive are each closed by their deadline, and others are served meanwhile"
