# lib/http.wz in https mode (http.https): the certificate obtained from a local ACME
# authority from inside the server's own loop, and what both ports do before and after.
#
# THE PIECES are those of tests/lib/autocert.sh -- tests/helpers/acmesrv.wz as the
# authority, validating later from a child process, behind tests/helpers/tlsfront.wz --
# with one difference that matters here: the authority issues from an INTERMEDIATE, and a
# client is given only the ROOT. That is how a browser meets a Let's Encrypt certificate,
# and it only verifies when the server sends the intermediate along with its own
# certificate. The server under test is examples/autocert.wz, which is http.https plus
# option parsing.
#
# WHAT IS ESTABLISHED:
#   1. before any certificate: the plain port answers 503 and never the application, and a
#      TLS handshake is closed at once -- without the server stopping
#   2. once the authority works: the challenge is answered WHILE the order is pending, the
#      certificate is installed, and the served chain has two certificates
#   3. a client that trusts only the root is served over HTTPS
#   4. the plain port then redirects to https://<host>:<port><path>
#   5. a restart with a valid certificate in the store orders nothing, and serves it
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
set -- $(free_ports 4)
caport=$1; frontport=$2; p80=$3; p443=$4
host=test.example.org
started=""
SRV=""
cleanup() {
  rc=$?
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
  for p in $started; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# ---- a root, an intermediate under it, and the authority's HTTPS front -----------------------
cd "$tmp"
mkdir ca
openssl ecparam -name prime256v1 -genkey -noout -out root.key 2>/dev/null
openssl req -x509 -new -key root.key -out root.pem -days 3650 -subj "/CN=Test Root" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out int.key 2>/dev/null
openssl req -new -key int.key -subj "/CN=Test Intermediate" -out int.csr 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > int.cnf
openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -days 365 \
  -extfile int.cnf -outform DER -out int.der 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out front.key 2>/dev/null
openssl req -new -key front.key -subj "/CN=ca.example.com" -out front.csr 2>/dev/null
printf 'subjectAltName=DNS:ca.example.com\nbasicConstraints=CA:FALSE\n' > front.cnf
openssl x509 -req -in front.csr -CA root.pem -CAkey root.key -CAcreateserial -days 30 \
  -extfile front.cnf -outform DER -out front.der 2>/dev/null
hexkey() { openssl ec -in "$1" -text -noout 2>/dev/null | sed -n '/priv:/,/pub:/p' \
           | tr -d ' :\n' | sed 's/priv//;s/pub//' | tail -c 65; }

"$here/bin/wantzel" "$here/tests/helpers/acmesrv.wz" acmesrv >/dev/null 2>&1 \
  || { echo "  FAIL  the ACME fixture does not compile"; exit 1; }
"$here/bin/wantzel" "$here/tests/helpers/tlsfront.wz" tlsfront >/dev/null 2>&1 \
  || { echo "  FAIL  the TLS front does not compile"; exit 1; }
"$here/bin/wantzel" "$here/examples/autocert.wz" server 2>cerr \
  || { echo "  FAIL  examples/autocert.wz does not compile"; cat cerr; exit 1; }

intkey=$(hexkey int.key); frontkey=$(hexkey front.key)
touch ca/fail                     # the authority starts out failing: no certificate yet
echo 0 > ca/age
( cd ca && exec ../acmesrv "$caport" "$p80" "https://ca.example.com:$frontport" ../int.der "$intkey" > ../ca.log 2>&1 ) &
started="$started $!"
./tlsfront "$frontport" "$caport" front.der "$frontkey" > front.log 2>&1 &
started="$started $!"

waitfor() {   # waitfor <file> <text> <seconds>
  n=0; lim=$(( $3 * 10 ))
  while [ $n -lt $lim ]; do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1
}
waitfor ca.log LISTENING 10 && waitfor front.log LISTENING 10 \
  || { echo "  FAIL  the authority never started"; cat ca.log front.log; exit 1; }

start() {
  : > srv.log
  ./server "$p80" "$p443" "$host" --directory "https://ca.example.com:$frontport/directory" \
    --pin ca.example.com=127.0.0.1 --store store --ca root.pem --check 3600 --retry 1 > srv.out 2> srv.log &
  SRV=$!
  waitfor srv.out LISTENING 10 || { bad "the server did not start" "$(cat srv.log)"; exit 1; }
}
stop() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }; SRV=""; }
orders() { grep -c "^ORDER" ca.log || true; }
chain() { echo | timeout 10 openssl s_client -connect "127.0.0.1:$p443" -servername "$host" -showcerts 2>/dev/null; }
plain() { curl -s --max-time 5 -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $host" "http://127.0.0.1:$p80$1" 2>/dev/null || true; }

# ---- 1. before a certificate ----------------------------------------------------------------
start
waitfor srv.log "order failed" 15 || bad "the failing authority did not fail the first order" "$(cat srv.log)"
out=$(curl -s --max-time 5 -i -H "Host: $host" "http://127.0.0.1:$p80/" 2>/dev/null | tr -d '\r' || true)
case "$out" in
  "HTTP/1.1 503"*"Retry-After"*) ok "before a certificate the plain port answers 503, with Retry-After" ;;
  *) bad "before a certificate the plain port answered something else" "$(echo "$out" | head -3)" ;;
esac
case "$out" in *"hello over"*) bad "the application was served over plain HTTP" ;; *) ok "and not the application" ;; esac
if echo | timeout 5 openssl s_client -connect "127.0.0.1:$p443" -servername "$host" >/dev/null 2>&1; then
  bad "a handshake completed without a certificate"
else ok "and a TLS handshake is closed at once"; fi
kill -0 "$SRV" 2>/dev/null && ok "the server carries on" || bad "the server died before its certificate"

# ---- 2. the order, through the loop ---------------------------------------------------------
rm -f ca/fail
waitfor srv.log "certificate installed" 30 && ok "once the authority works, a certificate is ordered and installed" \
  || bad "no certificate was installed" "$(cat srv.log)" "$(tail -5 ca.log)"
grep -q "^VALIDATED" ca.log && ok "the challenge was answered on the plain port while the order was pending" \
  || bad "the authority never saw the token" "$(cat ca.log)"
n=$(chain | grep -c "BEGIN CERTIFICATE" || true)
[ "$n" = 2 ] && ok "port 443 sends the chain: its certificate and the intermediate" \
             || bad "port 443 sends $n certificate(s); a browser needs the intermediate too"

# ---- 3. a client that trusts only the root ---------------------------------------------------
body=$(curl -s --http1.1 --max-time 10 --resolve "$host:$p443:127.0.0.1" --cacert root.pem "https://$host:$p443/" 2>&1 || true)
case "$body" in
  *"hello over a certificate of mine"*) ok "a client that trusts only the root is served over HTTPS" ;;
  *) bad "a client trusting only the root was not served" "$body" ;;
esac

# ---- 4. the plain port now redirects ------------------------------------------------------------
r=$(plain "/some/page?x=1")
[ "$r" = "301 https://$host:$p443/some/page?x=1" ] && ok "the plain port now redirects: $r" \
  || bad "the plain port does not redirect to https" "got: $r"
r=$(plain "/.well-known/acme-challenge/not-the-token")
case "$r" in "404 "*) ok "a token that is not the order's is a 404, also after the order" ;;
  *) bad "an unknown token got: $r" ;; esac
stop

# ---- 5. a restart orders nothing ---------------------------------------------------------------
before=$(orders)
start
waitfor srv.log "loaded from the store" 10 && ok "a restart installs the certificate from the store" \
  || bad "the stored certificate was not loaded" "$(cat srv.log)"
sleep 2
[ "$(orders)" = "$before" ] && ok "and places no new order" || bad "a restart ordered again ($before -> $(orders))"
body=$(curl -s --http1.1 --max-time 10 --resolve "$host:$p443:127.0.0.1" --cacert root.pem "https://$host:$p443/" 2>&1 || true)
case "$body" in *"hello over"*) ok "and serves it at once" ;; *) bad "after a restart nothing is served" "$body" ;; esac
stop

echo "http_https_acme: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
