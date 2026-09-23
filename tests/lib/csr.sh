# lib/csr.wz: a certificate signing request that openssl accepts.
#
# WHY THIS IS THE HARD PART OF ACME. The protocol itself is JSON over HTTPS, which is
# ordinary work. What it demands is a CSR -- a DER structure, with the requested names in an
# attribute rather than a field, signed over its own encoded bytes. Every one of those has a
# way to be subtly wrong that produces something a lenient parser accepts and a certificate
# authority rejects.
#
# SO OPENSSL IS THE JUDGE, and specifically `-verify`, which checks the signature rather than
# just parsing the structure. A CSR that parses but whose signature does not verify is worse
# than one that fails to parse: it looks finished.
#
# WHAT IS ESTABLISHED:
#   1. openssl parses it and reports the subject, the P-256 key and the SAN
#   2. openssl VERIFIES the self-signature
#   3. the requested hostname really arrives in the subjectAltName -- not only the CN, which
#      no certificate authority looks at any more
#   4. a second CSR with a different name differs, so nothing is hard-coded
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so nothing can judge the request"
  exit 0
fi

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

# The hostname is an argument, so one binary makes several different requests and nothing can
# be accidentally constant.
cat > "$tmp/m.wz" <<'WZ'
include "io.wz";
include "csr.wz";
var d, qx, qy: array[0..P.N-1] of int;
    host: array[0..63] of char;
    hn: int;
begin
  p256.setup;
  if not p256.genkey(d, qx, qy) then halt(1);
  hn := 0;
  while (argch(1, hn) <> chr(0)) and (hn < 63) do
  begin
    host[hn] := argch(1, hn);
    hn := hn + 1;
  end;
  if hn = 0 then halt(1);
  if not csr.make(host, hn, d, qx, qy) then
  begin
    io.puts(STDERR, csr.err);
    io.puts(STDERR, "\n");
    halt(1);
  end;
  io.out(STDOUT, addr(csr.buf[0]), csr.n);
end.
WZ
"$here/bin/wantzel" "$tmp/m.wz" "$tmp/m" >/dev/null 2>&1 \
  || { echo "  FAIL  the request builder does not compile"; exit 1; }

"$tmp/m" test.example.com > "$tmp/a.csr" 2>"$tmp/err" || true
if [ -s "$tmp/a.csr" ]; then
  ok "a certificate request is produced, $(stat -c %s "$tmp/a.csr") bytes"
else
  bad "no request was produced" "$(cat "$tmp/err" | head -2)"
  echo "$pass ok, $fail fail"; exit 1
fi

# ---- 1. IT PARSES, AND SAYS WHAT IT SHOULD ----------------------------------------------------
txt=$(openssl req -inform DER -in "$tmp/a.csr" -noout -text 2>&1 || true)
case "$txt" in
  *"CN = test.example.com"*) ok "openssl reads the subject back" ;;
  *) bad "openssl cannot read the subject" "$(echo "$txt" | head -3)" ;;
esac
case "$txt" in
  *"NIST CURVE: P-256"*) ok "and recognises the P-256 public key" ;;
  *) bad "the public key is not recognised as P-256" "$(echo "$txt" | grep -i curve)" ;;
esac

# ---- 3. THE NAME MUST BE IN THE subjectAltName -------------------------------------------------
#
# NOT ONLY IN THE CN. Certificate authorities stopped looking at commonName years ago, so a
# request carrying the name only there is accepted by openssl's parser and refused by
# Let's Encrypt. Checking the SAN specifically is what separates the two.
case "$txt" in
  *"DNS:test.example.com"*) ok "and the requested name is in the subjectAltName" ;;
  *) bad "the name is not in the subjectAltName" \
         "a certificate authority reads the SAN, not the CN" "$(echo "$txt" | grep -A2 Alternative)" ;;
esac

# ---- 2. THE SIGNATURE, which is the whole point -------------------------------------------------
v=$(openssl req -inform DER -in "$tmp/a.csr" -noout -verify 2>&1 || true)
case "$v" in
  *"verify OK"*) ok "and openssl VERIFIES the signature we made over it" ;;
  *) bad "openssl rejects the signature" \
         "a request that parses but does not verify looks finished and is not" \
         "$(echo "$v" | head -2)" ;;
esac
case "$txt" in
  *"ecdsa-with-SHA256"*) ok "signed with ecdsa-with-SHA256, as declared" ;;
  *) bad "an unexpected signature algorithm" "$(echo "$txt" | grep -i 'Signature Algorithm')" ;;
esac

# ---- 4. A DIFFERENT NAME GIVES A DIFFERENT REQUEST ----------------------------------------------
#
# Without this, a builder that ignored its argument and emitted a fixed request would satisfy
# everything above.
"$tmp/m" other.example.org > "$tmp/b.csr" 2>/dev/null || true
txt2=$(openssl req -inform DER -in "$tmp/b.csr" -noout -text 2>&1 || true)
case "$txt2" in
  *"DNS:other.example.org"*) ok "a different hostname produces a different request" ;;
  *) bad "the hostname argument is ignored" "$(echo "$txt2" | grep -A2 Alternative)" ;;
esac
if cmp -s "$tmp/a.csr" "$tmp/b.csr"; then
  bad "two requests with different names are byte-identical"
else
  ok "and the two requests differ"
fi

# AND THE SECOND ONE MUST VERIFY TOO. A fresh key each time means the signature path runs
# again; one that only works for a particular key would show up here.
v2=$(openssl req -inform DER -in "$tmp/b.csr" -noout -verify 2>&1 || true)
case "$v2" in
  *"verify OK"*) ok "and it verifies as well, with its own fresh key" ;;
  *) bad "the second request does not verify" "$(echo "$v2" | head -2)" ;;
esac

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
