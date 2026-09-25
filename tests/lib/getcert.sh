# The whole ACME exchange, both ends written here, no external dependency.
#
# WHAT THIS ESTABLISHES that no other test can: that a client walks the protocol from
# directory to certificate. Every step is checkable on its own -- the JWS, the thumbprint,
# the CSR -- and all of them passing still leaves the question of whether the sequence works.
# That is the "a complete model nobody calls" shape, and this is the call.
#
# BOTH ENDS ARE OURS, AND THAT IS DELIBERATE RATHER THAN A COMPROMISE. Let's Encrypt publishes
# Pebble for exactly this, but it is a Go binary fetched through Docker -- the kind of
# dependency this stack exists to avoid. openssl earns its place in these tests because it
# gives an INDEPENDENT JUDGEMENT on what we produce; a protocol fixture gives no judgement, it
# only has to speak. So the fixture is ours, and openssl still judges the certificate at the
# end, which is where judgement actually matters.
#
# THE FIXTURE REALLY FETCHES THE CHALLENGE. When the client says the token is published, the
# server opens a connection and reads it back, and refuses the order when it does not match.
# A fixture that simply answered "validated" would let a client that never serves the token
# pass -- which is the single most important thing here to get wrong.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/tests/lib/portlib.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d)
set -- $(free_ports 2)
caport=$1; chport=$2
started=""
cleanup() {
  rc=$?
  for p in $started; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT

"$here/bin/wantzel" "$here/tests/helpers/acmesrv.wz" "$tmp/acmesrv" >/dev/null 2>&1 \
  || { echo "  FAIL  the ACME fixture does not compile"; exit 1; }
"$here/bin/wantzel" "$here/examples/getcert.wz" "$tmp/getcert" >/dev/null 2>&1 \
  || { echo "  FAIL  examples/getcert.wz does not compile"; exit 1; }
ok "a certificate authority ($(stat -c %s "$tmp/acmesrv") bytes) and a client ($(stat -c %s "$tmp/getcert") bytes) build"

# THE PID IS KEPT, so cleanup can stop the authority. Started as `( ... & )` it was a
# grandchild nobody knew the number of: every run left one behind, listening, and a later
# run landing on the same port would have talked to it.
( cd "$tmp" && exec ./acmesrv "$caport" "$chport" > ca.log 2>&1 ) &
started="$started $!"
i=0
while [ $i -lt 60 ]; do
  ss -tln 2>/dev/null | grep -q ":$caport " && break
  sleep 0.1; i=$((i+1))
done
ss -tln 2>/dev/null | grep -q ":$caport " \
  || { echo "  FAIL  the authority never started listening"; exit 1; }

# ---- the exchange -------------------------------------------------------------------------
out=$( cd "$tmp" && timeout 90 ./getcert 127.0.0.1 "$caport" "$chport" \
       test.example.org floris@wantzel.com 2>"$tmp/err" || true )

case "$out" in
  *"challenge ready"*) ok "the client published the challenge token" ;;
  *) bad "the client never got as far as the challenge" "$(head -2 "$tmp/err")" ;;
esac
case "$out" in
  *CERTIFICATE*) ok "and walked the whole exchange to a certificate" ;;
  *) bad "no certificate came back" "$(head -2 "$tmp/err")" ;;
esac

# THE CERTIFICATE IS READ FROM THE FILE the client wrote, not from its stdout. DER is
# arbitrary bytes and a shell capture mangles it -- measured: openssl said "Could not read
# certificate" about output that was correct when it left the program.

# ---- and openssl judges it -----------------------------------------------------------------
#
# The fixture is ours and proves only that the protocol was followed. Whether what came out
# is a real certificate is a question for something that did not build it.
txt=$(openssl x509 -inform DER -in "$tmp/test.example.org.der" -noout -text 2>&1 || true)
case "$txt" in
  *"Version: 3"*) ok "openssl reads it as a v3 certificate" ;;
  *) bad "openssl cannot read the certificate" "$(echo "$txt" | head -3)" ;;
esac
case "$txt" in
  *"CN = test.example.org"*) ok "for the hostname that was asked for" ;;
  *) bad "the subject is not the requested name" "$(echo "$txt" | grep -i subject | head -2)" ;;
esac

# THE NAME MUST BE IN THE subjectAltName, not only the CN. That is what a client checks and
# what an authority is asked for -- a certificate carrying it only in the CN is useless today.
case "$txt" in
  *"DNS:test.example.org"*) ok "and the name travelled all the way into the subjectAltName" ;;
  *) bad "the requested name is not in the subjectAltName" \
         "the CSR carried it; something between the request and the issued certificate lost it" ;;
esac
case "$txt" in
  *"NIST CURVE: P-256"*) ok "with a P-256 key" ;;
  *) bad "the certificate does not carry a P-256 key" "$(echo "$txt" | grep -i curve)" ;;
esac

# AND IT MUST BE THE KEY THE CLIENT ASKED FOR, not merely a valid one.
#
# MEASURED 22-09-2026: with the authority ignoring the CSR's key and signing its own instead,
# every check above stayed green -- 9 ok, 0 fail. A certificate issued for someone else's key
# is useless in a way that only shows up at the first handshake, long after the exchange
# "succeeded". So the client prints the X it requested and it has to appear in what came back.
want_x=$(printf '%s\n' "$out" | sed -n 's/^PUBKEY //p')
cert_x=$(openssl x509 -inform DER -in "$tmp/test.example.org.der" -noout -pubkey 2>/dev/null \
         | openssl pkey -pubin -outform DER 2>/dev/null | xxd -p -c400 | tail -c 129 | cut -c1-64)
if [ -n "$want_x" ] && [ "$want_x" = "$cert_x" ]; then
  ok "and it is exactly the key the client generated and asked for"
else
  bad "the certificate carries a DIFFERENT key than the one requested" \
      "asked for: $want_x" "got:       $cert_x" \
      "the private half of that key is not ours, so the certificate is unusable"
fi

# ---- A SECOND NAME, so nothing is hard-coded --------------------------------------------------
out2=$( cd "$tmp" && timeout 90 ./getcert 127.0.0.1 "$caport" "$chport" \
        other.example.net test@example.com 2>/dev/null || true )
txt2=$(openssl x509 -inform DER -in "$tmp/other.example.net.der" -noout -text 2>&1 || true)
case "$txt2" in
  *"DNS:other.example.net"*) ok "a second run for another name issues that name" ;;
  *) bad "the second certificate does not carry the second name" "$(echo "$txt2" | grep -A1 Alternative)" ;;
esac

# ---- THE CHALLENGE MUST ACTUALLY BE CHECKED ---------------------------------------------------
#
# The check this whole file turns on. If the authority accepted the order without fetching
# the token, every test above would pass with a client that never serves it -- and the same
# client would fail against a real authority with nothing to explain why.
#
# So: run the client with the challenge listener pointed at a port where nothing answers. The
# order must be refused.
deadport=$(free_port)   # nothing binds this; a kernel-fresh port is guaranteed unheld
out3=$( cd "$tmp" && timeout 60 ./getcert 127.0.0.1 "$caport" "$deadport" \
        never.example.com test@example.com 2>&1 || true )
case "$out3" in
  *CERTIFICATE*)
     bad "a certificate was issued although the token was never served" \
         "the authority is not really fetching the challenge, so none of the above means much" ;;
  *)
     ok "and an order whose token is never served is refused" ;;
esac

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
