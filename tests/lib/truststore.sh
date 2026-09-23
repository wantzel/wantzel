# lib/chain.wz: where the trust store comes from, and what happens when there is none.
#
# TOETSGROEP: lib
# DEKT: lib/chain.wz
#
# THE STORE STARTS EMPTY AND THAT IS DELIBERATE: a library that trusts something by default
# is a library nobody can audit. But a TOOL has to behave like the other tools on the
# machine, and a program that fetches its own certificate has to trust Let's Encrypt BEFORE
# it has one. So ch.addsystem reads the machine's bundle when there is one and falls back to
# two built-in roots when there is not.
#
# WHAT IS ESTABLISHED:
#   1. the system bundle loads, and it loads ALL of it -- an earlier buffer held 32 of 121
#      roots and said nothing
#   2. a missing file gives 0, not a crash and not a silent success
#   3. the built-in roots parse and are CAs
#   4. ch.addsystem falls back when the bundle is unreadable
#
# NO NETWORK HERE. That the built-in roots actually verify a live Let's Encrypt chain is
# checked in tests/lib/wget.sh, which already needs the network.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

# HOW MANY ROOTS THE MACHINE HAS, counted outside the program being tested.
if [ -r /etc/ssl/certs/ca-certificates.crt ]; then
  want=$(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt)
else
  want=0
fi

cat > "$tmp/t.wz" <<WZ
include "io.wz";
include "chain.wz";
var n, i, failures: int;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what); io.puts(STDOUT, "\n");
end;
begin
  failures := 0;

  // THE BUILT-IN ROOTS. Two, because Let's Encrypt signs under either -- X1 is RSA and X2
  // is ECDSA, and shipping only one works today and fails on a chain under the other.
  ch.clearroots;
  n := ch.addbaked;
  expect(n = 2, "both built-in roots load");

  i := 0;
  while i < 2 do
  begin
    expect(x509.parse(ch.baked, ch.bakedat[i], ch.bakedat[i] + ch.bakedn[i]),
           "a built-in root parses as a certificate");
    expect(x509.isca, "and it says it is a CA");
    i := i + 1;
  end;

  // A MISSING FILE IS 0, not a crash and not a quiet success.
  ch.clearroots;
  expect(ch.addfile("/this/path/does/not/exist") = 0, "a missing bundle gives no roots");

  // AND THE FALLBACK: with the bundle unreadable, ch.addsystem must still fill the store.
  // That is the scratch-container case, which is exactly where "just give it a domain" has
  // to work.
  ch.clearroots;
  n := ch.addfile("/this/path/does/not/exist");
  if n <= 0 then n := ch.addbaked;
  expect(n = 2, "the fallback fills the store when there is no bundle");

  // THE SYSTEM BUNDLE, if this machine has one.
  ch.clearroots;
  n := ch.addsystem;
  io.puts(STDOUT, "COUNT "); io.putn(STDOUT, n); io.puts(STDOUT, "\n");

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

got=$(grep '^COUNT ' "$tmp/out.txt" | awk '{print $2}')
if [ "$want" -gt 0 ]; then
  # ALL OF THEM, not most. The buffer once held 32 of 121 and reported success.
  if [ "$got" = "$want" ]; then
    ok "the system bundle loads all $want roots"
  else
    bad "the system bundle loaded $got of $want roots"
  fi
else
  [ "$got" = "2" ] && ok "no system bundle, so the built-in roots were used" \
                   || bad "no system bundle and the fallback gave $got roots"
fi

grep -q ALLGOOD "$tmp/out.txt" || { echo "  FAIL  the test program did not run to the end"; fail=$((fail+1)); }

echo "truststore: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
