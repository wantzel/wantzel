# lib/http.wz: a reply that does not fit in OUTBUF (512 kB) gets a clean 500, not a
# runtime array-bounds crash that takes the whole worker (and every OTHER connection it
# was serving) down with it.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
#
# http.addc and http.addb used to write http.outbuf[http.wpos] directly with no check.
# Every array write in this language is bounds-checked at run time (docs/language.md §"Not
# checked" / the safety section), so a handler that overran OUTBUF did not corrupt memory --
# it TRAPPED, and the trap kills the process. In a forked worker serving many connections at
# once (http.serve's whole design), that is every other request in flight at the same
# moment, for a mistake in one handler.
#
# The fix does not raise OUTBUF (that repeats INBUF's own problem in the other direction:
# one buffer times MAXCONN). It catches the overflow before the write and turns http.finish
# into a clean 500 with a short message instead of a lie about Content-Length.
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(free_port)

cat > "$T/outsrv.wz" <<EOF
include "http.wz";
var big: array[0..699999] of char;   // 700000 > OUTBUF (524288), on purpose
procedure app.request;
var i: int;
begin
  if http.pathis("/toobig") then
  begin
    for i := 0 to 699999 do big[i] := 'y';
    http.addb(big, 0, 700000);
    http.finish(200, "text/plain");
    return;
  end;
  http.add("fine");
  http.finish(200, "text/plain");
end;
begin
  http.serve($port, 1);
end.
EOF
compile "$T/outsrv.wz" "$T/outsrv"

"$T/outsrv" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

code=$(curl -s -o "$T/toobig_out" -w '%{http_code}' "http://127.0.0.1:$port/toobig")
assert_eq "a reply bigger than OUTBUF gets a clean 500, not a dropped connection" "$code" "500"
assert_contains "the 500 body says why" "$(cat "$T/toobig_out")" "did not fit"

# The worker must survive: a plain request right after is still served, which is the
# entire point -- one handler's mistake must not have taken the process down.
body=$(curl -s "http://127.0.0.1:$port/ok")
assert_eq "the worker survives and serves the next request" "$body" "fine"

echo "a reply larger than OUTBUF gets a clean 500 instead of crashing the worker"
