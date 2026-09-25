# lib/http.wz: a client that is refused -- 413 (body too large), 431 (headers
# too large), 408 (headers too slow) -- reliably reads the status, never a bare reset.
#
# Closing a socket with unread input still sitting in its receive buffer makes the kernel
# answer with RST instead of the normal FIN, and a client that has not read the reply yet
# then sees the connection die with no status at all -- indistinguishable from a crash.
# http.refuse now half-closes (shutdown SHUT_WR) and lingers, draining what the client still
# sends (http.linger/http.swallow), before closing outright.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
#
# WHAT IS ESTABLISHED, each read directly off the socket by tests/helpers/httpload.wz's
# `refuse` mode -- not through curl, whose retries and buffering can hide a reset that
# arrived after the useful bytes were already delivered to it:
#   1. a body past what the server accepts (no http.maxbody: INBUF, 256 kB) gets 413, and the
#      client -- still writing more body it has not been told to stop sending -- reads it
#      without the connection resetting out from under it
#   2. a request whose headers alone fill the slot's input and never end gets 431, the same
#      way
#   3. a request whose headers never arrive within the header deadline gets 408
#   4. the connection under all three ends in a clean EOF, not an error -- net.recv's -104
#      (ECONNRESET) or a failed send with -32 (EPIPE) would both show up as reset=1
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

compile "$ROOT/tests/helpers/httpstat.wz" "$T/srv"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

port=$(free_port)
# maxconn 0 (default), idle 0 (default), header deadline 2s -- short, so the 408 case does
# not make this test slow -- body and send deadlines 0 (default)
"$T/srv" "$port" 0 0 2 0 0 >"$T/server.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/"; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

one() {   # one <kind> <label>
  out=$("$T/load" refuse "$port" "$1")
  echo "  $1: $out"
  case "$out" in
    *"status=$1"*"reset=0"*) ;;
    *) echo "FAIL  $2"; echo "  got: $out"; exit 1 ;;
  esac
}

one 413 "an oversized body gets 413 with no reset"
one 431 "headers that never end get 431 with no reset"
one 408 "headers that never arrive get 408 with no reset"

echo "413, 431 and 408 are all read cleanly, never as a bare connection reset"
