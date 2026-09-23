# lib/p256.wz: the modular inverse, and that it stays fast.
#
# TOETSGROEP: lib
# DEKT: lib/p256.wz
#
# WHY A SPEED TEST AT ALL, when nothing else here measures time. Because this one routine was
# 81% of a TLS handshake and the cause was invisible: p256.invm used Fermat's inverse,
# a^(m-2), which is ~256 modular multiplications -- and modulo n there is no Solinas shortcut,
# so every one took the slow bit-by-bit reduction. Measured 22-09-2026: p256.sign 9.2 ms,
# handshake 12.2 ms against nginx's 2.1 ms.
#
# Binary extended GCD does no modular multiplication at all, and brought sign to 4.0 ms.
# A future change that reintroduces Fermat, or that makes redc the default path again, would
# be invisible in every other test in this suite -- they all still pass, just slowly.
#
# THE THRESHOLD IS DELIBERATELY LOOSE. This is a regression guard, not a benchmark: it fires
# on a return to the old algorithm (more than twice as slow) and not on a busy machine.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

cat > "$tmp/t.wz" <<'WZ'
include "io.wz";
include "p256.wz";
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

  // ONE IS ITS OWN INVERSE, and the loop must notice before doing any work.
  p256.zero(a); a[0] := 1;
  p256.invm(r, a, p256.n);
  expect(p256.isone(r), "1 inverts to 1");

  // ZERO HAS NO INVERSE, and the honest answer is zero rather than a hang.
  p256.zero(a);
  p256.invm(r, a, p256.n);
  expect(p256.iszero(r), "0 has no inverse and does not loop");

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
# FERMAT WAS ~2500 us HERE; the binary algorithm is a few hundred. 1500 sits between them
# with room for a loaded machine on either side.
if [ -n "$us" ] && [ "$us" -lt 1500 ]; then
  ok "an inverse mod n takes ${us} us, well under the Fermat cost"
else
  bad "an inverse mod n takes ${us:-?} us -- Fermat's inverse may be back"
fi

grep -q ALLGOOD "$tmp/out.txt" || { echo "  FAIL  the test program did not run to the end"; fail=$((fail+1)); }

echo "invm: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
