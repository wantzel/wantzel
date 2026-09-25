# lib/csr.wz: a self-signed certificate, written by us and read by openssl.
#
# TOETSGROEP: lib
# DEKT: lib/csr.wz
#
# WHY SELF-SIGNED EXISTS AT ALL. Let's Encrypt cannot issue for `localhost` or `127.0.0.1` --
# not out of strictness, but because ACME proves control of a PUBLIC name and localhost
# belongs to everyone. There is no DNS record and no reachable address to validate. A machine
# that wants TLS on loopback has to make its own.
#
# OPENSSL IS THE ARBITER, and that is the whole value: writing DER that WE can read proves
# nothing, because the same misunderstanding sits on both sides. A certificate openssl parses,
# prints correctly and verifies is one that other software will accept too.
#
# WHAT IS ESTABLISHED:
#   1. openssl parses it, and the subject, issuer and SAN are what we put in
#   2. the DATES are right -- this caught a real bug, see below
#   3. basicConstraints says CA:FALSE, which lib/chain.wz and every other verifier require
#   4. openssl VERIFIES the signature against the certificate's own key
#   5. and it works in a real TLS 1.3 handshake, with openssl as the client
#
# THE DATE CHECK EARNS ITS PLACE. The first version encoded the two-digit year with
# band(y, 100) -- bitwise AND, not modulo -- so 2026 became 96 and the certificate claimed
# 1996 to 2000. It parsed, it printed, and every field looked plausible.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is needed as the arbiter"
  exit 0
fi

tmp=$(mktemp -d)
started=""
cleanup() {
  rc=$?
  for p in $started; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT
cd "$tmp"

. "$here/tests/lib/portlib.sh"
port=$(free_port)

cat > "$tmp/t.wz" <<WZ
include "io.wz";
include "net.wz";
include "csr.wz";
include "tls.wz";
var ts: array[0..15] of char;
    host: array[0..63] of char;
    d, qx, qy: array[0..P.N-1] of int;
    hn, lfd, fd, i, n: int;
    b: array[0..4095] of char;
procedure nap(ns: int);
var k: int;
begin
  k := 0;
  while k < 16 do begin ts[k] := chr(0); k := k + 1; end;
  k := 8;
  while k < 16 do begin ts[k] := chr(band(ns, 255)); ns := ns shr 8; k := k + 1; end;
  sys2(SYS.nanosleep, addr(ts[0]), 0);
end;
begin
  p256.setup;
  hn := io.push(host, 0, "localhost");
  if not p256.genkey(d, qx, qy) then begin io.puts(STDERR, "genkey\n"); halt(1); end;
  csr.setvalidity(io.realtime div 1000000000, 10);
  if not csr.selfsign(host, hn, d, qx, qy) then
  begin io.puts(STDERR, csr.err); halt(1); end;

  // THE CERTIFICATE GOES TO stdout AS BYTES so the shell can hand it to openssl. Writing a
  // file would need fs write support; this needs nothing.
  i := 0;
  while i < csr.n do begin io.putn(STDOUT, ord(csr.buf[i])); io.puts(STDOUT, ","); i := i + 1; end;
  io.puts(STDOUT, "\n");

  if not tls.setcert(csr.buf, csr.n, d) then begin io.puts(STDERR, tls.errmsg); halt(1); end;
  lfd := net.listen($port, 8, false);
  if lfd < 0 then begin io.puts(STDERR, "listen\n"); halt(1); end;
  io.puts(STDERR, "READY\n");
  i := 0;
  while i < 500 do
  begin
    fd := net.accept(lfd);
    if fd >= 0 then
    begin
      if tls.accept(fd) then
      begin
        n := io.push(b, 0, "self-signed and it works\n");
        if tls.write(b, n) then io.puts(STDERR, "SERVED\n");
        tls.close;
      end;
      net.close(fd);
      return;
    end;
    nap(10000000);
    i := i + 1;
  end;
end.
WZ

"$here/bin/wantzel" "$tmp/t.wz" t >build.log 2>&1 \
  || { echo "  FAIL  the test program does not compile"; cat build.log; exit 1; }

./t >cert.txt 2>srv.log &
started="$started $!"
i=0; while [ $i -lt 60 ] && ! grep -q READY srv.log 2>/dev/null; do sleep 0.1; i=$((i+1)); done
grep -q READY srv.log || { echo "  FAIL  the server did not start"; cat srv.log; exit 1; }

# cert.txt is the DER as comma-separated decimal bytes; turn it back into the bytes themselves
awk -v RS=',' 'NF{printf "%02x", $1}' cert.txt | xxd -r -p > self.der
ok "a self-signed certificate was generated, $(stat -c%s self.der) bytes"

# 1. OPENSSL PARSES IT
openssl x509 -inform DER -in self.der -noout -subject >subj.txt 2>&1 \
  && ok "openssl parses it as a certificate" || bad "openssl cannot parse it"
grep -q "CN *= *localhost" subj.txt && ok "the subject is the name we asked for" \
                                    || bad "the subject is wrong: $(cat subj.txt)"

openssl x509 -inform DER -in self.der -noout -issuer 2>/dev/null | grep -q "CN *= *localhost" \
  && ok "the issuer is the same, which is what self-signed means" \
  || bad "the issuer is not the subject"

# 2. THE DATES. band(y,100) instead of y mod 100 gave 1996; this is that guard.
thisyear=$(date -u +%Y)
nb=$(openssl x509 -inform DER -in self.der -noout -startdate 2>/dev/null | sed 's/notBefore=//')
nbyear=$(date -u -d "$nb" +%Y 2>/dev/null || echo 0)
[ "$nbyear" = "$thisyear" ] && ok "notBefore is this year ($thisyear), not a wrapped one" \
                            || bad "notBefore says $nbyear, expected $thisyear"

na=$(openssl x509 -inform DER -in self.der -noout -enddate 2>/dev/null | sed 's/notAfter=//')
nayear=$(date -u -d "$na" +%Y 2>/dev/null || echo 0)
[ "$nayear" -gt "$thisyear" ] && ok "notAfter is in the future ($nayear)" \
                              || bad "notAfter says $nayear, which is not later than $thisyear"

# 3. THE EXTENSIONS
openssl x509 -inform DER -in self.der -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:localhost" \
  && ok "the subjectAltName carries the hostname" || bad "no usable subjectAltName"
openssl x509 -inform DER -in self.der -noout -ext basicConstraints 2>/dev/null | grep -q "CA:FALSE" \
  && ok "basicConstraints says CA:FALSE, as a server certificate must" \
  || bad "basicConstraints is missing or wrong"

# 4. THE SIGNATURE, checked by openssl against the certificate's own key.
openssl x509 -inform DER -in self.der -out self.pem 2>/dev/null
openssl verify -CAfile self.pem self.pem >ver.txt 2>&1 \
  && ok "openssl verifies the signature against its own key" \
  || bad "openssl rejects the signature: $(tail -1 ver.txt)"

# 5. AND IN A REAL HANDSHAKE. -ign_eof, because with stdin at EOF s_client otherwise closes
# right after the handshake and races the server's reply: about half the runs lost it.
body=$(timeout 20 openssl s_client -connect "127.0.0.1:$port" -servername localhost \
       -tls1_3 -ign_eof </dev/null 2>/dev/null | grep "self-signed and it works" || true)
case "$body" in
  *"self-signed and it works"*) ok "and it serves a real TLS 1.3 connection to openssl" ;;
  *) bad "the handshake with our own certificate failed" "$(tail -2 srv.log)" ;;
esac

echo "selfsign: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
