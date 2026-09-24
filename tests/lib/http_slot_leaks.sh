# lib/http.wz: every way a connection can end gives back everything it held.  After some
# thousands of connections ending in every way the loop knows -- answered and closed,
# closed without a request, closed mid-request, closed while a large request held a shared
# chunk, closed while a queued reply waited for the socket, refused with 413 -- the server
# holds exactly what it held before: no slot, no chunk, no reply region, no descriptor.
#
# COUNTED, NOT INFERRED: /stats reads the loop's own free lists, and /proc gives the fds.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(( 30700 + ($$ % 900) ))
ulimit -Sn 4096 2>/dev/null

compile "$ROOT/tests/helpers/httpstat.wz" "$T/srv"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

"$T/srv" "$port" 0 0 0 0 0 >"$T/server.log" 2>&1 &
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

state() { curl -s -m 5 "http://127.0.0.1:$port/stats" | tr ' ' '\n' | grep -E '^(open|free|chunks|pend)='; }
fds() { ls "/proc/$pid/fd" | wc -l; }
held() { for _ in $(seq 50); do grep -q = "$T/hold.out" && return 0; sleep 0.1; done; echo "the client did not start"; cat "$T/hold.out"; exit 1; }
settle() { for _ in $(seq 50); do [ "$(state)" = "$start" ] && return 0; sleep 0.1; done; }

start=$(state)
fd0=$(fds)
echo "at the start: $(echo $start) fds=$fd0"

# answered and closed / closed with nothing sent / closed halfway through a body
out=$("$T/load" cycle "$port" 600)
assert_eq "every full request in the cycles is answered" "$out" "cycles=600 served=600"

# closed while a large request in progress held a shared chunk
"$T/load" bigpart "$port" 30 >"$T/hold.out" 2>&1 &
holder=$!
held
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""

# closed while a queued reply waited for the socket
"$T/load" stall "$port" 30 >"$T/hold.out" 2>&1 &
holder=$!
held
queued=$(curl -s -m 5 "http://127.0.0.1:$port/stats" | tr ' ' '\n' | sed -n 's/^pend=//p')
[ "$queued" -gt 0 ] || { echo "the stalled replies were never queued (pend=$queued): this part tests nothing"; exit 1; }
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""

# refused: a body larger than INBUF with no http.maxbody
head -c 400000 /dev/zero > "$T/b400k"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' --data-binary "@$T/b400k" "http://127.0.0.1:$port/x")
assert_eq "a body over INBUF is refused with 413" "$code" "413"

# and a queued reply that WAS read to the end
size=$(curl -s -m 10 "http://127.0.0.1:$port/bigslow" | wc -c)
assert_eq "a queued reply arrives whole" "$size" "500000"

settle
assert_eq "slots, chunks and reply regions are all back" "$(state)" "$start"
assert_eq "no descriptor is left open" "$(fds)" "$fd0"
echo "after 1800 cycled connections and every way of ending: $(echo $(state)) fds=$(fds)"
