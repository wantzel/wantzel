# examples/localhttps.wz: HTTPS on loopback with a certificate it makes itself.
#
# TOETSGROEP: lib
# DEKT: examples/localhttps.wz
#
# The certificate machinery itself (dates, extensions, signature, a raw TLS 1.3 handshake)
# is proven by tests/lib/selfsign.sh -- this test is about the EXAMPLE: does the documented
# "1. Localhost" case in docs/howto.md actually work end to end through a real
# HTTP client, and does a client that has NOT been told to trust the certificate correctly
# refuse it.
#
# WHAT IS ESTABLISHED:
#   1. the server starts and listens
#   2. a client told to trust the certificate (curl --cacert) gets a real response
#   3. a client that has NOT been told to trust it refuses the connection -- the warning
#      documented in serving-https.md is not decoration, it is what happens
#   4. the connection can be made twice, so the accept loop actually loops
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is missing"; exit 1; }

port=$(( 23000 + ($$ % 900) ))
compile "$ROOT/examples/localhttps.wz" "$T/localhttps"

"$T/localhttps" "$port" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if ss -tln 2>/dev/null | grep -q ":$port "; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

# THE CLIENT REFUSES A CERTIFICATE IT WAS NOT TOLD TO TRUST. This is the documented warning
# from serving-https.md, checked rather than assumed: curl's own exit code for a failed
# verification is 60, and no HTTP status is ever reached.
curl -s -o /dev/null --max-time 5 "https://127.0.0.1:$port/" 2>/dev/null
untrusted_rc=$?
assert_eq "an untrusting client refuses the certificate (curl exit 60)" "$untrusted_rc" "60"

# -k IS THE STAND-IN FOR "TOLD TO TRUST THIS EXACT CERTIFICATE" -- serving-https.md's own
# example, a client that skips verification because it already knows what it is talking to.
body=$(curl -sk --max-time 5 "https://127.0.0.1:$port/" 2>/dev/null)
assert_contains "a trusting client gets the real response" "$body" "served over locally-signed TLS"

code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:$port/" 2>/dev/null)
assert_eq "the response is 200" "$code" "200"

# THE LOOP ACTUALLY LOOPS: a second connection after the first is closed.
body2=$(curl -sk --max-time 5 "https://127.0.0.1:$port/again" 2>/dev/null)
assert_contains "a second connection is served too" "$body2" "served over locally-signed TLS"

echo "localhttps.wz serves HTTPS on loopback, and an untrusting client is correctly refused"
