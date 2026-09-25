# lib/p256.wz: p256.sign is constant-time in the nonce and the private key.
#
# WHY THIS FILE EXISTS SEPARATELY FROM tests/lib/p256.sh. That file is about the VERIFIER,
# whose inputs are all public -- a signature, a public key, a message hash -- and where the
# scalar multiplications inside are allowed to branch on their input. This file is about the
# SIGNER, where the scalar (the nonce k, the private key d) is secret, lib/tls.wz now calls
# p256.sign on every TLS server handshake, and a branch whose timing depends on a secret bit
# is the whole vulnerability class Minerva and TPM-Fail used to recover ECDSA keys from
# nothing but how long signing took.
#
# WHAT IS ESTABLISHED:
#   1. p256.cswap and p256.csel, the two constant-time primitives everything else here is
#      built from, actually swap/select -- a bug here would not fail loudly, it would just
#      quietly compute wrong points and (rarely) still verify by luck
#   2. a known-answer signature (made once by OpenSSL, frozen here) still verifies -- catches
#      a transcription error in the constant-time rewrite that a fresh-signature test, which
#      compares against itself, cannot: see tests/lib/p256.sh for why a fresh signature is
#      normally preferred, and this is the deliberate exception.
#   3. many freshly generated keys sign and verify, and no two signatures share an r (a
#      repeated r means a repeated nonce -- the actual, catastrophic failure mode a timing
#      leak of k eventually enables)
#   4. THE TIMING SHAPE: p256.mulpoint (k*G, variable-base ladder), p256.mulbase (k*G,
#      fixed-base comb) and p256.invm (1/k mod n) all run in close to the same time for a
#      scalar with one bit set as for one with 255 bits set. This is a SMOKE TEST, NOT A
#      PROOF -- see the long comment before the check for exactly what it can and cannot
#      tell you.
#   5. p256.comblookup HAS NO SECRET-INDEXED READ, structurally -- a grep, not a timing
#      measurement, because timing cannot see this one: a direct `combtab_x[digit*P.N..]`
#      read on a table this small (16 entries, a few kilobytes) costs the same wall-clock
#      time as the constant-time scan, since p256.mulbase's own p256.addct already does the
#      same fixed amount of field arithmetic on every column regardless of which entry was
#      fetched -- sabotaging the lookup to read directly at `digit` (checked 25-09-2026)
#      left the timing-shape ratio at 1.16, comfortably inside the band, while silently
#      reopening exactly the cache/index-timing side channel this file exists to close.
#      So this is checked the only way that catches it: the source must show every table
#      entry being touched (p256.csel calls, one per non-zero digit) and must not show the
#      digit used directly as a slice index.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

# ---- 1. THE PRIMITIVES THEMSELVES -------------------------------------------------------------
cat > "$tmp/prim.wz" <<'WZ'
include "io.wz";
include "p256.wz";
var a, b, r, f, t: array[0..P.N-1] of int;
    i, failures: int;
begin
  failures := 0;
  a[0] := 111; a[1] := 222; b[0] := 333; b[1] := 444;
  p256.cswap(a, b, 0);                                        // bit=0: no change
  if (a[0] <> 111) or (b[0] <> 333) then failures := failures + 1;
  p256.cswap(a, b, 1);                                        // bit=1: swap
  if (a[0] <> 333) or (b[0] <> 111) then failures := failures + 1;

  i := 0; while i < P.N do begin f[i] := 10 + i; t[i] := 90 + i; i := i + 1; end;
  p256.csel(r, f, t, 0);                                      // bit=0: r := f
  i := 0; while i < P.N do begin if r[i] <> f[i] then failures := failures + 1; i := i + 1; end;
  p256.csel(r, f, t, 1);                                      // bit=1: r := t
  i := 0; while i < P.N do begin if r[i] <> t[i] then failures := failures + 1; i := i + 1; end;

  io.puts(STDOUT, "failures "); io.putn(STDOUT, failures); io.puts(STDOUT, "\n");
end.
WZ
"$WANTZEL" "$tmp/prim.wz" "$tmp/prim" 2>"$tmp/cerr" || { echo "  FAIL  the primitives program does not compile"; cat "$tmp/cerr"; exit 1; }
pfail=$("$tmp/prim" | awk '{print $2}')
if [ "$pfail" = "0" ]; then ok "p256.cswap and p256.csel swap/select correctly, both ways"
else bad "p256.cswap/p256.csel: $pfail check(s) failed"; fi

# ---- 2. KNOWN-ANSWER VECTOR ------------------------------------------------------------------
#
# Made once with OpenSSL (a fixed prime256v1 key, message "p256 known-answer vector for
# wantzel", SHA-256), then frozen here so this check needs no openssl at test time and pins
# the exact bytes the constant-time rewrite must still accept.
cat > "$tmp/kat.wz" <<'WZ'
include "io.wz";
include "p256.wz";
var e, qx, qy, r, s: array[0..P.N-1] of int;
begin
  p256.setup;
  p256.hexto(e,  "e7377ba73d78056e73818970b9d2f3c4052dc2a103d49cbad0b415d975ad1761");
  p256.hexto(qx, "6b6e3257cf89e33a1247bb6073cae4cc2d5d6427f91d9a0910806facb7f253d0");
  p256.hexto(qy, "ddb094bf057f90c9b301b3f7e028ee1da38a697a84f6ce994af4f315608ac216");
  p256.hexto(r,  "a82f937d08233d03ce3bc38760ae80260678b23e9881f0fa15f989a3c1a23437");
  p256.hexto(s,  "cf0a259df5f8f9ba7cd8b397e45bdf8937f2b1b8b0ba9ffaaad59a95105dfcc3");
  if p256.verify(qx, qy, e, r, s) then io.puts(STDOUT, "ok\n") else io.puts(STDOUT, "FAIL\n");
end.
WZ
"$WANTZEL" "$tmp/kat.wz" "$tmp/kat" 2>"$tmp/cerr" || { echo "  FAIL  the KAT program does not compile"; cat "$tmp/cerr"; exit 1; }
if [ "$("$tmp/kat")" = "ok" ]; then ok "the frozen known-answer signature verifies"
else bad "the frozen known-answer signature does not verify" "the rewrite changed the arithmetic, not just its timing"; fi

# ---- 3. MANY KEYS, SIGN AND VERIFY, NO REPEATED NONCE ----------------------------------------
#
# The Montgomery ladder and the Fermat inverse replace the old double-and-add and binary GCD;
# this is the check that they still compute the SAME answer across many different scalars,
# not just the one KAT above and the single key tests/lib/p256.sh already exercises.
cat > "$tmp/many.wz" <<'WZ'
include "io.wz";
include "rand.wz";
include "p256.wz";
const N = 30;
var d, qx, qy, e: array[0..P.N-1] of int;
    rs: array[0..N*P.N-1] of int;      // N slices of P.N limbs each; no array of array here
    hash: array[0..31] of char;
    i, j, failures, dup: int;
begin
  p256.setup;
  failures := 0;
  i := 0;
  while i < N do
  begin
    if not p256.genkey(d, qx, qy) then begin failures := failures + 1; i := i + 1; continue; end;
    rand.bytes(hash);
    p256.frombytes(e, hash, 0);
    if not p256.sign(d, e) then begin failures := failures + 1; i := i + 1; continue; end;
    if not p256.verify(qx, qy, e, p256.sigr, p256.sigs) then failures := failures + 1;
    p256.copy(rs[i*P.N..(i+1)*P.N-1], p256.sigr);
    i := i + 1;
  end;
  dup := 0;
  i := 0;
  while i < N do
  begin
    j := i + 1;
    while j < N do
    begin
      if p256.cmp(rs[i*P.N..(i+1)*P.N-1], rs[j*P.N..(j+1)*P.N-1]) = 0 then dup := dup + 1;
      j := j + 1;
    end;
    i := i + 1;
  end;
  io.puts(STDOUT, "failures "); io.putn(STDOUT, failures); io.puts(STDOUT, "\n");
  io.puts(STDOUT, "dup ");      io.putn(STDOUT, dup);      io.puts(STDOUT, "\n");
end.
WZ
"$WANTZEL" "$tmp/many.wz" "$tmp/many" 2>"$tmp/cerr" || { echo "  FAIL  the many-keys program does not compile"; cat "$tmp/cerr"; exit 1; }
out=$("$tmp/many")
failures=$(echo "$out" | awk '$1=="failures"{print $2}')
dup=$(echo "$out" | awk '$1=="dup"{print $2}')
if [ "$failures" = "0" ]; then ok "30 fresh keys all sign and self-verify"
else bad "30 fresh keys: $failures did not sign or verify"; fi
if [ "$dup" = "0" ]; then ok "no two of the 30 signatures share a nonce (r)"
else bad "$dup pair(s) of signatures share an r -- a repeated nonce"; fi

# ---- 4. THE TIMING SHAPE -----------------------------------------------------------------
#
# HONEST ABOUT WHAT THIS IS. It measures p256.mulpoint (k*G, variable-base ladder),
# p256.mulbase (k*G, fixed-base comb) and p256.invm (1/k mod n) -- what p256.sign uses on
# the secret nonce -- over a scalar with ONE bit set against one with 255 bits set, both 256
# bits wide (bit 255 forced on both, so this is not measuring the separate top-bit-position
# caveat p256.mulpoint's own comment documents; p256.mulbase has no such caveat -- it always
# runs exactly COMB.T columns and COMB.T table scans regardless of k). If any of these
# routines still branched on the scalar's bits/digits the way the pre-rewrite double-and-add
# and binary GCD did, or read the comb table at a secret INDEX instead of scanning every
# entry, 255 extra branches (or 64 secret-indexed reads) would show up as a clearly different
# run time between the two; a constant-time implementation runs the identical sequence of
# operations and touches the same memory either way, so the two times should be close.
#
# WHAT IT CANNOT TELL YOU: this is ONE machine, under ordinary load, with the usual jitter of
# a shared CPU, cache state and branch predictor -- not a controlled timing lab, and not
# proof of zero leakage (p256.mulpoint's comment already names the one gap this rewrite
# leaves: infinity's own early-return, live for the rounds above the scalar's TOP set bit,
# which both test scalars here fix at bit 255 so it cannot show up in this comparison
# either; p256.mulbase shares the same residual through p256.add's own infinity branch, once
# per column, but every column always runs so there is no top-bit-position case to leak). It
# is a SMOKE TEST: a branch big enough to matter -- one taken or skipped roughly 128 times
# out of 256 rounds on average, or a table scan collapsed to a single indexed read -- moves
# the ratio far past ordinary noise, and re-introducing exactly such a branch/index turns
# this check red. A ratio inside the band below does not prove constant time; a ratio
# outside it is real evidence something branches (or indexes) on the scalar again.
#
# TEN REPETITIONS, MEDIAN, inside the Wantzel program itself (p256_ctcheck.wz) -- the median
# of ten discards the rare scheduler hiccup without hiding a systematic difference. The band
# is deliberately wide (0.5x-2.0x): tight enough that a per-bit branch (which roughly doubles
# or halves the work depending on which scalar has more set bits) cannot hide inside it, wide
# enough that ordinary single-machine jitter does not make this test flaky.
compile() { "$WANTZEL" "$1" "$2" 2>"$tmp/cerr" || { echo "  FAIL  $1 does not compile"; cat "$tmp/cerr"; exit 1; }; }
compile "$here/tests/lib/progs/p256_ctcheck.wz" "$tmp/ctcheck"

band_ok() {
  # $1 = high, $2 = low, both positive integers (nanoseconds); ratio must be in [0.5, 2.0]
  awk -v h="$1" -v l="$2" 'BEGIN { r = h / l; if (r < 0.5 || r > 2.0) { print r; exit 1 } else { print r; exit 0 } }'
}

out=$("$tmp/ctcheck")
mlo=$(echo "$out" | awk '$1=="MULPOINT_LOW"{print $2}')
mhi=$(echo "$out" | awk '$1=="MULPOINT_HIGH"{print $2}')
ilo=$(echo "$out" | awk '$1=="INVM_LOW"{print $2}')
ihi=$(echo "$out" | awk '$1=="INVM_HIGH"{print $2}')
blo=$(echo "$out" | awk '$1=="MULBASE_LOW"{print $2}')
bhi=$(echo "$out" | awk '$1=="MULBASE_HIGH"{print $2}')

mratio=$(band_ok "$mhi" "$mlo") && ok "mulpoint: low/high-weight timing ratio $mratio is within [0.5, 2.0]" \
  || bad "mulpoint: low/high-weight timing ratio $mratio is OUTSIDE [0.5, 2.0]" \
         "low-weight median ${mlo}ns, high-weight median ${mhi}ns"
iratio=$(band_ok "$ihi" "$ilo") && ok "invm: low/high-weight timing ratio $iratio is within [0.5, 2.0]" \
  || bad "invm: low/high-weight timing ratio $iratio is OUTSIDE [0.5, 2.0]" \
         "low-weight median ${ilo}ns, high-weight median ${ihi}ns"
bratio=$(band_ok "$bhi" "$blo") && ok "mulbase: low/high-weight timing ratio $bratio is within [0.5, 2.0]" \
  || bad "mulbase: low/high-weight timing ratio $bratio is OUTSIDE [0.5, 2.0]" \
         "low-weight median ${blo}ns, high-weight median ${bhi}ns"

# ---- 5. THE COMB TABLE LOOKUP: STRUCTURAL, NOT TIMING -------------------------------------
#
# Timing cannot see a secret-indexed read on a table this small (checked 25-09-2026, see the
# header comment) -- p256.addct's own field arithmetic dominates every column regardless of
# which table entry was fetched. So this checks the SOURCE: p256.comblookup must fold in
# every one of COMB.DIGITS (16) table entries through p256.csel, and must not read the table
# at an offset built directly from `digit`.
lookup=$(awk '/^procedure p256\.comblookup/,/^end;/' "$here/lib/p256.wz")
# One p256.csel per coordinate (x, y, z), INSIDE a `while d < COMB.DIGITS` loop that runs
# over every table entry -- so this is a structural check of the SHAPE (a loop that visits
# every entry and folds each one in), not a count of how many times it runs.
nsel=$(echo "$lookup" | grep -c 'p256\.csel(p256\.b[xyz]' || true)
haswhile=$(echo "$lookup" | grep -c 'while d < COMB\.DIGITS' || true)
if [ "$nsel" -eq 3 ] && [ "$haswhile" -ge 1 ]; then
  ok "p256.comblookup folds every table entry (x,y,z) through p256.csel inside a full COMB.DIGITS scan"
else
  bad "p256.comblookup: expected 3 p256.csel folds (one per coordinate) inside a 'while d < COMB.DIGITS' scan, found $nsel csel line(s) and $haswhile scan(s)" \
      "a table entry that is never csel'd in, or a loop that does not cover every digit, is a table entry that can be skipped -- exactly what a secret-indexed read does"
fi
if echo "$lookup" | grep -Eq '\[digit(\s*\*|\s*\])'; then
  bad "p256.comblookup reads the table at an offset built directly from digit" \
      "that is a secret-indexed memory access -- the whole thing this file exists to rule out"
else ok "p256.comblookup does not index the table directly by digit"
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
