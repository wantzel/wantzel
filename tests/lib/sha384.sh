# lib/sha384.wz: SHA-384, against the digests openssl produces.
#
# TOETSGROEP: lib
# DEKT: lib/sha384.wz
#
# WHY SHA-384 IS HERE AT ALL: public certificate chains sign with ecdsa-with-SHA384.
# Measured 22-09-2026, the intermediates and roots of github.com, cloudflare.com and
# letsencrypt.org all use it.
#
# THE ARBITER IS OPENSSL, not a stored vector. A vector proves the implementation agrees
# with one transcription; twice now a published vector has been typed wrongly here while the
# code was right, which costs a round of chasing a bug that is not there.
#
# THE CASES ARE CHOSEN FOR THE PADDING, which is where this family goes wrong:
#   - the empty message: one padding block and nothing else
#   - "abc": the FIPS example, comfortably inside one block
#   - 111 bytes: the length field still fits after the 0x80
#   - 112 bytes: it does NOT, so a second block is forced -- the boundary
#   - 128 bytes: exactly one full block, then a whole block of padding
#   - 1000 bytes: several blocks, so the streaming path runs
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so there is nothing to check against"
  exit 0
fi

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

# THE LENGTHS THAT MATTER, and each is a line in the generated program.
cases="0 3 111 112 113 127 128 129 1000"

{
echo 'import io;'
echo 'import sha384;'
echo 'var b: array[0..2047] of char; d: array[0..47] of char; i, j, n: int;'
echo 'begin'
for n in $cases; do
  # a deterministic filler: byte i is (i * 7 + 13) mod 256, which openssl can reproduce
  echo "  n := $n;"
  echo '  i := 0; while i < n do begin b[i] := chr(band(i * 7 + 13, 255)); i := i + 1; end;'
  echo '  sha384.init; sha384.updateat(b, 0, n); sha384.final(d);'
  echo '  j := 0; while j < 48 do begin'
  echo '    io.putn(STDOUT, band(ord(d[j]) shr 4, 15)); io.puts(STDOUT, ",");'
  echo '    io.putn(STDOUT, band(ord(d[j]), 15)); io.puts(STDOUT, ",");'
  echo '    j := j + 1; end;'
  echo '  io.puts(STDOUT, "\\n");'
done
echo 'end.'
} > "$tmp/t.wz"

"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  the test program does not compile"; cat "$tmp/build.log"; exit 1; }
"$tmp/t" > "$tmp/out.txt" 2>&1 || true

i=0
for n in $cases; do
  i=$((i+1))
  # the same filler, byte for byte, made outside the program being tested
  awk -v n="$n" 'BEGIN{for(k=0;k<n;k++) printf "%02x", (k*7+13)%256}' | xxd -r -p > "$tmp/in.bin"
  want=$(openssl dgst -sha384 -binary "$tmp/in.bin" | xxd -p -c48)
  # ours comes out as decimal nibbles; fold them back to hex
  line=$(sed -n "${i}p" "$tmp/out.txt")
  got=$(echo "$line" | tr ',' '\n' | grep -v '^$' | while read -r v; do printf '%x' "$v"; done)
  if [ "$got" = "$want" ]; then
    ok "SHA-384 of $n bytes matches openssl"
  else
    bad "SHA-384 of $n bytes differs from openssl"
    echo "        want $want" >&2
    echo "        got  $got" >&2
  fi
done

echo "sha384: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
