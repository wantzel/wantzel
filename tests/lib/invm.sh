# lib/p256.wz: the modular inverse -- correct, and not absurdly slow.
#
# TOETSGROEP: lib
# DEKT: lib/p256.wz
#
# THIS USED TO BE A SPEED REGRESSION GUARD AGAINST FERMAT'S INVERSE, and it said so here in
# some detail: p256.invm was Fermat's a^(m-2) until 22-09-2026 (~256 modular multiplications,
# 81% of a TLS handshake), was replaced with a binary extended GCD for speed (4.0 ms per
# sign), and this test asserted an inverse stayed well under Fermat's cost as the guard
# against that regression.
#
# THAT GUARD WAS BACKWARDS, and constant-time signing is why: the binary extended GCD branches on the
# parity and relative size of values derived from its input, and that input is the ECDSA
# nonce k in p256.sign -- exactly the secret-dependent timing that let Minerva and TPM-Fail
# recover ECDSA keys, and now exposed to the network on every TLS handshake rather than only
# to a local ACME operator. So p256.invm is Fermat exponentiation again, deliberately,
# with a constant-time select in place of the branch p256.powm used to have -- see
# lib/p256.wz's own notes at p256.powm and p256.invm. Slower (an inverse mod n now costs on
# the order of 6 ms, not the ~2.5 ms Fermat cost this test once compared against, because a
# constant-time square-and-always-multiply does roughly twice the multiplies of a plain
# square-and-multiply) is the accepted cost of not leaking k's bits through timing.
#
# So this file keeps only what still needs checking: that an inverse is still correct, and
# that it still finishes in bounded time (a hang, or an accidental return to something far
# slower than either algorithm, would otherwise pass silently -- every OTHER test in this
# suite still passes even if signing is minutes slow). The constant-time PROPERTY itself is
# tests/lib/p256_ct.sh's job, not this file's.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

cat > "$tmp/t.wz" <<'WZ'
import io;
import p256;
var a, r, chk: array[0..P.N-1] of int;
    i, t0, t1, failures: int;
    rb: array[0..31] of char;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what); io.puts(STDOUT, "\n");
end;
begin
  failures := 0;
  p256.setup;

  // CORRECTNESS FIRST, and against the definition rather than against another
  // implementation: a * (1/a) must be 1, modulo both p and n. Twenty random values, because
  // the binary algorithm has branches a single input will not reach.
  i := 0;
  while i < 20 do
  begin
    rand.bytes(rb);
    p256.frombytes(a, rb, 0);
    if not p256.iszero(a) then
    begin
      p256.invm(r, a, p256.p);
      p256.mulm(chk, a, r, p256.p);
      if not p256.isone(chk) then failures := failures + 1;
      p256.invm(r, a, p256.n);
      p256.mulm(chk, a, r, p256.n);
      if not p256.isone(chk) then failures := failures + 1;
    end;
    i := i + 1;
  end;
  expect(failures = 0, "a * (1/a) = 1 for twenty random values, mod p and mod n");

  // ONE IS ITS OWN INVERSE: 1^(m-2) mod m = 1.
  p256.zero(a); a[0] := 1;
  p256.invm(r, a, p256.n);
  expect(p256.isone(r), "1 inverts to 1");

  // ZERO HAS NO INVERSE, and the honest answer is zero: 0^(m-2) mod m = 0, no special case
  // needed (unlike the old binary GCD, which had to refuse zero explicitly before its loop
  // or spin forever -- zero is even forever, so it never left the "make it odd" step).
  p256.zero(a);
  p256.invm(r, a, p256.n);
  expect(p256.iszero(r), "0 has no inverse, and 0 is the honest answer");

  // AND THE SPEED. Twenty inverses modulo n, which is the expensive modulus.
  rand.bytes(rb);
  p256.frombytes(a, rb, 0);
  t0 := io.now;
  i := 0;
  while i < 20 do begin p256.invm(r, a, p256.n); i := i + 1; end;
  t1 := io.now;
  io.puts(STDOUT, "USEC ");
  io.putn(STDOUT, (t1 - t0) div 20000);
  io.puts(STDOUT, "\n");

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

us=$(grep '^USEC ' "$tmp/out.txt" | awk '{print $2}')
# MEASURED 25-09-2026, the constant-time Fermat inverse: ~6 ms on a quiet machine. 50000 (50
# ms) is not a tight regression bound -- it is a hang/sanity bound, generous enough for a
# busy machine, that would still catch an inverse that stopped terminating or that regressed
# to something far slower than either algorithm this file has used.
if [ -n "$us" ] && [ "$us" -lt 50000 ]; then
  ok "an inverse mod n takes ${us} us"
else
  bad "an inverse mod n takes ${us:-?} us -- unexpectedly slow, or it did not finish"
fi

grep -q ALLGOOD "$tmp/out.txt" || { echo "  FAIL  the test program did not run to the end"; fail=$((fail+1)); }

echo "invm: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
