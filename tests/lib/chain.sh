# lib/chain.wz: does a certificate chain up to a root we trust?
#
# TOETSGROEP: lib
# DEKT: lib/chain.wz lib/x509.wz lib/rsa.wz lib/p256.wz
#
# THE CHAIN IS BUILT FRESH EVERY RUN by OpenSSL: an RSA root, an RSA intermediate and an EC
# leaf. That mix is deliberate -- it exercises BOTH verifiers in one chain, which is also
# what a real Let's Encrypt chain looks like.
#
# OPENSSL VERIFIES ITS OWN CHAIN FIRST. If that fails the rest proves nothing, and the fault
# is in this script rather than in lib/.
#
# THE TEST THAT MATTERS IS NUMBER 2: a FORGED chain, for the same hostname, signed by a root
# the attacker generated. Everything about it is internally perfect -- the names match, the
# signatures verify, the dates are right. Only the trust store distinguishes it from the real
# one. A verifier that checks signatures but not the root accepts it, and that is the whole
# failure mode this file exists to catch.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so there is nothing to build a chain with"
  exit 0
fi

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT
cd "$tmp"

ext_ca=$tmp/ca.ext;   printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$ext_ca"
ext_leaf=$tmp/lf.ext; printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:local.wantzel.com\n' > "$ext_leaf"

openssl genrsa -out root.key 2048 2>/dev/null
openssl req -x509 -new -key root.key -sha256 -days 3650 -subj "/CN=Test Root" -out root.crt 2>/dev/null
openssl genrsa -out int.key 2048 2>/dev/null
openssl req -new -key int.key -subj "/CN=Test Intermediate" -out int.csr 2>/dev/null
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial -days 1825 -sha256 \
  -extfile "$ext_ca" -out int.crt 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key 2>/dev/null
openssl req -new -key leaf.key -subj "/CN=local.wantzel.com" -out leaf.csr 2>/dev/null
openssl x509 -req -in leaf.csr -CA int.crt -CAkey int.key -CAcreateserial -days 365 -sha256 \
  -extfile "$ext_leaf" -out leaf.crt 2>/dev/null

# THE FORGERY: a root nobody knows, and a leaf for the same name under it.
openssl genrsa -out evil.key 2048 2>/dev/null
openssl req -x509 -new -key evil.key -sha256 -days 3650 -subj "/CN=Evil Root" -out evil.crt 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out fake.key 2>/dev/null
openssl req -new -key fake.key -subj "/CN=local.wantzel.com" -out fake.csr 2>/dev/null
openssl x509 -req -in fake.csr -CA evil.crt -CAkey evil.key -CAcreateserial -days 365 -sha256 \
  -extfile "$ext_leaf" -out fake.crt 2>/dev/null

# A "CA" THAT IS NOT ONE. notca.crt is signed by the root but has CA:FALSE, and it signs a
# leaf anyway. Every signature in that chain verifies and it ends at a trusted root -- only
# the basicConstraints rule refuses it. Without that rule, anyone holding an ordinary
# certificate for their own domain could issue one for any other domain.
openssl genrsa -out notca.key 2048 2>/dev/null
openssl req -new -key notca.key -subj "/CN=Not A CA" -out notca.csr 2>/dev/null
openssl x509 -req -in notca.csr -CA root.crt -CAkey root.key -CAcreateserial -days 1825 -sha256 \
  -extfile "$ext_leaf" -out notca.crt 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out sub.key 2>/dev/null
openssl req -new -key sub.key -subj "/CN=local.wantzel.com" -out sub.csr 2>/dev/null
openssl x509 -req -in sub.csr -CA notca.crt -CAkey notca.key -CAcreateserial -days 365 -sha256 \
  -extfile "$ext_leaf" -out sub.crt 2>/dev/null

openssl verify -CAfile root.crt -untrusted int.crt leaf.crt >/dev/null 2>&1 \
  || { echo "  FAIL  openssl cannot verify the chain it just built"; exit 1; }
ok "openssl built a chain and verifies it itself"

for f in root int leaf evil fake notca sub; do openssl x509 -in $f.crt -outform DER -out $f.der 2>/dev/null; done
hexesc() { xxd -p -c100000 "$1" | sed 's/\(..\)/\\x\1/g'; }
LEAF=$(hexesc leaf.der); INT=$(hexesc int.der); ROOT=$(hexesc root.der)
FAKE=$(hexesc fake.der); EVIL=$(hexesc evil.der)
nleaf=$(stat -c%s leaf.der); nint=$(stat -c%s int.der); nroot=$(stat -c%s root.der)
nfake=$(stat -c%s fake.der); nevil=$(stat -c%s evil.der)
NOTCA=$(hexesc notca.der); SUB=$(hexesc sub.der)
nnotca=$(stat -c%s notca.der); nsub=$(stat -c%s sub.der)

cat > "$tmp/t.wz" <<WZ
import io;
import chain;
var cb, fb, nb: array[0..8191] of char;
    rb: array[0..4095] of char;
    hb: array[0..63] of char;
    n, hn, failures: int;

procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what); io.puts(STDOUT, "\n");
end;

begin
  failures := 0;
  n  := io.push(cb, 0, "$LEAF$INT");
  n  := io.push(fb, 0, "$FAKE$EVIL");
  n  := io.push(nb, 0, "$SUB$NOTCA");
  n  := io.push(rb, 0, "$ROOT");
  hn := io.push(hb, 0, "local.wantzel.com");

  ch.clearroots;
  expect(ch.addroot(rb, 0, $nroot), "the real root goes into the store");

  ch.reset;
  if not ch.setcert(0, 0, $nleaf) then halt(1);
  if not ch.setcert(1, $nleaf, $nint) then halt(1);
  expect(ch.verify(cb, hb, hn, 0), "the genuine chain is accepted");

  // THE ONE THAT MATTERS. Same hostname, perfect internally, unknown root.
  ch.reset;
  if not ch.setcert(0, 0, $nfake) then halt(1);
  if not ch.setcert(1, $nfake, $nevil) then halt(1);
  expect(not ch.verify(fb, hb, hn, 0), "a chain under an UNKNOWN root is refused");

  hn := io.push(hb, 0, "anders.wantzel.com");
  ch.reset;
  if not ch.setcert(0, 0, $nleaf) then halt(1);
  if not ch.setcert(1, $nleaf, $nint) then halt(1);
  expect(not ch.verify(cb, hb, hn, 0), "a different hostname is refused");

  // NO INTERMEDIATE: nothing in the store signed the leaf directly.
  hn := io.push(hb, 0, "local.wantzel.com");
  ch.reset;
  if not ch.setcert(0, 0, $nleaf) then halt(1);
  expect(not ch.verify(cb, hb, hn, 0), "a chain missing its intermediate is refused");

  ch.reset;
  if not ch.setcert(0, 0, $nleaf) then halt(1);
  if not ch.setcert(1, $nleaf, $nint) then halt(1);
  cb[400] := chr(bxor(ord(cb[400]), 1));
  expect(not ch.verify(cb, hb, hn, 0), "a flipped bit in the leaf is refused");
  cb[400] := chr(bxor(ord(cb[400]), 1));
  expect(ch.verify(cb, hb, hn, 0), "and once undone it verifies again");

  // AN ISSUER THAT IS NOT A CA. Every signature here verifies and it reaches the real root;
  // only basicConstraints says no.
  ch.reset;
  if not ch.setcert(0, 0, $nsub) then halt(1);
  if not ch.setcert(1, $nsub, $nnotca) then halt(1);
  expect(not ch.verify(nb, hb, hn, 0), "an issuer without CA:TRUE is refused");

  // AN EMPTY TRUST STORE trusts nothing, including what it trusted a moment ago.
  ch.clearroots;
  ch.reset;
  if not ch.setcert(0, 0, $nleaf) then halt(1);
  if not ch.setcert(1, $nleaf, $nint) then halt(1);
  expect(not ch.verify(cb, hb, hn, 0), "an empty trust store accepts nothing");

  if failures = 0 then io.puts(STDOUT, "ALLGOOD\n");
end.
WZ

"$here/bin/wantzel" "$tmp/t.wz" t >build.log 2>&1 \
  || { echo "  FAIL  the test program does not compile"; cat build.log; exit 1; }
./t > out.txt 2>&1 || true

while read -r line; do
  case "$line" in
    "ok   "*) ok "${line#ok   }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done < out.txt

grep -q ALLGOOD out.txt || { echo "  FAIL  the test program did not run to the end"; fail=$((fail+1)); }

echo "chain: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
