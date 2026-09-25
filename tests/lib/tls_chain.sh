# The server sends the whole certificate chain: a client that trusts only the root accepts
# the server exactly when the intermediate is sent along with the leaf.
#
# TOETSGROEP: lib
# DEKT: lib/tls.wz examples/serve.wz
#
# THIS IS HOW A CERTIFICATE FROM AN AUTHORITY ARRIVES: a leaf signed by an intermediate,
# signed by a root the client already has. The client does not have the intermediate, so a
# server that sends only the leaf is refused by every browser and by curl -- while a test
# that trusts the leaf directly would never notice. So the trust anchor here is the root
# alone, and the same server is checked twice: with the leaf only (must fail), then, after
# the chain is swapped in while it runs, with leaf and intermediate (must succeed).
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
  for p in $started; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT
trap 'exit 143' TERM INT

"$here/bin/wantzel" "$here/examples/serve.wz" "$tmp/serve" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  serve.wz does not compile"; cat "$tmp/build.log"; exit 1; }

# ---- a root, an intermediate, a leaf -----------------------------------------------------------
cd "$tmp"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:local.test\n' > leaf.ext
openssl ecparam -name prime256v1 -genkey -noout -out root.key 2>/dev/null
openssl req -x509 -new -key root.key -out root.pem -days 30 -subj "/CN=Test Root" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out inter.key 2>/dev/null
openssl req -new -key inter.key -out inter.csr -subj "/CN=Test Intermediate" 2>/dev/null
openssl x509 -req -in inter.csr -CA root.pem -CAkey root.key -CAcreateserial -out inter.pem \
  -days 30 -extfile ca.ext 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key 2>/dev/null
openssl req -new -key leaf.key -out leaf.csr -subj "/CN=local.test" 2>/dev/null
openssl x509 -req -in leaf.csr -CA inter.pem -CAkey inter.key -CAcreateserial -out leaf.pem \
  -days 30 -extfile leaf.ext 2>/dev/null
openssl x509 -in leaf.pem -outform DER -out leaf.der 2>/dev/null
openssl x509 -in inter.pem -outform DER -out inter.der 2>/dev/null
[ -s leaf.der ] && [ -s inter.der ] || { echo "  FAIL  could not make the test chain"; exit 1; }
openssl verify -CAfile root.pem -untrusted inter.pem leaf.pem >/dev/null 2>&1 \
  && ok "a leaf, signed by an intermediate, signed by a root" \
  || { echo "  FAIL  the test chain does not verify on its own"; exit 1; }
h=$(openssl ec -in leaf.key -noout -text 2>/dev/null \
    | awk '/^priv:/{f=1;next} f&&/^[ \t]/{print;next} {f=0}' | tr -dc '0-9a-f')
h=$(printf '%s' "$h" | tail -c 64)
while [ ${#h} -lt 64 ]; do h="0$h"; done

mkdir srv
cp leaf.der srv/cert.der
printf '%s' "$h" > srv/key.hex

set -- $(free_ports 2)
p80=$1; p443=$2
( cd "$tmp/srv" && exec "$tmp/serve" "$p80" "$p443" local.test >"$tmp/serve.log" 2>&1 ) &
started="$started $!"
wait_port "$p443" || { echo "  FAIL  serve did not start"; port_owner "$p443"; cat "$tmp/serve.log"; exit 1; }

get() {
  curl -s --http1.1 --max-time 10 --resolve "local.test:$p443:127.0.0.1" --cacert "$tmp/root.pem" \
    "https://local.test:$p443/" 2>/dev/null || true
}
certs() {   # how many certificates the server sends
  timeout 10 openssl s_client -connect "127.0.0.1:$p443" -servername local.test -tls1_3 -showcerts \
    </dev/null 2>/dev/null | grep -c "BEGIN CERTIFICATE" || true
}

# ---- the leaf alone ----------------------------------------------------------------------------
[ "$(certs)" = "1" ] && ok "with only the leaf installed, one certificate is sent" \
                     || bad "expected one certificate with only the leaf installed"
[ -z "$(get)" ] && ok "and a client that trusts only the root refuses it" \
                || bad "a client trusting only the root accepted a server that sent no intermediate"

# ---- the chain, swapped in while running --------------------------------------------------------
cat leaf.der inter.der > srv/cert.der.new
mv srv/cert.der.new srv/cert.der
i=0; while [ $i -lt 50 ] && ! grep -q "certificate installed" serve.log; do sleep 0.1; i=$((i+1)); done
grep -q "certificate installed" serve.log && ok "leaf and intermediate are installed while the server runs" \
                                          || bad "the chain was not installed" "$(tail -2 serve.log)"
[ "$(certs)" = "2" ] && ok "now both certificates are sent" \
                     || bad "expected two certificates after the chain was installed, got $(certs)"
case "$(get)" in
  *"over its own TLS"*) ok "and a client that trusts only the root accepts the server" ;;
  *) bad "a client trusting only the root still refused the server with its chain" ;;
esac

echo "tls_chain: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
