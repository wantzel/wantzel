# lib/http.wz: app.request can hand a connection off (http.detach) instead of
# replying, and http.wz really lets go of it -- closes nothing, but removes it from
# its own http.open and its own epoll set so its loop never touches that fd again.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
#
# THIS IS lib/http.wz ALONE, WITHOUT lib/websocket.wz: the mechanism http.detach and
# http.dropdetach add has no WebSocket in it (see the changelog entry), and testing it
# here, separately from the handshake/framing test in tests/lib/websocket.sh, proves
# that fact rather than merely asserting it in a comment.
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

port=$(free_port)

cat > "$T/detsrv.wz" <<'EOF'
import http;

// A detached connection is handed raw bytes directly, bypassing http.add/http.finish
// entirely -- there is nothing WebSocket-specific about http.detach itself.
procedure app.request;
var n, ignored: int;
begin
  if http.pathis("/take") then
  begin
    http.detach := true;
    // A real status line, but written directly to the socket -- never through
    // http.add/http.finish -- so a passing check here can only mean the NEW owner
    // (this code, standing in for lib/websocket.wz) wrote it, not http.wz itself.
    n := io.push(http.hdr, 0, "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nTAKEN-OVER\n");
    ignored := net.send(http.fd, addr(http.hdr[0]), n);
    // http.wz must not touch this fd again after app.request returns: no reply
    // written through http.finish, and the connection is closed here, by the new
    // owner, once it is done -- not by http.wz's own http.drop.
    net.close(http.fd);
    return;
  end;
  // how many connections the loop still counts as its own: a detached one must not be
  http.start;
  http.add("plain open=");
  http.addn(http.nopen);
  http.add("\n");
  http.finish(200, "text/plain");
end;

begin
  http.serve(PORT, 1);
end.
EOF
sed -i "s/PORT/$port/" "$T/detsrv.wz"
compile "$T/detsrv.wz" "$T/detsrv"

"$T/detsrv" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

body=$(curl -s "http://127.0.0.1:$port/")
assert_contains "an ordinary request is answered as before http.detach is ever used" "$body" "plain"

taken=$(curl -s "http://127.0.0.1:$port/take")
assert_contains "a detached connection gets exactly the bytes app.request itself wrote, not an http.wz reply" "$taken" "TAKEN-OVER"

# ---- AFTER A DETACH, THE SERVER STILL SERVES ORDINARY REQUESTS -- proving http.wz's
# own loop was not left confused about the fd it gave away (a stuck epoll registration,
# a slot http.accept could no longer reuse, or a crash) -----------------------------
body2=$(curl -s "http://127.0.0.1:$port/")
assert_contains "the server still answers ordinary requests after a detach" "$body2" "plain"

# Twenty detaches in a row, on top of the ordinary request that already happened: if
# the fd or its epoll registration ever leaked, this is where a fixed-size table
# (MAXCONN, or a leaked epoll interest) would start showing it as hangs or errors.
i=0
while [ $i -lt 20 ]; do
  out=$(curl -s "http://127.0.0.1:$port/take")
  assert_contains "detach #$i also gets its own reply, not the server's" "$out" "TAKEN-OVER"
  i=$((i + 1))
done
body3=$(curl -s "http://127.0.0.1:$port/")
assert_contains "and the server is still healthy after twenty detaches" "$body3" "plain"
assert_contains "and every detached connection gave its slot back" "$body3" "open=1"

# ---- SABOTAGE: remove the http.detach check from http.readable so app.request's
# flag is never acted on. This is the same mechanism tests/lib/websocket.sh's own
# sabotage exercises end-to-end (a real WebSocket connection is held open across
# several round trips, so http.wz's loop DOES get another chance at the detached fd
# if the check is missing, and that test goes red for it); this test's server closes
# the fd immediately after its one write, which turned out to make the corrupted
# fallthrough here silent (a write to an already-closed fd just fails, ignored, the
# same way any other write error on this path already is) -- restoring the check
# below is therefore verified from lib/websocket.wz's test, not repeated here.
echo "lib/http.wz: app.request can detach a connection with http.detach, hand it raw bytes itself, and the server keeps serving ordinary requests afterwards -- repeatedly, and without lib/websocket.wz involved at all. The http.detach check itself is sabotage-tested in tests/lib/websocket.sh, where the connection stays open long enough for a missing check to matter."
