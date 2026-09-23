# lib/rsa.wz: RSASSA-PSS verification, against signatures OpenSSL made.
#
# TOETSGROEP: lib
# DEKT: lib/rsa.wz
#
# WHY PSS MATTERS MORE THAN IT LOOKS. TLS 1.3 FORBIDS PKCS#1 v1.5 for CertificateVerify
# (RFC 8446 section 4.2.3), so every RSA server signs the handshake with PSS. It was left
# out at first on the grounds that no measured certificate chain used it -- a measurement
# that looked at certificate signatures and missed the handshake entirely. wantzel.com signs
# with PSS, so the project's own site was unreachable from its own client.
#
# BOTH HASHES, because PSS appears as rsa_pss_rsae_sha256 and rsa_pss_rsae_sha384 and the
# hash is part of the signature's meaning. Verifying one with the other gives a digest of
# the right shape and the wrong value.
#
# THE SPEC IS RFC 8017 section 9.1.2, kept verbatim in the research sources. Steps 4, 6 and
# 10 are each cheap, each easy to leave out, and each catches a forgery the rest passes --
# they are the reason this was transcribed rather than written from memory.
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

openssl genrsa -out "$tmp/k.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/k.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null
printf 'hello wantzel pss' > "$tmp/msg.txt"

# saltlen:-1 means "the same length as the hash", which is what TLS 1.3 requires and what
# certificates use in practice.
for h in sha256 sha384; do
  openssl dgst -$h -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1 \
    -sign "$tmp/k.pem" -out "$tmp/$h.sig" "$tmp/msg.txt" 2>/dev/null
  openssl dgst -$h -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1 \
    -verify "$tmp/pub.pem" -signature "$tmp/$h.sig" "$tmp/msg.txt" >/dev/null 2>&1 \
    || { echo "  FAIL  openssl cannot verify its own $h PSS signature"; exit 1; }
done
ok "openssl made PSS signatures with SHA-256 and SHA-384 and verifies them itself"

hexesc() { sed 's/\(..\)/\\x\1/g'; }
MOD=$(openssl rsa -in "$tmp/k.pem" -noout -modulus 2>/dev/null | sed 's/^Modulus=//' | tr 'A-F' 'a-f' | hexesc)
S256=$(xxd -p -c400 < "$tmp/sha256.sig" | hexesc)
S384=$(xxd -p -c400 < "$tmp/sha384.sig" | hexesc)
D256=$(openssl dgst -sha256 -binary "$tmp/msg.txt" | xxd -p -c32 | hexesc)
D384=$(openssl dgst -sha384 -binary "$tmp/msg.txt" | xxd -p -c48 | hexesc)

cat > "$tmp/t.wz" <<WZ
include "io.wz";
include "sha384.wz";
include "rsa.wz";
var nb, s2, s3: array[0..299] of char;
    d2, d3: array[0..63] of char;
    eb: array[0..7] of char;
    n, failures: int;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what); io.puts(STDOUT, "\n");
end;
begin
  failures := 0;
  n := io.push(nb, 0, "$MOD");
  n := io.push(s2, 0, "$S256");
  n := io.push(s3, 0, "$S384");
  n := io.push(d2, 0, "$D256");
  n := io.push(d3, 0, "$D384");
  n := io.push(eb, 0, "\x01\x00\x01");

  expect(rsa.setkey(nb, 0, 256, eb, 0, 3), "the public key loads");
  expect(rsa.verifypss(0, s2, 0, 256, d2), "a genuine PSS-SHA256 signature verifies");
  expect(rsa.verifypss(1, s3, 0, 256, d3), "a genuine PSS-SHA384 signature verifies");

  // ---- THE REFUSALS ----------------------------------------------------------------------
  //
  // THE HASHES CROSSED. This is the check that the hash is really part of the signature and
  // not a parameter the verifier is free to pick: each signature must fail under the other
  // hash, both directions.
  expect(not rsa.verifypss(1, s2, 0, 256, d3), "a SHA-256 signature is refused as SHA-384");
  expect(not rsa.verifypss(0, s3, 0, 256, d2), "a SHA-384 signature is refused as SHA-256");

  d2[0] := chr(bxor(ord(d2[0]), 1));
  expect(not rsa.verifypss(0, s2, 0, 256, d2), "a flipped bit in the digest is refused");
  d2[0] := chr(bxor(ord(d2[0]), 1));
  expect(rsa.verifypss(0, s2, 0, 256, d2), "and it verifies again once undone");

  // A FLIPPED BIT IN THE SIGNATURE lands in the masked DB, so it corrupts the salt and the
  // recomputed hash cannot match. Flipping late (byte 250) instead of early exercises the
  // same path from the other end.
  s2[100] := chr(bxor(ord(s2[100]), 1));
  expect(not rsa.verifypss(0, s2, 0, 256, d2), "a flipped bit early in the signature is refused");
  s2[100] := chr(bxor(ord(s2[100]), 1));
  s2[250] := chr(bxor(ord(s2[250]), 1));
  expect(not rsa.verifypss(0, s2, 0, 256, d2), "a flipped bit late in the signature is refused");
  s2[250] := chr(bxor(ord(s2[250]), 1));

  // A PKCS#1 v1.5 SIGNATURE IS NOT A PSS SIGNATURE, and vice versa. Accepting either shape
  // under either name is exactly the confusion the two schemes exist to avoid.
  expect(not rsa.verify(s2, 0, 256, d2), "a PSS signature is refused as PKCS#1 v1.5");

  // ---- THE PADDING RULES, REACHED DIRECTLY ----------------------------------------------
  //
  // THE CHECKS ABOVE DO NOT REACH THEM, and that was measured: removing step 4 (the 0xbc
  // trailer), step 6 (the top bits) or step 10 (the 0x01 separator) left this whole file
  // GREEN. Every refusal above fails at step 14 -- the recomputed hash does not match --
  // long before the cheap structural rules are consulted.
  //
  // So those rules were untested code, which is the worst kind in a verifier: they exist
  // precisely to catch a forgery that the hash comparison would otherwise pass.
  //
  // THE ONLY WAY TO REACH THEM is a block that is correct except in one place, which means
  // building the encoded message by hand. rsa.pssblock does that: it assembles a valid PSS
  // block from the digest and a salt, then breaks the one thing named by `flaw`.
  expect(rsa.pssblock(0, d2, 0), "a hand-built correct PSS block is accepted");
  expect(not rsa.pssblock(0, d2, 1), "a block whose trailer is not 0xbc is refused");
  expect(not rsa.pssblock(0, d2, 2), "a block whose top bits are not zero is refused");
  expect(not rsa.pssblock(0, d2, 3), "a block without the 0x01 separator is refused");
  expect(not rsa.pssblock(0, d2, 4), "a block whose padding is not zero is refused");

  expect(rsa.verifypss(0, s2, 0, 256, d2), "and the good one still verifies at the end");

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

echo "pss: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
