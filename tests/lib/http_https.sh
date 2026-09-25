# lib/http.wz serving an application over HTTPS itself: TLS per connection in the one event
# loop, with a certificate from PEM files (http.httpsfiles), and the plain port redirecting.
#
# WHAT IS ESTABLISHED:
#   1. the application answers over TLS, and the plain port only ever redirects to it
#   2. bodies past one slot and past INBUF, a 500 kB reply, keep-alive and pipelining all
#      go through the TLS layer unchanged -- including more pipelined requests than the
#      slot has room for, which exercises the bytes kept between two reads
#   3. a client that stalls in its ClientHello is closed by the header deadline and holds
#      up nobody; garbage on the TLS port costs only that connection
#   4. 520 TLS connections at once, and requests still answered while they stand
#   5. a new certificate installed while serving
#   6. back to baseline afterwards: no session, slot, kept region or queued byte left over
#   7. with no certificate at all: handshakes closed at once, the plain port says 503
#
# Every wait has a bound: curl and openssl run under --max-time or timeout, the helpers
# give up on their own, and the runner's limit is in http_https.timeout.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/tests/lib/portlib.sh"
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
  for p in $started; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT
# A time limit sends TERM, and sh runs no EXIT trap for a signal on its own.
trap 'exit 143' TERM INT

"$here/bin/wantzel" "$here/tests/lib/progs/httpsapp.wz" "$tmp/app" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  httpsapp.wz does not compile"; cat "$tmp/build.log"; exit 1; }
"$here/bin/wantzel" "$here/tests/lib/progs/tlspoke.wz" "$tmp/tlspoke" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  tlspoke.wz does not compile"; cat "$tmp/build.log"; exit 1; }

# Two certificates. The first key is PKCS #8 ("PRIVATE KEY", what `openssl req -newkey`
# writes), the second SEC 1 ("EC PRIVATE KEY", `openssl ecparam`): http.httpsfiles reads both.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$tmp/one.key" -out "$tmp/one.pem" -days 30 -subj "/CN=local.test" \
  -addext "subjectAltName=DNS:local.test" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/two.key" 2>/dev/null
openssl req -x509 -key "$tmp/two.key" -out "$tmp/two.pem" -days 30 -subj "/CN=local.test" \
  -addext "subjectAltName=DNS:local.test" 2>/dev/null

set -- $(free_ports 6)
p443=$1; p80=$2; paux=$3; pbare=$4; pshort=$5; pshort80=$6
listening() { i=0; while [ $i -lt 50 ]; do ss -tln 2>/dev/null | grep -q ":$1 " && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

# The server under test, with a 400000-byte big-body region; and a second one whose header
# deadline is 2 s, so a deadline is seen inside the test.
#
# 90 s, NOT 30. p256.sign is constant-time: 520 sequential handshakes in
# check 4 below now cost roughly 7 s of signing alone on a quiet machine, and considerably
# more loaded -- and a completed handshake with no request after it is held to this SAME
# header deadline (checked earlier in this file), so the earliest of the 520 connections
# were being timed out before the last one finished shaking hands. 30 s was already close
# to that cost before the change; 90 s leaves real room without weakening check 3, which
# only needs "clearly longer than a few seconds".
"$tmp/app" "$p443" "$p80" "$tmp/one.pem" "$tmp/one.key" 90 400000 "cert2=$tmp/two.pem" "key2=$tmp/two.key" \
  >"$tmp/app.log" 2>&1 &
srv=$!
started="$started $srv"
"$tmp/app" "$pshort" "$pshort80" "$tmp/one.pem" "$tmp/one.key" 2 0 >"$tmp/short.log" 2>&1 &
short=$!
started="$started $short"
listening "$p443" && listening "$p80" && listening "$pshort" \
  || { echo "  FAIL  the servers did not start"; port_owner "$p443"; port_owner "$p80"; port_owner "$pshort"; cat "$tmp/app.log" "$tmp/short.log"; exit 1; }

U="https://local.test:$p443"
get() {    # get <path> [cafile]: the body, over HTTPS
  curl -s --http1.1 --max-time 10 --resolve "local.test:$p443:127.0.0.1" --cacert "${2:-$tmp/one.pem}" "$U$1" 2>/dev/null || true
}
stat() { get /stats; }
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
now_ms() { date +%s%3N; }

# ---- 1. TLS for the application, redirects on the plain port -------------------------------
[ "$(get /)" = ok ] && ok "the application answers over HTTPS" || bad "no answer over HTTPS" "$(cat "$tmp/app.log")"
[ "$(get /tls)" = tls ] && ok "and knows the request came over TLS (http.istls)" || bad "http.istls is wrong: $(get /tls)"

hdrs=$(curl -s --max-time 5 -o /dev/null -D - -H "Host: local.test:$p80" "http://127.0.0.1:$p80/tls?a=1" 2>/dev/null | tr -d '\r' || true)
case "$hdrs" in
  "HTTP/1.1 301"*"Location: https://local.test:$p443/tls?a=1"*) ok "the plain port redirects a GET with 301 to https, path and query kept" ;;
  *) bad "the plain port did not redirect the GET" "$hdrs" ;;
esac
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: local.test" -d x=1 "http://127.0.0.1:$p80/form" 2>/dev/null || true)
[ "$code" = 308 ] && ok "and a POST with 308, which keeps the method" || bad "a POST on the plain port got $code"
body=$(curl -s --max-time 5 -H "Host: local.test" "http://127.0.0.1:$p80/tls" 2>/dev/null || true)
case "$body" in *plain*|*tls*) bad "the application was served over plain HTTP" "$body" ;;
  *) ok "the application is never served on the plain port" ;; esac
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: bad_host!" "http://127.0.0.1:$p80/" 2>/dev/null || true)
[ "$code" = 400 ] && ok "a Host that is not a hostname is refused, not copied into a Location" || bad "a bad Host got $code"
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p80/.well-known/acme-challenge/sometoken" 2>/dev/null || true)
[ "$code" = 404 ] && ok "a challenge nobody asked for is a 404" || bad "an unknown challenge got $code"

# ---- 2. bodies, a large reply, keep-alive, pipelining ----------------------------------------
check_echo() {   # check_echo <bytes> <what>
  head -c "$1" /dev/urandom >"$tmp/body"
  want="$1 $(sha256sum "$tmp/body" | cut -d' ' -f1)"
  got=$(curl -s --http1.1 --max-time 20 --resolve "local.test:$p443:127.0.0.1" --cacert "$tmp/one.pem" \
        --data-binary @"$tmp/body" "$U/echo" 2>/dev/null || true)
  [ "$got" = "$want" ] && ok "$2" || bad "$2" "want: $want" "got:  $got"
}
check_echo 20000 "a 20 kB body arrives whole over TLS (past one slot's input)"
check_echo 300000 "a 300 kB body arrives whole over TLS (past INBUF, into the big-body region)"
# REFUSED, AND THE CLIENT HEARS WHY. curl is still sending the body when the 413 comes; a
# server that closed at once would reset the connection under it, and curl would report a
# send failure instead of the answer. Five times, because that is a race when it is wrong.
head -c 500000 /dev/urandom >"$tmp/huge"
codes=""
i=0; while [ $i -lt 5 ]; do
  codes="$codes$(curl -s --http1.1 --max-time 20 --resolve "local.test:$p443:127.0.0.1" --cacert "$tmp/one.pem" \
         -o /dev/null -w '%{http_code}' --data-binary @"$tmp/huge" "$U/echo" 2>/dev/null || true) "
  i=$((i+1))
done
[ "$codes" = "413 413 413 413 413 " ] && ok "a 500 kB body past the region is refused with 413, and the client reads it" \
  || bad "an oversized body did not get a readable 413: $codes"
[ "$(get /)" = ok ] && ok "and the server serves on after it" || bad "the server stopped after a 413"

want=$(yes abcdefghijklmnopqrstuvwxyz | tr -d '\n' | head -c 500000 | sha256sum | cut -d' ' -f1)
got=$(get "/big?n=500000" | sha256sum | cut -d' ' -f1)
[ "$got" = "$want" ] && ok "a 500 kB reply arrives whole over TLS" || bad "the 500 kB reply is not what was sent"

n=$(curl -s --http1.1 --max-time 10 --resolve "local.test:$p443:127.0.0.1" --cacert "$tmp/one.pem" \
    -o /dev/null -o /dev/null -o /dev/null -w '%{num_connects} ' "$U/" "$U/tls" "$U/" 2>/dev/null || true)
[ "$n" = "1 0 0 " ] && ok "keep-alive: three requests, one connection, one handshake" || bad "keep-alive over TLS: connects per request were $n"

: >"$tmp/pipe"
i=0; while [ $i -lt 300 ]; do
  printf 'GET /tls HTTP/1.1\r\nHost: local.test\r\nX-Pad: 0123456789012345678901234567890123456789\r\n\r\n' >>"$tmp/pipe"
  i=$((i+1))
done
timeout 4 openssl s_client -quiet -connect "127.0.0.1:$p443" -servername local.test -ign_eof \
    <"$tmp/pipe" >"$tmp/pipe.out" 2>/dev/null || true
n=$(grep -c "^HTTP/1.1 200" "$tmp/pipe.out" || true)
[ "$n" = 300 ] && ok "300 requests pipelined in one burst over TLS: 300 answers" || bad "pipelined over TLS: $n of 300 answered"
# WHEN A READ DECRYPTS TO MORE THAN THE SLOT CAN TAKE, the rest is kept for the next pull.
# Whether a given read does depends on how the bytes arrive, so this is counted over the
# 20 kB body and the burst together; with both, it has always happened.
kept=$(field "$(stat)" kept)
[ "${kept:-0}" -ge 1 ] && ok "reads that decrypted to more than the slot could take kept the rest, not lost it ($kept)" \
                       || bad "no read ever needed the kept bytes (kept=$kept): that path went unexercised"

# ---- 3. stalls and garbage, on the server with the 2 s header deadline ------------------------
S="https://local.test:$pshort"
sget() { curl -s --http1.1 --max-time 10 --resolve "local.test:$pshort:127.0.0.1" --cacert "$tmp/one.pem" "$S$1" 2>/dev/null || true; }
"$tmp/tlspoke" capture "$paux" >"$tmp/hello.bin" 2>/dev/null &
cap=$!
listening "$paux" || true
timeout 5 openssl s_client -connect "127.0.0.1:$paux" -servername local.test -tls1_3 </dev/null >/dev/null 2>&1 || true
wait "$cap" || true
before=$(field "$(sget /stats)" timedout)
i=0; while [ $i -lt 2 ]; do
  "$tmp/tlspoke" half "$pshort" "$tmp/hello.bin" 6000 >/dev/null 2>&1 &
  started="$started $!"
  "$tmp/tlspoke" trickle "$pshort" 6000 >/dev/null 2>&1 &
  started="$started $!"
  i=$((i+1))
done
sleep 0.3
t0=$(now_ms); n=0; i=0
while [ $i -lt 20 ]; do [ "$(sget /)" = ok ] && n=$((n+1)); i=$((i+1)); done
t1=$(now_ms)
[ "$n" = 20 ] && [ $((t1 - t0)) -lt 3000 ] && ok "while four clients stall mid-ClientHello, 20 others are served ($((t1 - t0)) ms)" \
  || bad "stalled handshakes held up the others: $n of 20 in $((t1 - t0)) ms"
sleep 3
after=$(field "$(sget /stats)" timedout)
[ $((after - before)) -ge 4 ] && ok "the four stalled handshakes were closed by the 2 s header deadline" \
  || bad "the stalled handshakes were not closed by the deadline ($before -> $after)"
# A handshake that completes and then sends nothing is held to the same deadline.
before=$after
timeout 8 sh -c "sleep 5 | openssl s_client -connect 127.0.0.1:$pshort -servername local.test -quiet" >/dev/null 2>&1 &
started="$started $!"
sleep 3.5
after=$(field "$(sget /stats)" timedout)
[ $((after - before)) -ge 1 ] && ok "and so is a completed handshake with no request after it" \
  || bad "an idle completed handshake outlived the header deadline ($before -> $after)"

out=$("$tmp/tlspoke" garbage "$pshort" 2>&1 || true)
[ "$out" = "ALERT 10" ] && ok "plain HTTP on the TLS port gets an alert and is closed" || bad "garbage on the TLS port got: $out"
[ "$(sget /)" = ok ] && ok "and only that connection is affected" || bad "the server stopped after garbage"

# ---- 4. 520 TLS connections at once ---------------------------------------------------------
t0=$(now_ms)
"$tmp/tlspoke" hold "$p443" 520 4000 >"$tmp/hold.out" 2>&1 &
hp=$!
started="$started $hp"
i=0; while [ $i -lt 300 ] && ! grep -q HELD "$tmp/hold.out" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
held=$(sed -n 's/^HELD //p' "$tmp/hold.out")
t1=$(now_ms)
live=$(field "$(stat)" live)
[ "${held:-0}" = 520 ] && [ "${live:-0}" -ge 521 ] && ok "520 TLS connections open at once, each with its session ($live live, $((t1 - t0)) ms to shake hands)" \
  || bad "520 connections at once: $held held, $live sessions live"
n=0; i=0; while [ $i -lt 20 ]; do [ "$(get /)" = ok ] && n=$((n+1)); i=$((i+1)); done
[ "$n" = 20 ] && ok "and requests are answered while they stand" || bad "only $n of 20 answered next to 520 connections"
wait "$hp" || true

# ---- 5. a new certificate while serving ------------------------------------------------------
fp() { echo | timeout 5 openssl s_client -connect "127.0.0.1:$p443" -servername local.test 2>/dev/null \
       | openssl x509 -noout -fingerprint -sha256 2>/dev/null; }
two=$(openssl x509 -in "$tmp/two.pem" -noout -fingerprint -sha256)
[ "$(get /reload)" = reloaded ] && [ "$(fp)" = "$two" ] && ok "http.httpsfiles again while serving: the next handshake uses the new certificate" \
  || bad "the certificate was not replaced while serving"
[ "$(get / "$tmp/two.pem")" = ok ] && ok "and clients are served under it" || bad "no service under the new certificate"

# ---- 6. back to baseline ------------------------------------------------------------------------
i=0; while [ $i -lt 40 ]; do curl -s --max-time 5 --resolve "local.test:$p443:127.0.0.1" --cacert "$tmp/two.pem" "$U/" >/dev/null 2>&1 || true; i=$((i+1)); done
i=0; while [ $i -lt 10 ]; do "$tmp/tlspoke" garbage "$p443" >/dev/null 2>&1 || true; i=$((i+1)); done
i=0; while [ $i -lt 10 ]; do timeout 5 openssl s_client -connect "127.0.0.1:$p443" -servername local.test </dev/null >/dev/null 2>&1 || true; i=$((i+1)); done
i=0; while [ $i -lt 10 ]; do "$tmp/tlspoke" half "$p443" "$tmp/hello.bin" 10 >/dev/null 2>&1 || true; i=$((i+1)); done
sleep 1
s=$(get /stats "$tmp/two.pem")
[ "$(field "$s" live)" = 1 ] && [ "$(field "$s" open)" = 1 ] && [ "$(field "$s" pend)" = 0 ] && [ "$(field "$s" keep)" = 0 ] \
  && ok "after all of it only the asking connection is left: $s" || bad "something was left behind" "$s"
kill -0 "$srv" 2>/dev/null && ok "the server is still running" || bad "the server died" "$(tail -5 "$tmp/app.log")"

# ---- 7. no certificate ----------------------------------------------------------------------
"$tmp/app" "$pbare" "$paux" - - 2 0 >"$tmp/bare.log" 2>&1 &
bare=$!
started="$started $bare"
listening "$pbare" || bad "the server without a certificate did not start" "$(port_owner "$pbare")" "$(cat "$tmp/bare.log")"
if timeout 5 openssl s_client -connect "127.0.0.1:$pbare" -servername local.test </dev/null >/dev/null 2>&1; then
  bad "a handshake succeeded without a certificate"
else ok "without a certificate a handshake is closed at once"; fi
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$paux/" 2>/dev/null || true)
[ "$code" = 503 ] && ok "and the plain port says 503, not the application" || bad "the plain port without a certificate got $code"
kill -0 "$bare" 2>/dev/null && ok "and the server keeps running" || bad "the server without a certificate died"

echo "http_https: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
