# lib/p384.wz: ECDSA P-384 verification, against signatures OpenSSL made.
#
# TOETSGROEP: lib
# DEKT: lib/p384.wz
#
# WHY P-384 IS HERE. Measured 22-09-2026: the intermediates and roots of github.com,
# cloudflare.com and letsencrypt.org all sign with ecdsa-with-SHA384 over P-384. Only
# google.com's chain is pure RSA. So three of four real chains need this.
#
# VERIFICATION ONLY -- lib/p384.wz does not sign, unlike lib/p256.wz which does. So this
# file is shorter than tests/lib/p256.sh by exactly the signing half, and that is not an
# omission: nothing in the stack needs a P-384 signature, and a signer has constant-time
# obligations that a verifier does not.
#
# A FRESH KEY AND SIGNATURE EVERY RUN. A stored vector proves only that the verifier agrees
# with one transcription, and a mistyped vector costs a round of chasing a bug that is not
# there.
#
# THE FAST REDUCTION IS CHECKED AGAINST THE SLOW ONE, and that is the heart of this file.
# The Solinas reduction for P-384 (FIPS 186-4 D.2.4) is nine terms of shuffled 32-bit words,
# one doubled and three subtracted. One word in the wrong place gives a result that is still
# a plausible field element -- and in a verifier that means accepting signatures that should
# be refused. The slow reduction is correct by construction; the fast one is correct because
# it agrees with it on random products.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so there is nothing to sign with"
  exit 0
fi

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

openssl ecparam -name secp384r1 -genkey -noout -out "$tmp/ec.pem" 2>/dev/null
printf 'hello wantzel p384' > "$tmp/msg.txt"
openssl dgst -sha384 -sign "$tmp/ec.pem" -out "$tmp/sig.der" "$tmp/msg.txt" 2>/dev/null
openssl ec -in "$tmp/ec.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null
openssl dgst -sha384 -verify "$tmp/pub.pem" -signature "$tmp/sig.der" "$tmp/msg.txt" >/dev/null 2>&1 \
  || { echo "  FAIL  openssl cannot verify its own signature"; exit 1; }
ok "openssl made a P-384 signature and verifies it itself"

hash=$(openssl dgst -sha384 -binary "$tmp/msg.txt" | xxd -p -c48)
# The uncompressed public key is 04 || X || Y; the last 192 hex characters are X and Y.
pub=$(openssl ec -in "$tmp/ec.pem" -pubout -outform DER 2>/dev/null | xxd -p -c400 | tail -c 193)
qx=$(echo "$pub" | cut -c1-96)
qy=$(echo "$pub" | cut -c97-192)
rs=$(openssl asn1parse -inform DER -in "$tmp/sig.der" 2>/dev/null | grep INTEGER | sed 's/.*://')
sr=$(echo "$rs" | head -1 | tr 'A-F' 'a-f')
ss=$(echo "$rs" | tail -1 | tr 'A-F' 'a-f')
# openssl prints them without leading zeros; a 47-byte r is normal and happens often.
pad() { printf '%096s' "$1" | tr ' ' '0'; }
sr=$(pad "$sr"); ss=$(pad "$ss")

cat > "$tmp/t.wz" <<WZ
include "io.wz";
include "p384.wz";
var e, r, s, qx, qy, bad1: array[0..Q.N-1] of int;
    a, b, slow, fast: array[0..Q.N-1] of int;
    rb: array[0..47] of char;
    failures, i, diffs: int;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what); io.puts(STDOUT, "\n");
end;
begin
  failures := 0;
  p384.setup;
  p384.hexto(e,  "$hash");
  p384.hexto(qx, "$qx");
  p384.hexto(qy, "$qy");
  p384.hexto(r,  "$sr");
  p384.hexto(s,  "$ss");

  // The parameters first: if G is not on its own curve they were typed wrong and every
  // result below is meaningless.
  expect(p384.oncurve(p384.gx, p384.gy), "the base point G is on the curve");
  expect(p384.oncurve(qx, qy), "and openssl's public key is on the curve");

  expect(p384.verify(qx, qy, e, r, s), "a genuine openssl P-384 signature verifies");

  // ---- THE REFUSALS. A verifier that returned true always passes the check above.
  p384.copy(bad1, e); bad1[0] := bxor(bad1[0], 1);
  expect(not p384.verify(qx, qy, bad1, r, s), "a flipped bit in the hash is refused");
  p384.copy(bad1, r); bad1[0] := bxor(bad1[0], 1);
  expect(not p384.verify(qx, qy, e, bad1, s), "a flipped bit in r is refused");
  p384.copy(bad1, s); bad1[0] := bxor(bad1[0], 1);
  expect(not p384.verify(qx, qy, e, r, bad1), "a flipped bit in s is refused");

  // THE SAME SIGNATURE UNDER ANOTHER KEY. G is a perfectly valid point, just not the one
  // that signed -- this is what proves the verifier uses the key it was given.
  expect(not p384.verify(p384.gx, p384.gy, e, r, s), "the signature under another key is refused");

  // OUT OF RANGE. r and s must lie in 1..n-1; zero is the classic case a lazy verifier lets
  // through, and an optimisation that returns 0 for 1/0 turns it into an acceptance.
  p384.zero(bad1);
  expect(not p384.verify(qx, qy, e, bad1, s), "r = 0 is refused");
  expect(not p384.verify(qx, qy, e, r, bad1), "s = 0 is refused");

  // ---- SIGN AND GENKEY, ROUND TRIP --------------------------------------------------------
  // A key made here signs, and verify accepts it. Before this test, nothing called genkey or
  // sign with a real key, and both read 48 bytes from a 32-byte buffer.
  expect(p384.genkey(a, qx, qy), "genkey makes a key");
  expect(p384.oncurve(qx, qy), "the public half of a fresh key is on the curve");
  expect(p384.sign(a, e), "sign with that key succeeds");
  p384.copy(r, p384.sigr); p384.copy(s, p384.sigs);
  expect(p384.verify(qx, qy, e, r, s), "and verify accepts our own signature");
  p384.copy(bad1, e); bad1[0] := bxor(bad1[0], 1);
  expect(not p384.verify(qx, qy, bad1, r, s), "but not for another hash");

  // ---- THE FAST REDUCTION AGAINST THE SLOW ONE ------------------------------------------
  //
  // This is what makes the rest trustworthy. 200 random products; the two must agree on
  // every one. The slow reduction is obviously correct (long division, one bit at a time);
  // the fast one is nine shuffles of words from the standard.
  diffs := 0;
  i := 0;
  while i < 200 do
  begin
    rand.bytes(rb); p384.frombytes(a, rb, 0);
    rand.bytes(rb); p384.frombytes(b, rb, 0);
    p384.mul512(a, b); p384.redc(slow, p384.p);
    p384.mul512(a, b); p384.redfast(fast);
    if p384.cmp(slow, fast) <> 0 then diffs := diffs + 1;
    i := i + 1;
  end;
  expect(diffs = 0, "the Solinas reduction agrees with the slow one on 200 products");

  if failures = 0 then io.puts(STDOUT, "ALLGOOD\n");
end.
WZ

"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  the test program does not compile"; cat "$tmp/build.log"; exit 1; }
"$tmp/t" > "$tmp/out.txt" 2>&1 || true

while read -r line; do
  case "$line" in
    "ok   "*) ok "${line#ok   }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done < "$tmp/out.txt"

grep -q ALLGOOD "$tmp/out.txt" || { echo "  FAIL  the test program did not run to the end"; fail=$((fail+1)); }

echo "p384: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
