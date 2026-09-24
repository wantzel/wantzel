# lib/http.wz with large requests and replies, over HTTP and HTTPS: bodies read into a
# region of their own connection's (http.maxbody), several at once under a total
# (http.maxbodymem), and replies that outgrow http.outbuf (http.maxreply).
#
# WHAT IS ESTABLISHED:
#   1. 10 MB and 40 MB bodies arrive whole, in the clear and over TLS
#   2. 10 MB and 40 MB replies arrive whole, in the clear and over TLS
#   3. four 10 MB uploads at once all arrive
#   4. a body past http.maxbody is a 413; a reply past http.maxreply is a 500
#   5. bodies that would go past http.maxbodymem wait their turn with 503 and Retry-After,
#      and the next one is taken once there is room again
#   6. a client that reads a 40 MB reply slowly holds up nobody else
#   7. afterwards no region is left mapped: the counters and the process's memory map are
#      back where they started
#
# Every wait has a bound (curl --max-time, the helpers' own limits, http_large.timeout).
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
  for p in $started; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT
trap 'exit 143' TERM INT

"$here/bin/wantzel" "$here/tests/lib/progs/httpsapp.wz" "$tmp/app" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  httpsapp.wz does not compile"; cat "$tmp/build.log"; exit 1; }
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 30 -subj "/CN=local.test" \
  -addext "subjectAltName=DNS:local.test" 2>/dev/null

base=$(( 38000 + ($$ % 1500) * 3 ))
ptls=$base; predir=$((base + 1)); pplain=$((base + 2))
# bodies up to 50 MB, 64 MB of them at once; replies up to 50 MB
"$tmp/app" "$ptls" "$predir" "$tmp/cert.pem" "$tmp/key.pem" 30 50000000 \
  app="$pplain" maxreply=50000000 bodymem=64000000 >"$tmp/app.log" 2>&1 &
srv=$!
started="$started $srv"
i=0; while [ $i -lt 50 ]; do ss -tln 2>/dev/null | grep -q ":$pplain " && break; sleep 0.1; i=$((i+1)); done

P="http://127.0.0.1:$pplain"
S="https://local.test:$ptls"
TLS="--resolve local.test:$ptls:127.0.0.1 --cacert $tmp/cert.pem"
stat() { curl -s --max-time 5 "$P/stats" 2>/dev/null || true; }
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# Bytes mapped by the server, the stack aside. Counted, not listed: the kernel merges a
# leaked region with its neighbours, so the NUMBER of areas can stay the same.
maps() {
  total=0
  while read -r range rest; do
    case "$rest" in *"[stack]"*) continue ;; esac
    lo=${range%-*}; hi=${range#*-}
    total=$(( total + 0x$hi - 0x$lo ))
  done < "/proc/$srv/maps"
  echo "$total"
}
now_ms() { date +%s%3N; }

[ "$(curl -s --max-time 5 "$P/")" = ok ] && [ "$(curl -s --max-time 5 $TLS "$S/")" = ok ] \
  && ok "the application answers in the clear and over TLS" || { bad "the server did not answer" "$(cat "$tmp/app.log")"; exit 1; }
base_maps=$(maps)

# ---- 1. large bodies ----------------------------------------------------------------------------
head -c 10000000 /dev/urandom >"$tmp/b10"
head -c 40000000 /dev/urandom >"$tmp/b40"
echo_ok() {   # echo_ok <file> <url> <label> [curl options]
  f=$1; u=$2; l=$3; shift 3
  want="$(wc -c <"$f" | tr -d ' ') $(sha256sum "$f" | cut -d' ' -f1)"
  got=$(curl -s --max-time 60 "$@" --data-binary @"$f" "$u/echo" 2>/dev/null || true)
  [ "$got" = "$want" ] && ok "$l" || bad "$l" "want: $want" "got:  $got"
}
echo_ok "$tmp/b10" "$P" "a 10 MB body arrives whole in the clear"
echo_ok "$tmp/b40" "$P" "a 40 MB body arrives whole in the clear"
echo_ok "$tmp/b10" "$S" "a 10 MB body arrives whole over TLS" $TLS
echo_ok "$tmp/b40" "$S" "a 40 MB body arrives whole over TLS" $TLS

# ---- 2. large replies ---------------------------------------------------------------------------
pattern() { yes abcdefghijklmnopqrstuvwxyz | tr -d '\n' | head -c "$1" | sha256sum | cut -d' ' -f1; }
w10=$(pattern 10000000); w40=$(pattern 40000000)
[ "$(curl -s --max-time 60 "$P/big?n=10000000" | sha256sum | cut -d' ' -f1)" = "$w10" ] \
  && ok "a 10 MB reply arrives whole in the clear" || bad "the 10 MB reply in the clear is wrong"
[ "$(curl -s --max-time 60 "$P/big?n=40000000" | sha256sum | cut -d' ' -f1)" = "$w40" ] \
  && ok "a 40 MB reply arrives whole in the clear" || bad "the 40 MB reply in the clear is wrong"
[ "$(curl -s --max-time 60 $TLS "$S/big?n=10000000" | sha256sum | cut -d' ' -f1)" = "$w10" ] \
  && ok "a 10 MB reply arrives whole over TLS" || bad "the 10 MB reply over TLS is wrong"
[ "$(curl -s --max-time 60 $TLS "$S/big?n=40000000" | sha256sum | cut -d' ' -f1)" = "$w40" ] \
  && ok "a 40 MB reply arrives whole over TLS" || bad "the 40 MB reply over TLS is wrong"

# ---- 3. four uploads at once ----------------------------------------------------------------------
want="10000000 $(sha256sum "$tmp/b10" | cut -d' ' -f1)"
pids=""
for i in 1 2; do
  ( curl -s --max-time 60 --data-binary @"$tmp/b10" "$P/echo" >"$tmp/par.p$i" 2>&1 || true ) & pids="$pids $!"
  ( curl -s --max-time 60 $TLS --data-binary @"$tmp/b10" "$S/echo" >"$tmp/par.t$i" 2>&1 || true ) & pids="$pids $!"
done
for p in $pids; do wait "$p" || true; done
n=0; for f in "$tmp"/par.*; do [ "$(cat "$f")" = "$want" ] && n=$((n+1)); done
[ "$n" = 4 ] && ok "four 10 MB uploads at once, two in the clear and two over TLS, all arrive" \
             || bad "only $n of 4 concurrent uploads arrived whole"

# ---- 4. over the limits -------------------------------------------------------------------------
head -c 60000000 /dev/zero >"$tmp/b60"
code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' --data-binary @"$tmp/b60" "$P/echo" 2>/dev/null || true)
[ "$code" = 413 ] && ok "a 60 MB body, past http.maxbody, is a 413" || bad "a body past the maximum got $code"
code=$(curl -s --max-time 30 $TLS -o /dev/null -w '%{http_code}' --data-binary @"$tmp/b60" "$S/echo" 2>/dev/null || true)
[ "$code" = 413 ] && ok "and so it is over TLS" || bad "a body past the maximum over TLS got $code"
code=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$P/big?n=60000000" 2>/dev/null || true)
[ "$code" = 500 ] && ok "a 60 MB reply, past http.maxreply, is a clean 500" || bad "a reply past the maximum got $code"

# ---- 5. the total for bodies --------------------------------------------------------------------
# Two uploads of 30 MB at 1 MB/s hold 60 of the 64 MB for their whole duration; a third
# body of 10 MB does not fit beside them.
head -c 30000000 /dev/zero >"$tmp/b30"
for i in 1 2; do
  curl -s --max-time 4 --limit-rate 1M --data-binary @"$tmp/b30" "$P/echo" >/dev/null 2>&1 &
  started="$started $!"
done
sleep 1
held=$(field "$(stat)" bodies)
hdr=$(curl -s --max-time 10 -D - -o /dev/null --data-binary @"$tmp/b10" "$P/echo" 2>/dev/null | tr -d '\r' || true)
case "$hdr" in
  "HTTP/1.1 503"*"Retry-After"*) ok "past http.maxbodymem ($held bytes held), a body waits its turn: 503 with Retry-After" ;;
  *) bad "a body past the total got something else" "held: $held" "$(echo "$hdr" | head -3)" ;;
esac
sleep 4
echo_ok "$tmp/b10" "$P" "and once the slow uploads are gone, the next body is taken"

# ---- 6. a slow reader ---------------------------------------------------------------------------
curl -s --max-time 6 --limit-rate 200K $TLS -o /dev/null "$S/big?n=40000000" >/dev/null 2>&1 &
slow=$!
started="$started $slow"
sleep 1
pend=$(field "$(stat)" pend)
t0=$(now_ms); n=0; i=0
while [ $i -lt 20 ]; do [ "$(curl -s --max-time 5 "$P/")" = ok ] && n=$((n+1)); i=$((i+1)); done
t1=$(now_ms)
[ "${pend:-0}" -gt 1000000 ] && [ "$n" = 20 ] && [ $((t1 - t0)) -lt 3000 ] \
  && ok "while a 40 MB reply waits for a slow reader ($pend bytes queued), 20 others are served in $((t1 - t0)) ms" \
  || bad "a slow reader held up the others" "queued: $pend, served: $n of 20 in $((t1 - t0)) ms"
wait "$slow" 2>/dev/null || true

# ---- 7. nothing left behind ----------------------------------------------------------------------
sleep 1
s=$(stat)
[ "$(field "$s" bodies)" = 0 ] && [ "$(field "$s" replies)" = 0 ] && [ "$(field "$s" pend)" = 0 ] && [ "$(field "$s" keep)" = 0 ] \
  && ok "no body, reply or queue region is left: $s" || bad "a region was left behind" "$s"
[ "$(maps)" = "$base_maps" ] && ok "and the process maps exactly as many bytes as before ($base_maps)" \
  || bad "the memory map grew: $base_maps bytes before, $(maps) after"
kill -0 "$srv" 2>/dev/null && ok "the server is still running" || bad "the server died" "$(tail -5 "$tmp/app.log")"

echo "http_large: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
