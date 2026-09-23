# lib/p256.wz: ECDSA P-256 verification, against signatures OpenSSL made.
#
# WHY A FRESH SIGNATURE EACH RUN rather than a hard-coded vector. A stored vector proves the
# verifier agrees with one transcription -- and I have twice transcribed a published vector
# wrongly while the implementation was right, which costs a round of chasing a bug that is
# not there. Here OpenSSL signs a message, says "Verified OK" about its own signature, and
# then our verifier has to agree. The key, the hash and the signature all change every run,
# so an accidental agreement cannot survive.
#
# WHAT IS ESTABLISHED:
#   1. a genuine signature verifies
#   2. the REFUSALS, which are the whole point -- a verifier that returns true always would
#      pass check 1 and nothing else:
#        - a flipped bit in the hash
#        - a flipped bit in r, and in s
#        - the signature presented against a different public key
#        - s = 0 and r = 0, which are out of range
#        - a public key that is not on the curve
#
# THAT LAST ONE IS AN ATTACK, not a typo: an invalid-curve attack feeds a point from a
# different, weaker curve and reads information out of the result.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so there is nothing to sign with"
  exit 0
fi

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ec.pem" 2>/dev/null
printf 'hello wantzel tls' > "$tmp/msg.txt"
openssl dgst -sha256 -sign "$tmp/ec.pem" -out "$tmp/sig.der" "$tmp/msg.txt" 2>/dev/null

# OPENSSL MUST AGREE WITH ITSELF FIRST. If this fails the rest is meaningless, and the
# failure is in the test setup rather than in anything being tested.
openssl ec -in "$tmp/ec.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null
openssl dgst -sha256 -verify "$tmp/pub.pem" -signature "$tmp/sig.der" "$tmp/msg.txt" >/dev/null 2>&1 \
  || { echo "  FAIL  openssl cannot verify its own signature"; exit 1; }
ok "openssl made a signature and verifies it itself"

hash=$(openssl dgst -sha256 -binary "$tmp/msg.txt" | xxd -p -c32)
# The uncompressed public key is 04 || X || Y; the last 128 hex characters are X and Y.
pub=$(openssl ec -in "$tmp/ec.pem" -pubout -outform DER 2>/dev/null | xxd -p -c400 | tail -c 129)
qx=$(echo "$pub" | cut -c1-64)
qy=$(echo "$pub" | cut -c65-128)
# r and s out of the DER SEQUENCE. openssl prints them without leading zeros, so they are
# padded back to 64 characters here -- a 31-byte r is perfectly normal and happens often.
rs=$(openssl asn1parse -inform DER -in "$tmp/sig.der" 2>/dev/null | grep INTEGER | sed 's/.*://')
sr=$(echo "$rs" | head -1 | tr 'A-F' 'a-f')
ss=$(echo "$rs" | tail -1 | tr 'A-F' 'a-f')
pad() { printf '%064s' "$1" | tr ' ' '0'; }
sr=$(pad "$sr"); ss=$(pad "$ss")

cat > "$tmp/t.wz" <<WZ
include "io.wz";
include "rand.wz";
include "p256.wz";
var e, r, s, qx, qy, bad1: array[0..P.N-1] of int;
    u, v, slow, fast: array[0..P.N-1] of int;
    sig1r, sig1s: array[0..P.N-1] of int;
    rb: array[0..31] of char;
    failures, i, bad: int;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what);
  io.puts(STDOUT, "\n");
end;
begin
  failures := 0;
  p256.setup;
  p256.hexto(e,  "$hash");
  p256.hexto(qx, "$qx");
  p256.hexto(qy, "$qy");
  p256.hexto(r,  "$sr");
  p256.hexto(s,  "$ss");

  // The base point must be on the curve, or the parameters were typed wrong and every
  // result below is meaningless.
  expect(p256.oncurve(p256.gx, p256.gy), "the base point G is on the curve");
  expect(p256.oncurve(qx, qy), "and openssl's public key is on the curve");

  expect(p256.verify(qx, qy, e, r, s), "a genuine openssl signature verifies");

  // ---- THE REFUSALS ------------------------------------------------------------------------
  //
  // Each of these must be false. A verifier that simply returned true would satisfy the
  // check above and fail every one of these.
  p256.copy(bad1, e);
  bad1[0] := bxor(bad1[0], 1);
  expect(not p256.verify(qx, qy, bad1, r, s), "a flipped bit in the hash is refused");

  p256.copy(bad1, r);
  bad1[0] := bxor(bad1[0], 1);
  expect(not p256.verify(qx, qy, e, bad1, s), "a flipped bit in r is refused");

  p256.copy(bad1, s);
  bad1[0] := bxor(bad1[0], 1);
  expect(not p256.verify(qx, qy, e, r, bad1), "a flipped bit in s is refused");

  // THE SAME SIGNATURE AGAINST ANOTHER KEY. G is a perfectly valid point, just not the one
  // that signed -- this is the check that a verifier is actually using the key.
  expect(not p256.verify(p256.gx, p256.gy, e, r, s),
         "the signature does not verify against a different key");

  // OUT OF RANGE. s = 0 makes 1/s undefined; r = 0 can never be a valid x coordinate; and a
  // value at or above n would let one signature be presented in several forms.
  //
  // HONEST ABOUT WHAT THESE PROVE. Removing p256.inrange from the verifier leaves this file
  // GREEN -- measured 22-09-2026. The reason is that the arithmetic happens to reject these
  // anyway: invm(0) returns 0 by Fermat, so u1 and u2 come out zero, the result is the point
  // at infinity, and the infinity check catches it. The range test is therefore
  // DEFENCE IN DEPTH rather than the thing standing between these inputs and acceptance.
  //
  // It stays, because relying on "the arithmetic happens to" is exactly how a later
  // optimisation (a faster inverse that does not return 0 for 0) turns a refusal into an
  // acceptance. But it is recorded here that this suite cannot tell the difference.
  p256.zero(bad1);
  expect(not p256.verify(qx, qy, e, r, bad1), "s = 0 is refused");
  expect(not p256.verify(qx, qy, e, bad1, s), "r = 0 is refused");
  expect(not p256.verify(qx, qy, e, r, p256.n), "s = n is refused");

  // AND THE RANGE CHECK ITSELF, tested directly rather than through verify, so that removing
  // it does fail something.
  expect(not p256.inrange(bad1), "inrange refuses zero");
  expect(not p256.inrange(p256.n), "inrange refuses n itself");
  expect(p256.inrange(r), "and accepts a genuine r");

  // A KEY OFF THE CURVE. Moving one coordinate by one almost certainly leaves the curve,
  // and an invalid-curve attack is exactly this.
  //
  // SAME CAVEAT AS ABOVE: removing the oncurve call from verify also leaves this file green,
  // because a key one bit off produces a point that fails the final comparison anyway. The
  // check is tested DIRECTLY here so that deleting it fails something, and it stays in
  // verify because "the comparison happens to fail" is not a security property.
  p256.copy(bad1, qy);
  bad1[0] := bxor(bad1[0], 1);
  expect(not p256.oncurve(qx, bad1), "a point off the curve is recognised");
  expect(not p256.verify(qx, bad1, e, r, s), "and a key off the curve is refused");

  // ---- THE NONCE MUST BE FRESH EVERY TIME --------------------------------------------------
  //
  // THE MOST DANGEROUS THING THIS FILE CAN GET WRONG, and it is invisible to every other
  // check: a signature made with a REUSED k is perfectly valid. openssl accepts it, our
  // verifier accepts it, the test vectors say nothing. And yet two signatures sharing a k
  // give away the private key by simple algebra:
  //
  //     k = (e1 - e2) / (s1 - s2)   and then   d = (s*k - e) / r
  //
  // That is how a games console and a cryptocurrency wallet were both broken in public.
  //
  // MEASURED 22-09-2026: replacing the random k with a constant left this file at 18 ok,
  // 0 fail. So it is checked directly -- sign the SAME hash twice and the two signatures
  // must differ, which they cannot if k is fixed.
  if not p256.genkey(u, v, slow) then expect(false, "genkey works");
  p256.hexto(fast, "0000000000000000000000000000000000000000000000000000000000000001");
  if p256.sign(u, fast) then
  begin
    p256.copy(sig1r, p256.sigr);
    p256.copy(sig1s, p256.sigs);
    if p256.sign(u, fast) then
    begin
      // r IS DERIVED ONLY FROM k, so a repeated r means a repeated nonce. Comparing s would
      // not do: s depends on the message, which is the same here anyway.
      expect(p256.cmp(sig1r, p256.sigr) <> 0,
             "signing the same hash twice gives a different nonce");
      // And both must still verify -- a "different" signature that is invalid proves nothing.
      expect(p256.verify(v, slow, fast, sig1r, sig1s), "the first of the two verifies");
      expect(p256.verify(v, slow, fast, p256.sigr, p256.sigs), "and so does the second");
    end
    else expect(false, "the second signature was made");
  end
  else expect(false, "the first signature was made");

  // ---- THE FAST REDUCTION AGREES WITH THE SLOW ONE -----------------------------------------
  //
  // THE ONLY THING GUARDING THE SOLINAS REDUCTION. It is nine shuffles of 32-bit words, two
  // doubled and four subtracted, and one term in the wrong word gives a result that is still
  // a plausible field element -- in a verifier that means accepting signatures that should be
  // refused. The test vectors above would very likely still pass.
  //
  // So the slow bit-by-bit reduction is KEPT, and the two are compared on random input. The
  // slow one is obviously correct by construction; the fast one is correct because it agrees
  // with it everywhere. Random rather than fixed input because the rare cases -- a borrow
  // that propagates, a term that lands just over p -- are exactly where a wrong term hides.
  i := 0;
  bad := 0;
  while i < 500 do
  begin
    rand.bytes(rb);
    p256.frombytes(u, rb, 0);
    rand.bytes(rb);
    p256.frombytes(v, rb, 0);
    while p256.cmp(u, p256.p) >= 0 do p256.subm(u, u, p256.p, p256.p);
    while p256.cmp(v, p256.p) >= 0 do p256.subm(v, v, p256.p, p256.p);
    p256.mul512(u, v);
    p256.redc(slow, p256.p);
    p256.mul512(u, v);
    p256.redfast(fast);
    if p256.cmp(slow, fast) <> 0 then bad := bad + 1;
    i := i + 1;
  end;
  expect(bad = 0, "the fast reduction agrees with the slow one on 500 random products");

  if failures > 0 then halt(1);
end.
WZ

cat > "$tmp/signer.wz" <<WZ
include "io.wz";
include "p256.wz";
var d, qx, qy, e: array[0..P.N-1] of int;
    hash: array[0..31] of char;
    b: array[0..63] of char;
procedure hex(bb: array of char; n: int);
var j, v: int;
begin
  j := 0;
  while j < n do
  begin
    v := ord(bb[j]) shr 4;
    if v < 10 then io.out(STDOUT, sadr("0123456789") + v, 1)
    else io.out(STDOUT, sadr("abcdef") + v - 10, 1);
    v := band(ord(bb[j]), 15);
    if v < 10 then io.out(STDOUT, sadr("0123456789") + v, 1)
    else io.out(STDOUT, sadr("abcdef") + v - 10, 1);
    j := j + 1;
  end;
  io.puts(STDOUT, "\n");
end;
begin
  p256.setup;
  if not p256.genkey(d, qx, qy) then halt(1);
  rand.bytes(hash);
  p256.frombytes(e, hash, 0);
  if not p256.sign(d, e) then halt(1);
  io.puts(STDOUT, "QX "); p256.tobytes(b, 0, qx); hex(b, 32);
  io.puts(STDOUT, "QY "); p256.tobytes(b, 0, qy); hex(b, 32);
  io.puts(STDOUT, "E ");  hex(hash, 32);
  io.puts(STDOUT, "R ");  p256.tobytes(b, 0, p256.sigr); hex(b, 32);
  io.puts(STDOUT, "S ");  p256.tobytes(b, 0, p256.sigs); hex(b, 32);
end.
WZ
"$here/bin/wantzel" "$tmp/signer.wz" "$tmp/signer" >/dev/null 2>&1 \
  || { echo "  FAIL  the signer does not compile"; exit 1; }

"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" >/dev/null 2>&1 \
  || { echo "  FAIL  the test program does not compile"; exit 1; }

out=$("$tmp/t" 2>&1) || true
echo "$out" | sed 's/^/  /'
if echo "$out" | grep -q FAIL; then
  fail=$((fail + $(echo "$out" | grep -c FAIL)))
else
  pass=$((pass + $(echo "$out" | grep -c '^ok')))
fi

# ---- SIGNING, WITH OPENSSL AS THE JUDGE ------------------------------------------------------
#
# Everything above checks the VERIFIER. This checks the SIGNER, and it cannot be done with our
# own verifier: two halves of the same misunderstanding agree perfectly. So we sign here and
# openssl says whether the signature is real.
#
# WHY SIGNING EXISTS AT ALL, since a TLS client never signs: ACME does. Every request to
# Let's Encrypt is a JWS signed with the account key.
sig=$("$tmp/signer" 2>/dev/null) || { bad "the signer did not run"; sig=""; }
if [ -n "$sig" ]; then
  qx=$(echo "$sig" | awk '$1=="QX"{print $2}')
  qy=$(echo "$sig" | awk '$1=="QY"{print $2}')
  eh=$(echo "$sig" | awk '$1=="E"{print $2}')
  rr=$(echo "$sig" | awk '$1=="R"{print $2}')
  sss=$(echo "$sig" | awk '$1=="S"{print $2}')
  # R and S as DER INTEGERs: leading zero bytes dropped, and a 00 put back in front when the
  # top bit is set, or the number would read as negative.
  derint() {
    h=$1
    while [ ${#h} -gt 2 ] && [ "${h#00}" != "$h" ]; do h=${h#00}; done
    case "$h" in [89a-f]*) h="00$h" ;; esac
    printf '02%02x%s' $(( ${#h} / 2 )) "$h"
  }
  body="$(derint "$rr")$(derint "$sss")"
  printf '30%02x%s' $(( ${#body} / 2 )) "$body" | xxd -r -p > "$tmp/our.sig"
  # SubjectPublicKeyInfo for prime256v1, then the uncompressed point.
  printf '%s%s%s' 3059301306072a8648ce3d020106082a8648ce3d03010703420004 "$qx" "$qy" \
    | xxd -r -p > "$tmp/our.pub.der"
  printf '%s' "$eh" | xxd -r -p > "$tmp/our.hash"
  openssl pkey -pubin -inform DER -in "$tmp/our.pub.der" -out "$tmp/our.pub.pem" 2>/dev/null
  if openssl pkeyutl -verify -pubin -inkey "$tmp/our.pub.pem" \
       -sigfile "$tmp/our.sig" -in "$tmp/our.hash" 2>/dev/null | grep -q "Verified Successfully"; then
    ok "openssl verifies a signature WE made, with a key we generated"
  else
    bad "openssl rejects our signature" \
        "the signer and our own verifier can agree and both still be wrong"
  fi
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
