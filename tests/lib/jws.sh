# lib/jws.wz: JWS with ES256, and the JWK thumbprint -- the parts ACME is built from.
#
# WHY THIS CAN BE TESTED WITHOUT A CERTIFICATE AUTHORITY. Most of ACME is arithmetic and
# text, not traffic: the signature, the thumbprint, the key authorization. All of it is
# checkable on a machine with no public domain and no network, which matters because
# Let's Encrypt cannot validate `localhost` at all -- there is nothing to prove ownership of.
#
# WHAT IS ESTABLISHED:
#   1. the thumbprint matches one computed independently (openssl, from the RFC's own rules)
#   2. the JWK has its members in LEXICOGRAPHIC order, which RFC 7638 requires and which no
#      other check would notice
#   3. a JWS we produce is accepted by an independent verifier -- the signature is over the
#      ENCODED header and payload joined by a dot, and is R||S rather than DER
#   4. the two header shapes ACME needs (jwk for the first request, kid for the rest)
#
# THE INDEPENDENT VERIFIER IS OPENSSL, fed the pieces the RFC names -- the signing input and
# the key from the header -- by a few lines of shell. Our own verifier agreeing with our own
# signer proves nothing.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is needed as the independent side"
  exit 0
fi

# base64url, both ways, by the RFC 4648 rule: the standard alphabet with + and / swapped for
# - and _, and no padding. Decoding puts the padding back first.
b64u()  { base64 -w0 | tr '+/' '-_' | tr -d '='; }
b64ud() {
  v=$1
  case $(( ${#v} % 4 )) in 2) v="$v==" ;; 3) v="$v=" ;; esac
  printf '%s' "$v" | tr -- '-_' '+/' | base64 -d
}

# ---- 1 and 2: the thumbprint, against a known key --------------------------------------------
#
# The key is the P-256 one from RFC 7515 appendix A.3, a long-standing published example. The
# expected thumbprint is computed here following RFC 7638 by hand -- the members written out in
# sorted order with no whitespace, then sha256 by openssl, then base64url without padding -- so
# the expectation does not come from our own implementation.
JX=f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU
JY=x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0
want=$(printf '{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}' "$JX" "$JY" \
       | openssl dgst -sha256 -binary | b64u)

# The same key as raw coordinates, for our side.
qxhex=$(b64ud "$JX" | xxd -p -c64)
qyhex=$(b64ud "$JY" | xxd -p -c64)

cat > "$tmp/tp.wz" <<WZ
include "io.wz";
include "jws.wz";
var qx, qy: array[0..P.N-1] of int;
    n: int;
begin
  p256.setup;
  p256.hexto(qx, "$qxhex");
  p256.hexto(qy, "$qyhex");
  // The JWK itself, so the member ORDER can be inspected -- RFC 7638 requires crv, kty, x, y
  // and any other order hashes to something else while still being valid JSON.
  n := jws.jwk(jws.tmp, 0, qx, qy);
  io.puts(STDOUT, "JWK ");
  io.out(STDOUT, addr(jws.tmp[0]), n);
  io.puts(STDOUT, "\n");
  jws.thumbprint(qx, qy);
  io.puts(STDOUT, "TP ");
  io.out(STDOUT, addr(jws.thumb[0]), jws.thumbn);
  io.puts(STDOUT, "\n");
end.
WZ
"$here/bin/wantzel" "$tmp/tp.wz" "$tmp/tp" >/dev/null 2>&1 \
  || { echo "  FAIL  the thumbprint program does not compile"; exit 1; }
out=$("$tmp/tp" 2>&1) || true
got=$(echo "$out" | awk '$1=="TP"{print $2}')
jwk=$(echo "$out" | sed -n 's/^JWK //p')

if [ "$got" = "$want" ]; then ok "the JWK thumbprint matches an independent computation"
else bad "the thumbprint differs" "ours: $got" "independent: $want"; fi

# THE MEMBER ORDER, checked as text. Nothing else would catch this: a JWK with the members in
# another order is valid JSON, produces a different thumbprint, and makes every ACME challenge
# fail with no error that points at the cause.
case "$jwk" in
  '{"crv":"P-256","kty":"EC","x":'*',"y":'*'}')
     ok "and its members are in the lexicographic order RFC 7638 requires" ;;
  *) bad "the JWK members are not in lexicographic order" "got: $jwk" ;;
esac

# ---- 3 and 4: a JWS an independent verifier accepts -------------------------------------------
cat > "$tmp/s.wz" <<'WZ'
include "io.wz";
include "jws.wz";
var d, qx, qy: array[0..P.N-1] of int;
    payload: array[0..255] of char;
    n: int;
begin
  p256.setup;
  if not p256.genkey(d, qx, qy) then halt(1);
  jws.setkey(d, qx, qy);
  n := io.push(payload, 0, "{\"termsOfServiceAgreed\":true}");
  // No kid: the "jwk" form, which is what an ACME account creation uses.
  if not jws.sign("nonce-abc", "https://example.com/acme/new-acct", payload, n, "") then halt(1);
  io.puts(STDOUT, "JWS ");
  io.out(STDOUT, addr(jws.buf[0]), jws.n);
  io.puts(STDOUT, "\n");
  // And the kid form, for every request after the account exists.
  if not jws.sign("nonce-def", "https://example.com/acme/order", payload, n, "https://example.com/acme/acct/1") then halt(1);
  io.puts(STDOUT, "KID ");
  io.out(STDOUT, addr(jws.buf[0]), jws.n);
  io.puts(STDOUT, "\n");
end.
WZ
"$here/bin/wantzel" "$tmp/s.wz" "$tmp/s" >/dev/null 2>&1 \
  || { echo "  FAIL  the signing program does not compile"; exit 1; }
sout=$("$tmp/s" 2>&1) || true
echo "$sout" | sed -n 's/^JWS //p' > "$tmp/jws.json"
echo "$sout" | sed -n 's/^KID //p' > "$tmp/kid.json"

# THE VERIFIER. Written against the RFC rather than against our implementation: take the three
# members out of the flattened JSON, rebuild "<protected>.<payload>", turn the R||S signature
# into the DER form openssl reads, and check it with the key taken out of the header's own jwk.
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
derint() {
  h=$1
  while [ ${#h} -gt 2 ] && [ "${h#00}" != "$h" ]; do h=${h#00}; done
  case "$h" in [89a-f]*) h="00$h" ;; esac
  printf '02%02x%s' $(( ${#h} / 2 )) "$h"
}
verify() {   # verify <jws.json> -- prints OK, or BAD and why
  prot=$(field protected < "$1"); pay=$(field payload < "$1"); sg=$(field signature < "$1")
  printf '%s.%s' "$prot" "$pay" > "$tmp/signed.txt"
  sighex=$(b64ud "$sg" | xxd -p -c200)
  if [ ${#sighex} -ne 128 ]; then
    echo "BAD signature is $(( ${#sighex} / 2 )) bytes, ES256 needs 64 (R||S, not DER)"; return
  fi
  body="$(derint "$(echo "$sighex" | cut -c1-64)")$(derint "$(echo "$sighex" | cut -c65-128)")"
  printf '30%02x%s' $(( ${#body} / 2 )) "$body" | xxd -r -p > "$tmp/sig.der"
  hdr=$(b64ud "$prot")
  kx=$(echo "$hdr" | field x); ky=$(echo "$hdr" | field y)
  [ -n "$kx" ] && [ -n "$ky" ] || { echo "BAD the protected header carries no jwk x and y"; return; }
  # SubjectPublicKeyInfo for prime256v1, then the uncompressed point 04||x||y.
  { printf '%s' 3059301306072a8648ce3d020106082a8648ce3d03010703420004 | xxd -r -p
    b64ud "$kx"; b64ud "$ky"; } > "$tmp/pub.der"
  openssl pkey -pubin -inform DER -in "$tmp/pub.der" -out "$tmp/pub.pem" 2>/dev/null \
    || { echo "BAD the jwk is not a valid P-256 key"; return; }
  if openssl dgst -sha256 -verify "$tmp/pub.pem" -signature "$tmp/sig.der" "$tmp/signed.txt" \
       >/dev/null 2>&1; then echo OK; else echo "BAD signature does not verify"; fi
}
res=$(verify "$tmp/jws.json")
case "$res" in
  OK) ok "an independent verifier accepts a JWS we signed" ;;
  *)  bad "the JWS we produced does not verify" "$res" ;;
esac

# THE KID FORM MUST NOT CARRY A JWK. ACME rejects a request that has both, and a client that
# always sends jwk works for account creation and fails on everything after it.
#
# NO PROCESS SUBSTITUTION HERE: the suite runs these with `sh`, not bash, and `<(...)` is a
# bashism that passes when the file is run alone and dies with "Syntax error" in the suite.
hdr=$(b64ud "$(field protected < "$tmp/kid.json")")
case "$hdr" in
  *'"jwk"'*) bad "the kid form still carries a jwk" "ACME rejects a header with both" ;;
  *'"kid"'*) ok "the kid form carries kid and not jwk" ;;
  *) bad "the kid form has no kid in its protected header" "got: $hdr" ;;
esac

# ---- the key authorization, which is what gets served at the challenge URL --------------------
cat > "$tmp/ka.wz" <<WZ
include "io.wz";
include "jws.wz";
var qx, qy: array[0..P.N-1] of int;
    buf: array[0..255] of char;
    n: int;
begin
  p256.setup;
  p256.hexto(qx, "$qxhex");
  p256.hexto(qy, "$qyhex");
  n := jws.keyauth(buf, 0, "sometoken123", qx, qy);
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
WZ
"$here/bin/wantzel" "$tmp/ka.wz" "$tmp/ka" >/dev/null 2>&1 \
  || { echo "  FAIL  the keyauth program does not compile"; exit 1; }
ka=$("$tmp/ka" 2>&1)
if [ "$ka" = "sometoken123.$want" ]; then
  ok "the HTTP-01 key authorization is token.thumbprint"
else
  bad "the key authorization is wrong" "ours:   $ka" "wanted: sometoken123.$want"
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
