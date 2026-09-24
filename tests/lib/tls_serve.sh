# examples/serve.wz holding many TLS connections at once in one thread: a crowd of clients
# together, one that stalls halfway through its ClientHello, one that sends everything a
# byte at a time, one that is not speaking TLS at all, hundreds of idle sessions, and a
# certificate swap while a connection is open.
#
# TOETSGROEP: lib
# DEKT: lib/tls.wz examples/serve.wz
#
# THE CLAIM UNDER TEST IS THAT NOTHING WAITS. The server is one process with one event loop,
# and every TLS connection is a session that advances only as its bytes arrive. So a client
# that stops sending must cost its own connection and nothing else -- which is measured
# here as time: the other requests have to finish quickly WHILE it stalls. A server that
# drives the handshake with a blocking read passes every functional check in tls.sh and
# fails this one.
#
# Every wait has a bound: curl and openssl run under --max-time or timeout, and the helper
# gives up on its own.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

if ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  skip  openssl and curl are both needed"
  exit 0
fi

tmp=$(mktemp -d)
started=""
cleanup() {
  rc=$?
  for p in $started; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT
# A TIMEOUT SENDS TERM, and sh does not run an EXIT trap for a signal on its own: without
# this, a test stopped by the runner's time limit left its server and helpers running.
trap 'exit 143' TERM INT

"$here/bin/wantzel" "$here/examples/serve.wz" "$tmp/serve" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  serve.wz does not compile"; cat "$tmp/build.log"; exit 1; }
"$here/bin/wantzel" "$here/tests/lib/progs/tlspoke.wz" "$tmp/tlspoke" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  tlspoke.wz does not compile"; cat "$tmp/build.log"; exit 1; }

# A certificate and its key, in the two files serve.wz reads beside itself.
mkdir "$tmp/srv"
mkcert() {   # mkcert <dir> <name>: <name>.pem, <name>.key.pem, <name>.der, <name>.hex
  openssl ecparam -name prime256v1 -genkey -noout -out "$1/$2.key.pem" 2>/dev/null
  openssl req -x509 -key "$1/$2.key.pem" -out "$1/$2.pem" -days 30 -subj "/CN=local.test" \
    -addext "subjectAltName=DNS:local.test" 2>/dev/null
  openssl x509 -in "$1/$2.pem" -outform DER -out "$1/$2.der" 2>/dev/null
  h=$(openssl ec -in "$1/$2.key.pem" -noout -text 2>/dev/null \
      | awk '/^priv:/{f=1;next} f&&/^[ \t]/{print;next} {f=0}' | tr -dc '0-9a-f')
  h=$(printf '%s' "$h" | tail -c 64)
  while [ ${#h} -lt 64 ]; do h="0$h"; done
  printf '%s' "$h" > "$1/$2.hex"
}
mkcert "$tmp" one
mkcert "$tmp" two
cp "$tmp/one.der" "$tmp/srv/cert.der"
cp "$tmp/one.hex" "$tmp/srv/key.hex"

base=$(( 26000 + $$ % 3000 * 3 ))
p80=$base; p443=$((base + 1)); paux=$((base + 2))
( cd "$tmp/srv" && exec "$tmp/serve" "$p80" "$p443" local.test >"$tmp/serve.log" 2>&1 ) &
srvpid=$!
started="$started $srvpid"
i=0; while [ $i -lt 200 ]; do ss -tln 2>/dev/null | grep -q ":$p443 " && break; sleep 0.1; i=$((i+1)); done
ss -tln 2>/dev/null | grep -q ":$p443 " || { echo "  FAIL  serve did not start"; cat "$tmp/serve.log"; exit 1; }

URL="https://local.test:$p443/"
get() {      # get <cafile> [--max-time n]: one HTTPS request, the body on stdout
  curl -s --http1.1 --max-time "${2:-10}" --resolve "local.test:$p443:127.0.0.1" --cacert "$1" "$URL" 2>/dev/null || true
}
now_ms() { date +%s%3N; }

case "$(get "$tmp/one.pem")" in
  *"over its own TLS"*) ok "serve answers over HTTPS" ;;
  *) bad "serve does not answer over HTTPS"; cat "$tmp/serve.log"; exit 1 ;;
esac

# ---- 1. A CROWD: 250 clients at once ---------------------------------------------------------
#
# All started before any has finished, so the handshakes really are interleaved in the one
# loop. Each gets 30 seconds, which is far more than a handshake needs even when all 250
# queue for the same core.
t0=$(now_ms)
pids=""
i=0
while [ $i -lt 250 ]; do
  ( curl -s --http1.1 --max-time 30 --resolve "local.test:$p443:127.0.0.1" \
      --cacert "$tmp/one.pem" "$URL" >"$tmp/crowd.$i" 2>&1 || true ) &
  pids="$pids $!"
  i=$((i+1))
done
for p in $pids; do wait "$p" || true; done
t1=$(now_ms)
n=$(grep -l "over its own TLS" "$tmp"/crowd.* 2>/dev/null | wc -l)
[ "$n" -eq 250 ] && ok "250 clients at once all get their page ($((t1 - t0)) ms for all of them)" \
                 || bad "only $n of 250 concurrent clients got their page"

# ---- 2. A CLIENT THAT STALLS HALFWAY THROUGH ITS ClientHello ---------------------------------
#
# A real ClientHello first: openssl's, caught by the helper listening on the spare port.
"$tmp/tlspoke" capture "$paux" >"$tmp/hello.bin" 2>/dev/null &
cap=$!
i=0; while [ $i -lt 200 ]; do ss -tln 2>/dev/null | grep -q ":$paux " && break; sleep 0.1; i=$((i+1)); done
timeout 5 openssl s_client -connect "127.0.0.1:$paux" -servername local.test -tls1_3 \
  </dev/null >/dev/null 2>&1 || true
wait "$cap" || true
hn=$(wc -c <"$tmp/hello.bin")
[ "$hn" -gt 100 ] && ok "a real ClientHello to replay ($hn bytes, from openssl)" \
                  || bad "no ClientHello was captured ($hn bytes)"

# Two clients send half of it and go quiet. Two more announce a ClientHello of 16 KB and
# send it a byte every 2 ms, so it is always almost there. Meanwhile, 20 requests one after
# another: each must be answered, and all 20 inside two seconds -- they need about a
# quarter of that. A server that reads a handshake until it is complete is held for as long
# as the trickle lasts, and cannot make it.
i=0
while [ $i -lt 2 ]; do
  "$tmp/tlspoke" half "$p443" "$tmp/hello.bin" 6000 >"$tmp/half.$i" 2>&1 &
  started="$started $!"
  "$tmp/tlspoke" trickle "$p443" 6000 >"$tmp/trickle.$i" 2>&1 &
  started="$started $!"
  i=$((i+1))
done
sleep 0.3
t0=$(now_ms)
n=0
i=0
while [ $i -lt 20 ]; do
  case "$(get "$tmp/one.pem" 3)" in *"over its own TLS"*) n=$((n+1)) ;; esac
  i=$((i+1))
done
t1=$(now_ms)
if [ "$n" -eq 20 ] && [ $((t1 - t0)) -lt 5000 ]; then
  ok "while four clients stall mid-ClientHello, 20 others are served in $((t1 - t0)) ms"
else
  bad "a stalled handshake held up the others: $n of 20 answered in $((t1 - t0)) ms"
fi

# ---- 3. ONE BYTE AT A TIME -------------------------------------------------------------------
out=$("$tmp/tlspoke" bytes "$p443" "$tmp/hello.bin" 2>&1 || true)
[ "$out" = "SERVERHELLO" ] && ok "a ClientHello sent one byte per segment is answered with a ServerHello" \
                           || bad "a ClientHello sent a byte at a time was not answered" "got: $out"

# And a whole exchange that way: curl through a relay that forwards what curl sends one byte
# per segment -- the ClientHello, the Finished and the request all arrive in pieces.
"$tmp/tlspoke" relay "$paux" "$p443" 20 >"$tmp/relay.out" 2>&1 &
started="$started $!"
i=0; while [ $i -lt 200 ]; do ss -tln 2>/dev/null | grep -q ":$paux " && break; sleep 0.1; i=$((i+1)); done
body=$(curl -s --http1.1 --max-time 20 --resolve "local.test:$paux:127.0.0.1" \
       --cacert "$tmp/one.pem" "https://local.test:$paux/" 2>&1 || true)
case "$body" in
  *"over its own TLS"*) ok "a whole request, every byte from the client in its own segment, is served" ;;
  *) bad "the byte-by-byte request failed" "got: $(echo "$body" | head -2)" ;;
esac

# ---- 3b. A SLOW NETWORK ----------------------------------------------------------------------
#
# Everything the client sends arrives 400 ms late, as over a long link. The client's
# Finished then comes 400 ms after the server's flight: a server that polls for it with a
# bounded busy loop gives up first, and every distant client fails its handshake.
"$tmp/tlspoke" slowrelay "$paux" "$p443" 20 400 >"$tmp/slow.out" 2>&1 &
started="$started $!"
i=0; while [ $i -lt 200 ]; do ss -tln 2>/dev/null | grep -q ":$paux " && break; sleep 0.1; i=$((i+1)); done
body=$(curl -s --http1.1 --max-time 20 --resolve "local.test:$paux:127.0.0.1" \
       --cacert "$tmp/one.pem" "https://local.test:$paux/" 2>&1 || true)
case "$body" in
  *"over its own TLS"*) ok "a client whose every packet is 400 ms late is served" ;;
  *) bad "a client on a slow network was not served" "got: $(echo "$body" | head -2)" ;;
esac

# ---- 4. NOT TLS AT ALL -----------------------------------------------------------------------
out=$("$tmp/tlspoke" garbage "$p443" 2>&1 || true)
[ "$out" = "ALERT 10" ] && ok "plain HTTP on the TLS port gets an unexpected_message alert" \
                        || bad "plain HTTP on the TLS port was not refused with an alert" "got: $out"
case "$(get "$tmp/one.pem")" in
  *"over its own TLS"*) ok "and the server carries on serving everyone else" ;;
  *) bad "the server stopped serving after a garbage connection" ;;
esac

# ---- 5. HUNDREDS OF IDLE SESSIONS ------------------------------------------------------------
#
# 100 completed handshakes, all left open without a request. Every one holds a session in
# the server; a new client must still be served while they are there.
#
# 100 AND NOT MORE, because the handshakes run one after the other at about 30 ms each
# (three times that under a loaded machine)
# (the client verifies the server's signature too) and serve.wz closes a connection that
# has not sent its request within DEADLINE (10 s). With 300 the first ones were already
# swept by the time the last one completed, and the server-side count came out short --
# which looked like a server that drops idle sessions and was the deadline doing its job.
"$tmp/tlspoke" hold "$p443" 100 1500 >"$tmp/hold.out" 2>&1 &
holdpid=$!
started="$started $holdpid"
i=0; while [ $i -lt 300 ] && ! grep -q HELD "$tmp/hold.out" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
held=$(sed -n 's/^HELD //p' "$tmp/hold.out")
[ "${held:-0}" -eq 100 ] && ok "100 handshakes completed and held open at once" \
                         || bad "only ${held:-0} of 100 idle sessions were established"
# COUNTED ON THE SERVER'S SIDE, not the client's: the client only knows its handshakes
# finished, and a server that dropped each connection right after would look the same there.
n=$(ss -tnH state established "( sport = :$p443 )" 2>/dev/null | wc -l)
[ "$n" -ge 100 ] && ok "and the server holds all of them ($n connections established)" \
                 || bad "the server does not hold the idle sessions: $n established"
case "$(get "$tmp/one.pem")" in
  *"over its own TLS"*) ok "a new client is served while 100 sessions stand open" ;;
  *) bad "a new client was not served next to 300 open sessions" ;;
esac
wait "$holdpid" || true

# ---- 6. A NEW CERTIFICATE WHILE A CONNECTION IS OPEN -----------------------------------------
#
# openssl shakes hands under the first certificate at once and sends its request only two
# seconds later. In between, the files on disk are replaced; the server installs the new
# pair. The old connection must still get its answer, and a new one must see the new
# certificate.
( sleep 2; printf 'GET / HTTP/1.1\r\nHost: local.test\r\n\r\n'; sleep 1 ) \
  | timeout 15 openssl s_client -connect "127.0.0.1:$p443" -servername local.test -tls1_3 \
      -CAfile "$tmp/one.pem" -quiet >"$tmp/old.out" 2>&1 &
oldpid=$!
started="$started $oldpid"
sleep 0.5
cp "$tmp/two.der" "$tmp/srv/cert.der.new"; mv "$tmp/srv/cert.der.new" "$tmp/srv/cert.der"
cp "$tmp/two.hex" "$tmp/srv/key.hex.new"; mv "$tmp/srv/key.hex.new" "$tmp/srv/key.hex"
i=0; while [ $i -lt 200 ] && ! grep -q "certificate installed" "$tmp/serve.log"; do sleep 0.1; i=$((i+1)); done
grep -q "certificate installed" "$tmp/serve.log" && ok "the new certificate on disk is installed while running" \
                                                 || bad "the new certificate was not picked up" "$(tail -3 "$tmp/serve.log")"
case "$(get "$tmp/two.pem")" in
  *"over its own TLS"*) ok "a new connection is served under the new certificate" ;;
  *) bad "a new connection did not verify against the new certificate" ;;
esac
[ -z "$(get "$tmp/one.pem")" ] && ok "and no longer under the old one" \
                               || bad "the old certificate is still being served"
wait "$oldpid" || true
grep -q "over its own TLS" "$tmp/old.out" && ok "the connection opened before the swap is still answered after it" \
                                          || bad "the connection opened before the swap lost its answer" "$(head -3 "$tmp/old.out")"

# ---- one process did all of it ---------------------------------------------------------------
kill -0 "$srvpid" 2>/dev/null && ok "the server is still running" || bad "the server died"
n=$(pgrep -c -f "$tmp/serve" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "and it is one process" || bad "expected one server process, found $n"

echo "tls_serve: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
