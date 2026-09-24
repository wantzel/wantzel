# lib/websocket.wz: a WebSocket server (RFC 6455) that TAKES OVER a connection from
# lib/http.wz, on the SAME listening port -- handshake, text frames both ways, a
# server push with no request behind it, ping/pong, and a close that carries a code.
# The server under test also answers plain HTTP GET on the same port, which is the
# whole point of this design (DEC-0000-0106): one port, one origin, one cookie.
#
# TOETSGROEP: lib
# DEKT: lib/websocket.wz lib/http.wz
#
# THE CLIENT SPEAKS RAW FRAMES ITSELF rather than through lib/websocket.wz, because that
# library is written for the SERVER side (it never masks its own frames and always
# expects a masked one from its peer) -- a client using the same module would not be
# testing anything a real browser does differently. So the test client below builds its
# own handshake and masks its own frames by hand, the way a browser's WebSocket
# implementation does.
. "$ROOT/tests/helpers.sh"

port=$(( 23000 + ($$ % 900) ))

cat > "$T/wssrv.wz" <<'EOF'
include "websocket.wz";

// ECHO: whatever text comes in goes straight back out, so the client can tell its own
// frame was received and reassembled correctly.
procedure app.wsframe(fd: int);
var base: int;
begin
  base := fd * WS.INMAX;
  ws.ignored := ws.sendtext(fd, ws.in[base + ws.at .. base + ws.at + ws.len - 1], ws.len);
end;

procedure app.wsclose(fd: int);
begin
end;

// ONE HANDLER, BOTH PROTOCOLS: app.request is the same required hook an ordinary
// http.wz program already defines. A request to /ws with an Upgrade header sets
// http.detach and hands the fd to ws.take; anything else is answered as plain HTTP,
// proving the two share one port without stepping on each other.
procedure app.request;
var ok: bool;
begin
  if http.pathis("/ws") then
  begin
    if http.header("upgrade") then
    begin
      http.detach := true;
      ok := ws.take(http.fd);
      if not ok then
      begin
        // ws.take already failed to answer (bad/missing key): the fd was never
        // added to ws.open, so it is still this program's to close.
        http.detach := false;
        net.close(http.fd);
      end
      else
        // A PUSH WITH NOTHING FROM THE CLIENT BEHIND IT: proves the server can
        // write to a just-upgraded connection outside of answering a frame, which
        // is the whole point of a WebSocket over long-polling.
        ws.ignored := ws.sendtext(http.fd, "welcome", 7);
      return;
    end;
    http.start;
    http.add("no upgrade requested\n");
    http.finish(400, "text/plain");
    return;
  end;
  http.start;
  http.add("hello from wantzel\n");
  http.finish(200, "text/plain");
end;

// THE SERVER'S OWN LOOP, NOT http.serve -- the shape docs/library.md documents:
// http.serve never returns and so never gives the application a place to also drive
// ws.poll, so a program that wants both protocols binds with http.listen and then calls
// http.poll and ws.poll on every wake.
procedure runloop(port: int);
var n: int;
begin
  http.listen(port, 1);
  while true do
  begin
    n := http.poll(50);
    // ws.poll(0) does not block: any WebSocket activity found on http's wake above
    // already has fresh data waiting, and a 50ms wake is frequent enough that a push
    // queued between wakes is never held up noticeably.
    n := ws.poll(0);
  end;
end;

begin
  runloop(PORT);
end.
EOF
sed -i "s/PORT/$port/" "$T/wssrv.wz"
compile "$T/wssrv.wz" "$T/wssrv"

# ---- the test client: raw frames, masked by hand, exactly like a browser ---------------------
cat > "$T/wscli.wz" <<'EOF'
include "io.wz";
include "net.wz";
include "base64.wz";

const KEYB64LEN = 24;

var
  fd: int;
  n, i: int;
  buf: array[0..8191] of char;
  hdrbuf: array[0..1023] of char;
  req: array[0..1023] of char;
  nonce: array[0..15] of char;
  keyb64: array[0..31] of char;

function argnum(k: int): int;
var j, v: int;
    c: char;
begin
  v := 0; j := 0; c := argch(k, j);
  while (c >= '0') and (c <= '9') do
  begin v := v * 10 + (ord(c) - ord('0')); j := j + 1; c := argch(k, j); end;
  return v;
end;

// Read exactly `want` bytes into buf[0..want-1], across as many recv calls as it takes
// -- a TCP stream owes nothing about how the bytes were grouped in flight.
function fillbuf(want: int): bool;
var got, r: int;
begin
  got := 0;
  while got < want do
  begin
    r := net.recv(fd, addr(buf[got]), want - got);
    if r <= 0 then return false;
    got := got + r;
  end;
  return true;
end;

// Send a masked frame (as a real client must) carrying a[0..n-1] as opcode.
procedure sendframe(opcode: int; a: array of char; n: int; mk0: int; mk1: int; mk2: int; mk3: int);
var out: array[0..131] of char;
    hn, i, mv: int;
begin
  out[0] := chr(128 + opcode);
  out[1] := chr(128 + n);              // MASK bit set, n < 126 always in this test
  out[2] := chr(mk0); out[3] := chr(mk1); out[4] := chr(mk2); out[5] := chr(mk3);
  hn := 6;
  i := 0;
  while i < n do
  begin
    if i mod 4 = 0 then mv := mk0
    else if i mod 4 = 1 then mv := mk1
    else if i mod 4 = 2 then mv := mk2
    else mv := mk3;
    out[hn + i] := chr(bxor(ord(a[i]), mv));
    i := i + 1;
  end;
  n := net.send(fd, addr(out[0]), hn + n);
end;

begin
  fd := net.connect(127, 0, 0, 1, argnum(1));
  if fd < 0 then begin io.puts(STDERR, "connect failed\n"); halt(1); end;

  // A fixed 16-byte nonce is enough: RFC 6455 does not require cryptographic randomness
  // from the CLIENT's key, only that the server echo back the right hash of it, and a
  // fixed value makes this test's expected output fixed too.
  i := 0;
  while i < 16 do begin nonce[i] := chr(65 + i); i := i + 1; end;
  n := base64.encode(keyb64, 0, nonce[0..15]);

  n := io.push(req, 0, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
  i := 0;
  while i < KEYB64LEN do begin req[n] := keyb64[i]; n := n + 1; i := i + 1; end;
  n := io.push(req, n, "\r\nSec-WebSocket-Version: 13\r\n\r\n");
  if net.send(fd, addr(req[0]), n) <> n then begin io.puts(STDERR, "send failed\n"); halt(1); end;

  // The 101 response plus headers: read one byte at a time into hdrbuf and stop as soon
  // as the last four bytes seen are \r\n\r\n -- the header ends there and every frame
  // byte after it belongs to what comes next (the push below), so nothing past the
  // terminator may be read speculatively.
  n := 0;
  while true do
  begin
    i := net.recv(fd, addr(hdrbuf[n]), 1);
    if i <= 0 then begin io.puts(STDERR, "handshake read failed\n"); halt(1); end;
    n := n + 1;
    if (n >= 4) and (hdrbuf[n-4] = chr(13)) and (hdrbuf[n-3] = chr(10))
       and (hdrbuf[n-2] = chr(13)) and (hdrbuf[n-1] = chr(10)) then break;
    if n >= 1023 then begin io.puts(STDERR, "handshake header too long\n"); halt(1); end;
  end;
  io.puts(STDOUT, "HANDSHAKE-OK\n");

  // ---- 1. the server push, unprompted --------------------------------------------------------
  if not fillbuf(2) then begin io.puts(STDERR, "no push frame header\n"); halt(1); end;
  n := ord(buf[1]);
  if not fillbuf(n) then begin io.puts(STDERR, "push frame payload short\n"); halt(1); end;
  io.puts(STDOUT, "PUSH ");
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");

  // ---- 2. echo: what goes out comes back untouched -------------------------------------------
  n := io.push(req, 0, "roundtrip");
  sendframe(1, req, n, 17, 34, 51, 68);
  if not fillbuf(2) then begin io.puts(STDERR, "no echo frame header\n"); halt(1); end;
  n := ord(buf[1]);
  if not fillbuf(n) then begin io.puts(STDERR, "echo frame payload short\n"); halt(1); end;
  io.puts(STDOUT, "ECHO ");
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");

  // ---- 3. ping / pong -------------------------------------------------------------------------
  n := io.push(req, 0, "hi");
  sendframe(9, req, n, 1, 2, 3, 4);
  if not fillbuf(2) then begin io.puts(STDERR, "no pong header\n"); halt(1); end;
  io.puts(STDOUT, "PONGOP ");
  io.putn(STDOUT, band(ord(buf[0]), 15));
  io.puts(STDOUT, "\n");
  n := ord(buf[1]);
  if n > 0 then
    if not fillbuf(n) then begin io.puts(STDERR, "pong payload short\n"); halt(1); end;
  io.puts(STDOUT, "PONGBODY ");
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");

  // ---- 4. close, WITH A CODE -------------------------------------------------------------------
  n := 0;
  sendframe(8, req, n, 9, 9, 9, 9);           // empty masked close frame
  if not fillbuf(2) then begin io.puts(STDERR, "no close reply\n"); halt(1); end;
  io.puts(STDOUT, "CLOSEOP ");
  io.putn(STDOUT, band(ord(buf[0]), 15));
  io.puts(STDOUT, "\n");
  n := ord(buf[1]);
  if n >= 2 then
  begin
    if not fillbuf(n) then begin io.puts(STDERR, "close code short\n"); halt(1); end;
    io.puts(STDOUT, "CLOSECODE ");
    io.putn(STDOUT, ord(buf[0]) * 256 + ord(buf[1]));
    io.puts(STDOUT, "\n");
  end;
end.
EOF
compile "$T/wscli.wz" "$T/wscli"

# ---- run the server and drive it with the client ----------------------------------------------
"$T/wssrv" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

# ---- ONE PORT, BOTH PROTOCOLS: a plain HTTP GET works BEFORE any WebSocket has ever
# connected, proving app.request's ordinary path is untouched by the module existing. --
body=$(curl -s "http://127.0.0.1:$port/")
assert_contains "an ordinary GET on the same port is answered as plain HTTP" "$body" "hello from wantzel"

out=$("$T/wscli" "$port" 2>"$T/cli.err") || { echo "the test client failed:"; cat "$T/cli.err"; exit 1; }

assert_contains "the handshake completes with a 101" "$out" "HANDSHAKE-OK"
assert_contains "the server pushes without being asked" "$out" "PUSH welcome"
assert_contains "a text frame sent by the client is echoed back whole" "$out" "ECHO roundtrip"
assert_contains "a ping gets a pong (opcode 10)" "$out" "PONGOP 10"
assert_contains "the pong echoes the ping's own payload" "$out" "PONGBODY hi"
assert_contains "a close from the client is answered with a close" "$out" "CLOSEOP 8"
assert_contains "and the close carries a code (1000, normal closure)" "$out" "CLOSECODE 1000"

# ---- AND STILL BOTH, AFTER: an ordinary GET still works on the same port once a
# WebSocket has been opened and closed on it -- the takeover cost http.wz nothing
# permanent, only the one fd it handed off. ------------------------------------------------
body2=$(curl -s "http://127.0.0.1:$port/")
assert_contains "plain HTTP still works on the same port after a WebSocket round trip" "$body2" "hello from wantzel"

# ---- a request to /ws with no Upgrade header is answered as plain HTTP (400), not an
# upgrade -- app.request's own logic decides, this module never guesses. -------------------
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/ws")
assert_eq "a plain GET /ws with no Upgrade header gets a 400, not a silent upgrade" "$code" "400"

# ---- SABOTAGE: corrupt the byte ws.send copies into the outgoing frame's payload, and
# see the PUSH/ECHO content assertions actually fail. Proves those checks are reading
# something real rather than passing regardless of what the server sends.
#
# THE SABOTAGED SERVER NEEDS ITS OWN COMPILER BESIDE ITS OWN lib/, the same reason
# tests/lib/tls.sh does this: the compiler resolves lib/ relative to its own location, so
# copying only the sources and pointing at them does not work.
mkdir -p "$T/pg/lib" "$T/pg/bin"
cp "$ROOT"/lib/*.wz "$T/pg/lib/"
cp "$ROOT/bin/wantzel" "$T/pg/bin/"
awk '/ws\.out\[hn \+ i\] := a\[i\];/ && !done { print "    ws.out[hn + i] := chr(bxor(ord(a[i]), 1));"; done=1; next }
     { print }' "$ROOT/lib/websocket.wz" > "$T/pg/lib/websocket.wz"
if ! grep -q "bxor(ord(a\[i\]), 1)" "$T/pg/lib/websocket.wz"; then
  echo "the sabotage did not apply -- 'ws.out[hn + i] := a[i];' not found in lib/websocket.wz"
  exit 1
fi

# The good server is stopped first, freeing the port, so the sabotaged one (still
# compiled to listen on the SAME port) can bind it.
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
trap - EXIT

if ! "$T/pg/bin/wantzel" "$T/wssrv.wz" "$T/wssrv_sab" >"$T/sab_compile.err" 2>&1; then
  echo "the sabotaged server does not compile:"; cat "$T/sab_compile.err"; exit 1
fi
"$T/wssrv_sab" >"$T/sab_server.log" 2>&1 &
sabpid=$!
sabcleanup() { pkill -P "$sabpid" 2>/dev/null; kill "$sabpid" 2>/dev/null; wait "$sabpid" 2>/dev/null; }
trap sabcleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the sabotaged server did not come up"; cat "$T/sab_server.log"; exit 1; }

sabout=$("$T/wscli" "$port" 2>"$T/sabcli.err") || true
case "$sabout" in
  *"PUSH welcome"*)
    echo "sabotage did not break the test: the client still read the push frame's payload correctly with a corrupted payload byte"
    exit 1 ;;
  *) : ;;
esac
echo "the frame payload is really carried through: corrupting it breaks what the client reads, seen red by sabotage and restored from the unmodified lib/"

echo "lib/websocket.wz: on the SAME port as lib/http.wz, handshake, echo, server push, ping/pong, and a close with a code all work over a real (masked) client connection, and plain HTTP keeps working before and after"
