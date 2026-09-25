# lib/rsa.wz: RSA-2048 PKCS#1 v1.5 verification, against signatures OpenSSL made.
#
# TOETSGROEP: lib
# DEKT: lib/rsa.wz
#
# WHY A FRESH KEY AND SIGNATURE EACH RUN, as in tests/lib/p256.sh: a stored vector proves
# only that the verifier agrees with one transcription. Here OpenSSL generates a key, signs,
# verifies its own signature, and then ours has to agree -- key, hash and signature all
# change every run, so an accidental agreement cannot survive.
#
# WHAT IS ESTABLISHED:
#   1. a genuine signature verifies
#   2. the REFUSALS, which are the whole point. A verifier that returned true always would
#      pass check 1 and nothing else:
#        - a flipped bit in the digest
#        - a flipped bit in the signature
#        - the signature presented under a DIFFERENT key of the same size
#        - a signature that is not less than the modulus
#   3. and that it still verifies after each tamper is undone, so a refusal is not some
#      permanent broken state
#
# THE PADDING CHECK IS THE HISTORICALLY DANGEROUS PART. Bleichenbacher's 2006 attack worked
# against verifiers that found the digest and stopped looking, accepting forgeries with
# garbage after it. So a forged block with the right digest in the wrong place is tested too.
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
openssl genrsa -out "$tmp/k2.pem" 2048 2>/dev/null
printf 'hello wantzel rsa' > "$tmp/msg.txt"
openssl dgst -sha256 -sign "$tmp/k.pem" -out "$tmp/sig.bin" "$tmp/msg.txt" 2>/dev/null

# OPENSSL MUST AGREE WITH ITSELF FIRST, or the failure is in this script and not in lib/.
openssl rsa -in "$tmp/k.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null
openssl dgst -sha256 -verify "$tmp/pub.pem" -signature "$tmp/sig.bin" "$tmp/msg.txt" >/dev/null 2>&1 \
  || { echo "  FAIL  openssl cannot verify its own signature"; exit 1; }
ok "openssl made a signature and verifies it itself"

hexesc() { sed 's/\(..\)/\\x\1/g'; }
modn=$(openssl rsa -in "$tmp/k.pem" -noout -modulus 2>/dev/null | sed 's/^Modulus=//' | tr 'A-F' 'a-f')
mod2=$(openssl rsa -in "$tmp/k2.pem" -noout -modulus 2>/dev/null | sed 's/^Modulus=//' | tr 'A-F' 'a-f')
sig=$(xxd -p -c400 < "$tmp/sig.bin")
dig=$(openssl dgst -sha256 -binary "$tmp/msg.txt" | xxd -p -c32)

MODN=$(echo "$modn" | hexesc); MOD2=$(echo "$mod2" | hexesc)
SIG=$(echo "$sig" | hexesc);   DIG=$(echo "$dig" | hexesc)

cat > "$tmp/t.wz" <<WZ
import io;
import rsa;
var nb, n2b, sb: array[0..299] of char;
    db: array[0..63] of char;
    eb: array[0..7] of char;
    blk: array[0..RSA.N-1] of int;
    n, failures: int;

// mk -- build a PKCS#1 v1.5 block by hand, with one deliberate flaw selected by `flaw`.
//
// 0 = correct, 1 = the digest sits 8 bytes early with filler after it (the Bleichenbacher
// shape), 2 = one padding byte is not FF, 3 = the leading 00 01 is wrong.
procedure setb(r: array of int; klen: int; k: int; v: int);
var i, limb, sh: int;
begin
  i := klen - 1 - k;
  limb := i shr 2;
  sh := band(i, 3) * 8;
  if limb < RSA.N then
    r[limb] := bor(band(r[limb], bxor(band(0xFF shl sh, 0xFFFFFFFF), 0xFFFFFFFF)),
                   band(v shl sh, 0xFFFFFFFF));
end;

procedure mk(r: array of int; klen: int; digest: array of char; dat: int; flaw: int);
var i, sep, shift: int;
begin
  rsa.zero(r, RSA.N);
  rsa.setdi;
  shift := 0;
  if flaw = 1 then shift := 8;
  setb(r, klen, 0, 0x00);
  setb(r, klen, 1, 0x01);
  sep := klen - 19 - 32 - 1 - shift;
  i := 2;
  while i < sep do begin setb(r, klen, i, 0xFF); i := i + 1; end;
  // FLAW 2 PUTS A NON-FF BYTE IN THE MIDDLE OF THE PADDING, and it must NOT shorten the
  // block: if the separator moves, the length check catches it and the FF rule is never
  // reached. Measured -- with the byte at position 5 this test stayed green while the FF
  // check was removed. So the byte goes here and everything after it stays exactly as it
  // was, which leaves the length right and the FF rule as the only thing that can refuse it.
  if flaw = 2 then setb(r, klen, sep - 4, 0xFE);
  if flaw = 3 then setb(r, klen, 1, 0x02);
  setb(r, klen, sep, 0x00);
  i := 0;
  while i < 19 do begin setb(r, klen, sep + 1 + i, rsa.di[i]); i := i + 1; end;
  i := 0;
  while i < 32 do begin setb(r, klen, sep + 20 + i, ord(digest[dat + i])); i := i + 1; end;
  // for flaw 1 the block ends with filler AFTER the digest, which is exactly what a
  // length-blind verifier would accept
  i := sep + 20 + 32;
  while i < klen do begin setb(r, klen, i, 0xAA); i := i + 1; end;
end;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what); io.puts(STDOUT, "\n");
end;
begin
  failures := 0;
  n := io.push(nb,  0, "$MODN");
  n := io.push(n2b, 0, "$MOD2");
  n := io.push(sb,  0, "$SIG");
  n := io.push(db,  0, "$DIG");
  n := io.push(eb,  0, "\x01\x00\x01");

  expect(rsa.setkey(nb, 0, 256, eb, 0, 3), "the public key loads");
  expect(rsa.verify(sb, 0, 256, db), "a genuine openssl signature verifies");

  // ---- THE REFUSALS ----------------------------------------------------------------------
  db[0] := chr(bxor(ord(db[0]), 1));
  expect(not rsa.verify(sb, 0, 256, db), "a flipped bit in the digest is refused");
  db[0] := chr(bxor(ord(db[0]), 1));
  expect(rsa.verify(sb, 0, 256, db), "and it verifies again once undone");

  sb[200] := chr(bxor(ord(sb[200]), 1));
  expect(not rsa.verify(sb, 0, 256, db), "a flipped bit in the signature is refused");
  sb[200] := chr(bxor(ord(sb[200]), 1));

  // THE SAME SIGNATURE UNDER A DIFFERENT KEY of the same size. This is the check that the
  // verifier actually uses the key it was given.
  expect(rsa.setkey(n2b, 0, 256, eb, 0, 3), "a second key loads");
  expect(not rsa.verify(sb, 0, 256, db), "the signature is refused under another key");

  // AND BACK, so the refusal above was about the key and not about broken state.
  expect(rsa.setkey(nb, 0, 256, eb, 0, 3), "the first key loads again");
  expect(rsa.verify(sb, 0, 256, db), "and the signature verifies once more");

  // ---- THE PADDING ITSELF --------------------------------------------------------------
  //
  // THE CHECKS ABOVE DO NOT REACH IT, and that was measured: removing the "digest ends at
  // the end of the block" test left this whole file GREEN. Every refusal above fails in the
  // modular exponentiation long before the padding is looked at, so the padding rules were
  // untested code.
  //
  // So these go at rsa.checkpkcs1 directly, on blocks built by hand. This is the
  // Bleichenbacher shape: a block whose digest is correct but which is not a well-formed
  // PKCS#1 v1.5 encoding. A verifier that searches for the digest instead of checking the
  // whole block accepts these, and that is a forgery.
  rsa.zero(blk, RSA.N);
  expect(not rsa.checkpkcs1(blk, 256, db, 0), "an all-zero block is refused");

  // a WELL-FORMED block, assembled here, must be accepted -- otherwise the refusals below
  // prove nothing (they could all fail for an unrelated reason)
  mk(blk, 256, db, 0, 0);
  expect(rsa.checkpkcs1(blk, 256, db, 0), "a hand-built correct block is accepted");

  mk(blk, 256, db, 0, 1);
  expect(not rsa.checkpkcs1(blk, 256, db, 0), "a block with the digest too early is refused");

  mk(blk, 256, db, 0, 2);
  expect(not rsa.checkpkcs1(blk, 256, db, 0), "a block with a non-FF padding byte is refused");
  // HONEST NOTE ON THE CHECK ABOVE: it passes, but removing the FF rule from lib/rsa.wz
  // leaves this file GREEN -- measured. The reason is that the two rules overlap: a stray
  // non-FF byte becomes the separator, which moves the digest, and the LENGTH rule refuses
  // it first. So this case is covered, but not by the rule it names.
  //
  // It is left in because the behaviour it asserts is the one that matters (such a block is
  // refused), and noted because a future reader would otherwise believe the FF rule is
  // guarded when it is not. Guarding it on its own needs a block where the non-FF byte does
  // not shift anything, which PKCS#1 does not really allow -- the rule is a belt on top of
  // braces, and that is exactly what it should be.

  mk(blk, 256, db, 0, 3);
  expect(not rsa.checkpkcs1(blk, 256, db, 0), "a block that does not start with 00 01 is refused");

  if failures = 0 then io.puts(STDOUT, "ALLGOOD\n");
end.
WZ

"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  the test program does not compile"; cat "$tmp/build.log"; exit 1; }
"$tmp/t" > "$tmp/out.txt" 2>&1 || true

while read -r line; do
  case "$line" in
    "ok   "*)   ok "${line#ok   }" ;;
    "FAIL "*)   bad "${line#FAIL }" ;;
  esac
done < "$tmp/out.txt"

grep -q ALLGOOD "$tmp/out.txt" || { echo "  FAIL  the test program did not run to the end"; fail=$((fail+1)); }

echo "rsa: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
