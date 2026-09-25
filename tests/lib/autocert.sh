# lib/autocert.wz: a server that gets its certificate and keeps it, run through its whole life
# against a local authority over HTTPS -- no internet.
#
# THE PIECES. examples/autocertd.wz is the server under test: one loop, port 80 and 443, the
# module stepped from its timer. tests/helpers/acmesrv.wz is the authority, in the mode that
# behaves like a real one: it validates LATER, from a child process, so the challenge is only
# answered if the server keeps serving port 80 while its order is pending. In front of it,
# tests/helpers/tlsfront.wz speaks HTTPS with a certificate from a test CA that openssl makes
# here -- so the client has to verify a real chain, and does. openssl also judges what comes
# out: the stored key and chain, and the certificate actually served on 443.
#
# WHAT IS ESTABLISHED, one phase each:
#   1. first issuance: challenge answered while pending, stored 0700/0600, served on 443
#   2. a restart with a valid certificate on disk places NO new order
#   3. a certificate close to expiry is served at once AND renewed, without a restart
#   4. the authority failing: the old certificate stays, retries back off (1 s, then 6 s),
#      the backoff survives a restart, and it recovers when the authority does
#   5. a corrupt store: a fresh account key and a fresh order, not a crash
#   6. a malformed reply in the middle of an order fails that order cleanly; the server serves
#      on -- and a certificate issued for a key that is not ours is refused, not served
#   7. an authority whose certificate is not trusted is not talked to
#   8. a read-only store: it works, without a cache, and says so
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/tests/lib/portlib.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed: there is no independent judge of the certificates"
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
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT

# ---- a test CA, and the certificate of the authority's HTTPS front --------------------------
cd "$tmp"
mkdir ca
openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
openssl req -x509 -new -key ca.key -out ca.pem -days 3650 -subj "/CN=Test ACME Root" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl x509 -in ca.pem -outform DER -out ca.der
openssl ecparam -name prime256v1 -genkey -noout -out front.key 2>/dev/null
openssl req -new -key front.key -subj "/CN=ca.example.com" -out front.csr 2>/dev/null
printf 'subjectAltName=DNS:ca.example.com\nbasicConstraints=CA:FALSE\n' > ext.cnf
openssl x509 -req -in front.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 \
  -extfile ext.cnf -outform DER -out front.der 2>/dev/null
hexkey() { openssl ec -in "$1" -text -noout 2>/dev/null | sed -n '/priv:/,/pub:/p' \
           | tr -d ' :\n' | sed 's/priv//;s/pub//' | tail -c 65; }
frontkey=$(hexkey front.key); cakey=$(hexkey ca.key)

"$here/bin/wantzel" "$here/tests/helpers/acmesrv.wz" acmesrv >/dev/null 2>&1 \
  || { echo "  FAIL  the ACME fixture does not compile"; exit 1; }
"$here/bin/wantzel" "$here/tests/helpers/tlsfront.wz" tlsfront >/dev/null 2>&1 \
  || { echo "  FAIL  the TLS front does not compile"; exit 1; }
"$here/bin/wantzel" "$here/examples/autocertd.wz" autocert 2>cerr \
  || { echo "  FAIL  examples/autocertd.wz does not compile"; cat cerr; exit 1; }

( cd ca && exec ../acmesrv "$caport" "$p80" "https://ca.example.com:$frontport" ../ca.der "$cakey" > ../ca.log 2>&1 ) &
started="$started $!"
./tlsfront "$frontport" "$caport" front.der "$frontkey" > front.log 2>&1 &
started="$started $!"

# waitfor <file> <text> <seconds>: until the text is in the file, or the time is up.
waitfor() {
  n=0; lim=$(( $3 * 10 ))
  while [ $n -lt $lim ]; do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
waitfor ca.log LISTENING 10 && waitfor front.log LISTENING 10 \
  || { echo "  FAIL  the authority never started"; cat ca.log front.log; exit 1; }

# The server under test, with its log in srv.log (fresh per start). Extra options follow.
start() {
  store=$1; shift
  : > srv.log
  ./autocert "$p80" "$p443" "$host" --directory "https://ca.example.com:$frontport/directory" \
    --pin ca.example.com=127.0.0.1 --store "$store" "$@" > srv.out 2> srv.log &
  SRV=$!
  waitfor srv.out LISTENING 10 || { bad "the server did not start" "$(cat srv.log)"; exit 1; }
}
stop() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }; SRV=""; }
orders() { grep -c "^ORDER" ca.log || true; }
served() { echo | timeout 10 openssl s_client -connect "127.0.0.1:$p443" -servername "$host" -tls1_3 \
             -ciphersuites TLS_CHACHA20_POLY1305_SHA256 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null; }
stored() { openssl x509 -in "$1/$host.pem" -noout -fingerprint -sha256 2>/dev/null; }
alive() { kill -0 "$SRV" 2>/dev/null; }

# ---- 1. first issuance -----------------------------------------------------------------------
echo 0 > ca/age
start store --ca ca.pem --check 3600 --retry 1
if waitfor srv.log "certificate installed" 30; then ok "a first certificate was ordered and installed"
else bad "no certificate was installed" "$(cat srv.log)" "$(cat ca.log)"; fi

# THE CHALLENGE WAS ANSWERED WHILE THE ORDER WAS PENDING. The authority fetched it from a
# child AFTER it had answered the challenge request, so the only way VALIDATED appears is a
# server that went back to serving port 80 between its own requests.
if grep -q "^VALIDATED" ca.log; then ok "the authority's fetch of the token was answered while the order was pending"
else bad "the authority never saw the token" "$(cat ca.log)"; fi
[ "$(orders)" = 1 ] && ok "exactly one order" || bad "expected one order, got $(orders)"

mode=$(stat -c %a store 2>/dev/null || echo none); fmode=$(stat -c %a "store/$host.pem" 2>/dev/null || echo none)
amode=$(stat -c %a store/account.key 2>/dev/null || echo none)
if [ "$mode" = 700 ] && [ "$fmode" = 600 ] && [ "$amode" = 600 ]; then ok "the store is 0700 and its files 0600"
else bad "the store is readable by others" "dir $mode, cert $fmode, account $amode"; fi

txt=$(openssl x509 -in "store/$host.pem" -noout -text 2>&1 || true)
case "$txt" in *"DNS:$host"*) ok "openssl reads the stored certificate, for $host" ;;
  *) bad "the stored certificate is not for $host" "$(echo "$txt" | head -3)" ;; esac
if openssl verify -CAfile ca.pem "store/$host.pem" >/dev/null 2>&1; then ok "and it verifies against the CA that issued it"
else bad "the stored certificate does not verify"; fi
kp=$(openssl ec -in "store/$host.pem" -pubout 2>/dev/null | md5sum)
cp=$(openssl x509 -in "store/$host.pem" -pubkey -noout 2>/dev/null | md5sum)
[ "$kp" = "$cp" ] && ok "the stored key is the certificate's key" || bad "the stored key does not match the certificate"
openssl ec -in store/account.key -noout -check >/dev/null 2>&1 \
  && ok "the account key is a valid EC key" || bad "the account key does not read as an EC key"

first=$(stored store)
[ -n "$first" ] && [ "$(served)" = "$first" ] && ok "port 443 serves exactly that certificate" \
  || bad "port 443 does not serve the stored certificate" "stored: $first" "served: $(served)"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p80/.well-known/acme-challenge/nosuchtoken" || true)
[ "$code" = 404 ] && ok "an unknown challenge token is a 404" || bad "an unknown token got $code"
stop

# ---- 2. restart with a valid certificate: no order -------------------------------------------
start store --ca ca.pem --check 1 --retry 1
waitfor srv.log "loaded from the store" 10 && ok "a restart loads the certificate from the store" \
  || bad "the certificate was not loaded" "$(cat srv.log)"
sleep 3                                # three checks, a second apart
[ "$(orders)" = 1 ] && ok "and places no new order, through three checks" \
  || bad "a restart ordered again: the rate limit would lock this service out" "$(cat srv.log)"
[ "$(served)" = "$first" ] && ok "and serves the stored certificate" || bad "a restart serves something else"
stop

# ---- 3. near expiry: served at once, renewed without a restart --------------------------------
# A certificate with 20 of its 90 days left comes first (age 70), from a store without one.
rm -f "store/$host.pem"
echo 70 > ca/age
start store --ca ca.pem --check 3600 --retry 1
waitfor srv.log "certificate installed" 30 || bad "the near-expiry certificate was not issued" "$(cat srv.log)"
grep -q "no certificate in the store" srv.log && ok "a missing certificate is ordered afresh" \
  || bad "the missing certificate was not noticed" "$(cat srv.log)"
stop
cp "store/$host.pem" due.pem 2>/dev/null || bad "there is no near-expiry certificate to work with"
due=$(stored store)
echo 0 > ca/age
start store --ca ca.pem --check 3600 --retry 1
waitfor srv.log "renewing:" 10 && ok "a certificate with 19 days left is due for renewal" \
  || bad "the near-expiry certificate was not renewed" "$(cat srv.log)"
grep -q "loaded from the store" srv.log && ok "and it was served while the renewal ran" \
  || bad "the old certificate was not installed first" "$(cat srv.log)"
waitfor srv.log "certificate installed" 30 || bad "the renewal did not complete" "$(cat srv.log)"
renewed=$(stored store)
[ "$(orders)" = 3 ] && ok "the renewal is one order" || bad "expected 3 orders so far, got $(orders)"
[ -n "$renewed" ] && [ "$renewed" != "$due" ] && [ "$(served)" = "$renewed" ] \
  && ok "port 443 now serves the renewed certificate, without a restart" \
  || bad "the renewed certificate is not what is served" "due: $due" "renewed: $renewed" "served: $(served)"
stop

# ---- 4. the authority fails: old certificate kept, backoff, recovery ---------------------------
cp due.pem "store/$host.pem" 2>/dev/null || true
touch ca/fail
start store --ca ca.pem --check 1 --retry 1
waitfor srv.log "next attempt in 1 s" 15 && ok "a failed renewal is retried after the first backoff (1 s)" \
  || bad "no first retry" "$(cat srv.log)"
grep -q "the current certificate stays in use" srv.log && ok "and the log says the old certificate stays" \
  || bad "the log does not say what is served" "$(cat srv.log)"
waitfor srv.log "next attempt in 6 s" 5 && ok "the second retry waits longer (6 s)" \
  || bad "the backoff did not grow" "$(cat srv.log)"
[ "$(served)" = "$due" ] && ok "the old certificate is still served while the authority fails" \
  || bad "the old certificate was dropped" "due: $due" "served: $(served)"
[ "$(stored store)" = "$due" ] && ok "and the store still holds it" || bad "a failed renewal changed the store"
nfail=$(grep -c "order failed" srv.log || true)
sleep 2
[ "$(grep -c "order failed" srv.log || true)" = "$nfail" ] && ok "no attempt before the backoff is over" \
  || bad "an attempt came before the backoff ended" "$(cat srv.log)"
# THE BACKOFF SURVIVES A RESTART: a crash-looping service must not hammer the authority.
stop
start store --ca ca.pem --check 1 --retry 1
waitfor srv.log "an earlier attempt failed" 5 && ok "a restart keeps to the backoff it was in" \
  || bad "a restart forgot the backoff" "$(cat srv.log)"
rm -f ca/fail
waitfor srv.log "certificate installed" 30 && ok "and it recovers when the authority does" \
  || bad "no recovery after the authority came back" "$(cat srv.log)"
[ "$(served)" = "$(stored store)" ] && [ "$(served)" != "$due" ] && ok "serving the new certificate" \
  || bad "after recovery the served certificate is not the new one"
stop

# ---- 5. a corrupt store: a fresh start, not a crash ----------------------------------------------
before=$(orders)
printf 'not a key\n' > store/account.key
printf 'not a certificate\n' > "store/$host.pem"
start store --ca ca.pem --check 3600 --retry 1
waitfor srv.log "certificate installed" 30 && ok "a corrupt store leads to a fresh order" \
  || bad "a corrupt store was not recovered from" "$(cat srv.log)"
grep -q "account key is unreadable" srv.log && grep -q "account key created" srv.log \
  && ok "with a new account key, since the old one was unreadable" || bad "the corrupt account key was not replaced" "$(cat srv.log)"
[ "$(orders)" = $((before + 1)) ] && ok "one order for it" || bad "expected one more order"
openssl ec -in store/account.key -noout -check >/dev/null 2>&1 && ok "and the new account key is stored" \
  || bad "the new account key was not stored"
stop

# ---- 6. a malformed reply in the middle of an order ------------------------------------------------
echo /authz/1 > ca/garbage
start store6 --ca ca.pem --check 3600 --retry 5
waitfor srv.log "order failed" 15 && ok "a malformed authorization fails the order" \
  || bad "the malformed reply did not fail the order" "$(cat srv.log)"
alive && ok "and the server is still running" || bad "the server died on a malformed reply"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p80/" || true)
[ "$code" = 503 ] && ok "still answering port 80" || bad "port 80 got $code after the failure"
rm -f ca/garbage
stop

# ---- 6b. a certificate for someone else's key is not served ----------------------------------------
touch ca/wrongkey
start store6b --ca ca.pem --check 3600 --retry 5
waitfor srv.log "order failed" 30 && grep -q "for a different key" srv.log \
  && ok "an issued certificate for a key that is not ours is refused" \
  || bad "a certificate for a foreign key was not caught" "$(cat srv.log)"
[ ! -f "store6b/$host.pem" ] && ! grep -q "certificate installed" srv.log \
  && ok "and neither stored nor served" || bad "the foreign-key certificate was kept" "$(cat srv.log)"
rm -f ca/wrongkey
stop

# ---- 7. an authority whose certificate is not trusted ----------------------------------------------
# No --ca: the trust store is the machine's, which has never heard of the test CA.
before=$(orders)
start store7 --check 3600 --retry 5
waitfor srv.log "not trusted" 15 && ok "an authority with an untrusted certificate is refused" \
  || bad "the untrusted authority was not refused" "$(cat srv.log)"
[ "$(orders)" = "$before" ] && ! grep -q "account key created" srv.log \
  && ok "and nothing was sent to it" || bad "requests went to an untrusted authority" "$(cat srv.log)"
stop

# ---- 8. a read-only store ---------------------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then
  echo "  skip  a read-only store: running as root, which can write anywhere"
else
  mkdir store8; chmod 500 store8
  start store8 --ca ca.pem --check 3600 --retry 1
  waitfor srv.log "certificate installed" 30 && ok "a read-only store still gets a certificate" \
    || bad "a read-only store stopped the service" "$(cat srv.log)"
  grep -q "without a cache" srv.log && ok "and the log says there is no cache" \
    || bad "the read-only store went unmentioned" "$(cat srv.log)"
  stop
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
