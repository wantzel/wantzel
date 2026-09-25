# A malformed input into tls.wz, x509.wz, p256.wz and p384.wz must leave a REASON behind,
# not just a bare false.
#
# WHY THIS MATTERS. A caller that gets `false` back from a parser has one question: was that
# a real attack, a corrupted download, or a local bug in the caller's own setup code? Without
# a message the three look identical and every one of them gets debugged by adding prints
# until something shows up. tls.fail/x509.fail/p256.err/p384.err exist so the answer is
# already sitting there.
#
# WHAT IS DELIBERATELY LEFT ALONE: whether a SIGNATURE verifies. tls.checkcv still returns a
# bare true/false for that, on purpose -- an attacker probing a connection must not be able
# to tell "your signature is wrong" apart from "everything else about you is wrong" by
# reading two different error strings.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

cat > "$tmp/t.wz" <<'WZ'
import io;
import rand;
import der;
import x509;
import tls;
import p256;
import p384;

var failures: int;

procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what);
  io.puts(STDOUT, "\n");
end;

procedure expectmsg(msg: str; what: str);
begin
  expect(slen(msg) > 0, what);
end;

var
  garbage:  array[0..15] of char;
  d, qx, qy, e: array[0..P.N-1] of int;
  d4, qx4, qy4, e4: array[0..Q.N-1] of int;

begin
  failures := 0;

  // ---- tls.wz: a malformed DER INTEGER inside a CertificateVerify signature -----------------
  //
  // tls.checkcv drives tls.derint on whatever bytes claim to be r and s; here they are not
  // even a valid ASN.1 SEQUENCE, so the parse fails before derint is reached, and tls.fail
  // must still have set a reason and a nonzero alert code.
  tls.err := 0; tls.errmsg := "";
  tls.cvalg := 0x0403;      // ecdsa_secp256r1_sha256
  tls.keykind := 2;         // a P-256 key was loaded
  tls.haskey := true;
  garbage[0] := chr(0x30); garbage[1] := chr(0x02); garbage[2] := chr(0xff); garbage[3] := chr(0xff);
  tls.cvsig[0] := garbage[0]; tls.cvsig[1] := garbage[1];
  tls.cvsig[2] := garbage[2]; tls.cvsig[3] := garbage[3];
  tls.cvsign := 4;
  expect(not tls.checkcv, "a CertificateVerify with an impossible DER length is refused");
  expect(tls.err <> 0, "and tls.err carries an alert code, not 0");
  expectmsg(tls.errmsg, "and tls.errmsg carries a reason");

  // ---- x509.wz: a certificate with more dNSNames than the parser kept ----------------------
  //
  // x509.matchesb already had this guard (x509.toomanynames); x509.matches lacked it. Set
  // the flag directly rather than building a certificate with 129 SANs -- the guard itself
  // does not care how toomanynames became true.
  x509.err := "";
  x509.names := 0;
  x509.toomanynames := true;
  expect(not x509.matches(garbage, "example.com"),
         "no match among the names kept, with more names dropped");
  expectmsg(x509.err, "and x509.err says the host might still be covered");

  // Sanity: WITHOUT toomanynames, x509.err stays empty on the same no-match -- the guard
  // must not fire when it has nothing to warn about.
  x509.err := "";
  x509.toomanynames := false;
  expect(not x509.matches(garbage, "example.com"), "no match, no dropped names either");
  expect(slen(x509.err) = 0, "and x509.err stays empty: there is nothing to warn about");

  // ---- p256.wz / p384.wz: a signature made with an out-of-range key ------------------------
  //
  // p256.sign/p384.sign already refused this; they did not say why. Zero is never in range
  // for either curve's scalar field.
  p256.setup;
  p256.zero(d);
  p256.zero(e);
  expect(not p256.sign(d, e), "p256.sign refuses a zero private key");
  expectmsg(p256.err, "and p256.err says the key is out of range");

  p384.setup;
  p384.zero(d4);
  p384.zero(e4);
  expect(not p384.sign(d4, e4), "p384.sign refuses a zero private key");
  expectmsg(p384.err, "and p384.err says the key is out of range");

  // And the healthy path leaves p256.err empty, so a caller can tell "it worked" from "it
  // failed silently in some new way" without re-checking the boolean twice.
  if p256.genkey(d, qx, qy) then
    expect(slen(p256.err) = 0, "p256.err is empty after a successful genkey")
  else
    expect(false, "p256.genkey works at all");
  if p384.genkey(d4, qx4, qy4) then
    expect(slen(p384.err) = 0, "p384.err is empty after a successful genkey")
  else
    expect(false, "p384.genkey works at all");

  if failures > 0 then halt(1);
end.
WZ

"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" 2>"$tmp/compile.err" \
  || { echo "  FAIL  the test program does not compile"; cat "$tmp/compile.err" | sed 's/^/        /'; exit 1; }

out=$("$tmp/t" 2>&1) || true
echo "$out" | sed 's/^/  /'
nfail=$(echo "$out" | grep -c FAIL || true)
nok=$(echo "$out" | grep -c '^ok' || true)
fail=$((fail + nfail))
pass=$((pass + nok))

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
