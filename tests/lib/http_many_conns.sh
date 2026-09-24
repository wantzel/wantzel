# lib/http.wz: more than a thousand connections open at once are all served -- fds far past
# 256, where the server used to close a connection on sight -- and the server raises its own
# open-file limit to get there when it is started with the usual soft limit of 1024.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
#
# The connections come from one client process (tests/helpers/httpload.wz), which opens them
# ALL before it sends a single request, so the server has to hold every one of them at the
# same moment to answer the last.
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

N=1100
port=$(( 28000 + ($$ % 900) ))

# The client holds N descriptors of its own.
ulimit -Sn 4096 2>/dev/null
have=$(ulimit -Sn)
if [ "$have" != "unlimited" ] && [ "$have" -lt 1200 ]; then
  echo "this machine allows $have open files per process; the test needs 1200 for its client"
  exit 1
fi

compile "$ROOT/tests/helpers/httpstat.wz" "$T/srv"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

# Started with a soft limit of 1024, as a service usually is: 1100 connections only fit if
# http.serve raises it itself.
( ulimit -Sn 1024; exec "$T/srv" "$port" 0 0 0 0 0 ) >"$T/server.log" 2>&1 &
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

soft=$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits")
echo "server soft limit on open files after start: $soft (started with 1024)"
if [ "$soft" != "unlimited" ] && [ "$soft" -le 1024 ]; then
  echo "http.serve did not raise the soft limit on open files"
  exit 1
fi

stat() { curl -s -m 5 "http://127.0.0.1:$port/stats" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

# ---- N quiet connections held open, and a request from outside still gets through
"$T/load" hold "$port" $N 0 >"$T/hold.out" 2>&1 &
holder=$!
for _ in $(seq 200); do grep -q held= "$T/hold.out" && break; sleep 0.1; done
grep -q "held=$N" "$T/hold.out" || { echo "the client could not open $N connections"; cat "$T/hold.out"; exit 1; }
body=$(curl -s -m 5 "http://127.0.0.1:$port/")
assert_eq "with $N connections open, another request is still served" "$body" "ok"
open=$(stat open)
echo "open connections seen by the server while $N are held: $open"
[ "$open" -gt $N ] || { echo "the server holds $open connections, expected more than $N"; exit 1; }
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""

# ---- N connections open at once, then one request on each: every one is answered
out=$("$T/load" open "$port" $N)
echo "$out"
assert_eq "all $N simultaneous connections are answered" "$out" "opened=$N served=$N closed=0"
maxfd=$(stat maxfd)
echo "highest fd a request was answered on: $maxfd"
[ "$maxfd" -gt 1000 ] || { echo "no request was answered on an fd above 1000 (highest: $maxfd)"; exit 1; }

# ---- and every slot comes back once the clients are gone
for _ in $(seq 50); do [ "$(stat open)" = "1" ] && break; sleep 0.1; done
assert_eq "all slots are free again after the clients left (only /stats itself is open)" "$(stat open)" "1"

echo "$N connections at once are all served, on fds up to $maxfd, with the open-file limit raised from 1024 to $soft"
