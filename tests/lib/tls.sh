# lib/tls.wz: a real TLS 1.3 handshake, against an independent implementation.
#
# WHY AGAINST OPENSSL AND NOT AGAINST OURSELVES. Two copies of the same misunderstanding
# agree perfectly: a client and server that both derive the wrong key, or both order the
# transcript the same wrong way, would shake hands happily and be unable to talk to anything
# else. The whole value of this test is that the other end was written by someone else,
# reads the same RFC, and has interoperated with the internet for years.
#
# WHAT IS ESTABLISHED HERE:
#   1. the handshake completes -- ClientHello, key exchange, and Finished verified BOTH ways
#   2. application data flows, encrypted, and decrypts to what the server actually served
#   3. it works repeatedly, not once by luck
#   4. the authentication is load-bearing: a flipped bit in a record is REFUSED
#
# That fourth check is the one that matters. Encryption that cannot be verified is not
# security, and a decrypt path that ignores its tag looks identical to a working one right
# up until someone tampers with a record.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

# OPENSSL IS A TEST DEPENDENCY, NOT A BUILD ONE. Nothing in the compiler or the library
# needs it; it is here only to be the other end of a conversation. Skip rather than fail
# where it is absent, so the suite still runs on a machine without it.
if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so there is nothing to hand shake with"
  exit 0
fi

tmp=$(mktemp -d)
port=$(( 24000 + ($$ % 10000) ))
started=""
cleanup() {
  rc=$?
  # `|| true` on every kill: with `set -e` a kill of an already-dead process aborts the
  # cleanup and the script then exits non-zero with every check green.
  for p in $started; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT

# AN EC KEY, AND A subjectAltName. Both matter:
#
#   - P-256, because that is the signature this client can actually check. With an RSA
#     certificate the handshake still completes but tls.verified stays false, and the point
#     of this file is to get it TRUE.
#   - the SAN, because a certificate carrying only a CN is REFUSED. That is correct modern
#     behaviour -- browsers stopped honouring commonName years ago -- and it was measured
#     here: adding the hostname check turned this whole file red until the SAN went in.
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" 2>/dev/null \
  || { echo "  FAIL  cannot make a test key"; exit 1; }
openssl req -x509 -key "$tmp/k.pem" -out "$tmp/c.pem" \
  -days 1 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1 \
  || { echo "  FAIL  cannot make a test certificate"; exit 1; }

# -www makes it answer any request with a small HTML page and its own connection details.
# TLS 1.3 ONLY, because a client that cannot fall back should never be handed the chance.
openssl s_server -accept "$port" -cert "$tmp/c.pem" -key "$tmp/k.pem" \
  -tls1_3 -www -quiet >"$tmp/srv.log" 2>&1 &
started="$started $!"

i=0
while [ $i -lt 50 ]; do
  ss -tln 2>/dev/null | grep -q ":$port " && break
  sleep 0.1
  i=$((i+1))
done
ss -tln 2>/dev/null | grep -q ":$port " \
  || { echo "  FAIL  the test server never started listening"; exit 1; }

# ---- the client ----------------------------------------------------------------------------
cat > "$tmp/cli.wz" <<WZ
include "io.wz";
include "net.wz";
include "tls.wz";
var fd, n, i, rfd, rn: int;
    buf: array[0..8191] of char;
    req: array[0..255] of char;
    // THE ROOT IS READ FROM A FILE NAMED ON THE COMMAND LINE. The path is a fixed string
    // because Wantzel cannot build a str from characters; the harness always writes the
    // root to this name, which keeps the client simple and the test explicit.
    rootbuf: array[0..8191] of char;
    rootpath: array[0..63] of char;
// WHICH HOSTNAME TO CHECK AGAINST, chosen by a flag rather than passed as text: Wantzel has
// no way to build a str from characters, and x509.matches takes a str. Two fixed names cover
// what this test needs -- the right one and a wrong one.
function hostarg: str;
begin
  if argch(2, 0) = 'w' then return "wrong.example.com";
  return "localhost";
end;
function argnum(k: int): int;
var j, v: int;
    c: char;
begin
  v := 0; j := 0; c := argch(k, j);
  while (c >= '0') and (c <= '9') do
  begin v := v * 10 + (ord(c) - ord('0')); j := j + 1; c := argch(k, j); end;
  return v;
end;
begin
  // LOAD A ROOT IF ONE WAS GIVEN. tls.verified now means the chain reaches a trusted root,
  // so a run without this prints UNVERIFIED -- which is the honest answer and is itself
  // one of the things this file checks.
  ch.clearroots;
  // argc COUNTS THE PROGRAM NAME, so "port host root" is 4. Testing > 2 loaded the root
  // whenever a hostname was given, which made the no-root case impossible to test -- it
  // reported VERIFIED either way.
  if argc() > 3 then
  begin
    rn := io.push(rootpath, 0, "root.der");
    rootpath[rn] := chr(0);
    rfd := sys3(SYS.open, addr(rootpath[0]), O_RDONLY, 0);
    if rfd >= 0 then
    begin
      rn := sys3(SYS.read, rfd, addr(rootbuf[0]), len(rootbuf));
      rn := sys1(SYS.close, rfd) * 0 + rn;
      if rn > 0 then
        if not ch.addroot(rootbuf, 0, rn) then
          begin io.puts(STDERR, "addroot failed: "); io.puts(STDERR, ch.err); io.puts(STDERR, "\n"); halt(1); end;
    end;
  end;
  fd := net.connect(127, 0, 0, 1, argnum(1));
  if fd < 0 then begin io.puts(STDERR, "connect failed\n"); halt(1); end;
  tls.now := io.realtime div 1000000000;
  if not tls.connect(fd, hostarg) then
  begin
    io.puts(STDERR, "handshake failed: ");
    io.puts(STDERR, tls.errmsg);
    io.puts(STDERR, "\n");
    halt(1);
  end;
  io.puts(STDOUT, "HANDSHAKE-OK\n");
  if tls.verified then io.puts(STDOUT, "VERIFIED\n") else io.puts(STDOUT, "UNVERIFIED\n");
  n := io.push(req, 0, "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");
  if not tls.write(req, n) then begin io.puts(STDERR, "write failed\n"); halt(1); end;
  n := tls.read(buf, 8192);
  if n <= 0 then begin io.puts(STDERR, "read gave nothing\n"); halt(1); end;
  io.puts(STDOUT, "BYTES ");
  io.putn(STDOUT, n);
  io.puts(STDOUT, "\n");
  io.out(STDOUT, addr(buf[0]), n);
  tls.close;
end.
WZ
"$here/bin/wantzel" "$tmp/cli.wz" "$tmp/cli" >/dev/null 2>&1 \
  || { echo "  FAIL  the test client does not compile"; exit 1; }
ok "a TLS client builds, $(stat -c %s "$tmp/cli") bytes"

# ---- 1. the handshake ------------------------------------------------------------------------
# THE SELF-SIGNED CERTIFICATE IS ITS OWN ROOT, so putting it in the trust store is exactly
# what a real deployment does with a real root -- and it is what makes tls.verified mean
# something. Run from $tmp because the client opens "root.der" relative to where it stands.
openssl x509 -in "$tmp/c.pem" -outform DER -out "$tmp/root.der" 2>/dev/null
out=$(cd "$tmp" && "$tmp/cli" "$port" localhost root 2>"$tmp/err") || true
case "$out" in
  *HANDSHAKE-OK*) ok "a full TLS 1.3 handshake with OpenSSL completes" ;;
  *) bad "the handshake failed" "$(cat "$tmp/err")" ;;
esac

# ---- 2. the data is really the server's ------------------------------------------------------
#
# NOT JUST "SOME BYTES ARRIVED". A decrypt that produced garbage would still produce a
# length; what proves the keys are right is that the plaintext is the page OpenSSL serves.
case "$out" in
  *"HTTP/1.0 200 ok"*) ok "and the decrypted reply is the server's own HTTP" ;;
  *) bad "the decrypted data is not what the server served" "got: $(echo "$out" | head -3)" ;;
esac
case "$out" in
  *"Ciphers supported"*|*"</html>"*|*"New, TLSv1.3"*)
     ok "and the whole page decrypts, not only its first record" ;;
  *) bad "only part of the page came through" "$(echo "$out" | tail -3)" ;;
esac

# ---- 2b. THE SERVER PROVED IT HOLDS THE KEY ---------------------------------------------------
#
# This is the step from "encrypted" to "authenticated". tls.verified is true only when the
# certificate matched the hostname, was in date, AND the server signed the handshake
# transcript with the matching private key.
#
# WHAT IT STILL DOES NOT MEAN: that the certificate is trusted. There is no root store yet,
# so this self-signed certificate sets it true. Necessary, not yet sufficient.
# MATCHED ON A WHOLE LINE, and that is not fussiness. The first version tested for
# *VERIFIED* -- which "UNVERIFIED" also contains, so the check could not fail. Measured
# 22-09-2026: with the 64 spaces removed from the CertificateVerify digest the client
# printed UNVERIFIED and this file still said 9 ok, 0 fail.
case "
$out" in
  *"
VERIFIED"*) ok "and the server proved it holds the certificate's private key" ;;
  *) bad "the handshake completed but the signature was not verified" \
         "tls.verified stayed false against a P-256 certificate" ;;
esac

# ---- 2b-bis. AND WITHOUT A ROOT IT MUST SAY NO ------------------------------------------------
#
# THE SAME SERVER, THE SAME CERTIFICATE, ONE DIFFERENCE: nothing in the trust store. This is
# what makes the check above mean something. A verifier that reported VERIFIED here would be
# saying "the server holds this key", which is true and worthless -- anyone can hold a key
# for a certificate they made for your hostname.
#
# MEASURED WHILE WRITING THIS: the first version of the client tested argc() > 2, which is
# true whenever a hostname is given, so it loaded the root either way and this case could
# not be distinguished. It reported VERIFIED both times and the test would have passed.
out=$(cd "$tmp" && "$tmp/cli" "$port" localhost 2>"$tmp/err2") || true
case "
$out" in
  *"
UNVERIFIED"*) ok "and with an EMPTY trust store the same certificate is unverified" ;;
  *) bad "an empty trust store still reported the certificate as verified" \
         "verified must mean the chain reaches a root, not merely that the key is held" ;;
esac

# ---- 2c. THE REFUSALS, which are the whole value of the check above ----------------------------
#
# A verifier that always said yes would pass 2b and fail both of these.
wrong=$("$tmp/cli" "$port" wrong 2>&1 || true)
case "$wrong" in
  *"not valid for this hostname"*)
     ok "a certificate for another hostname is refused" ;;
  *HANDSHAKE-OK*)
     bad "a certificate for the WRONG hostname was accepted" \
         "any valid certificate for any domain would work: TLS with no security" ;;
  *) bad "the wrong-hostname case failed for another reason" "got: $(echo "$wrong" | head -2)" ;;
esac

# AN RSA CERTIFICATE MUST NOT LOOK VERIFIED. This client cannot check RSA signatures yet, and
# the honest answer is verified = false -- not a silent true, and not a refusal to connect.
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/rk.pem" -out "$tmp/rc.pem" \
  -days 1 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1
rsaport=$(( port + 1 ))
openssl s_server -accept "$rsaport" -cert "$tmp/rc.pem" -key "$tmp/rk.pem" \
  -tls1_3 -www -quiet >"$tmp/rsa.log" 2>&1 &
started="$started $!"
i=0
while [ $i -lt 50 ]; do
  ss -tln 2>/dev/null | grep -q ":$rsaport " && break
  sleep 0.1; i=$((i+1))
done
rsa=$("$tmp/cli" "$rsaport" localhost 2>&1 || true)
# UNVERIFIED is tested FIRST here, because *VERIFIED* would match it too.
case "$rsa" in
  *UNVERIFIED*) ok "an RSA certificate connects but is honestly reported as unverified" ;;
  *VERIFIED*)   bad "an RSA signature was reported as verified" \
                    "this client cannot check RSA; saying so would be a lie" ;;
  *) bad "the RSA case did not complete" "got: $(echo "$rsa" | head -2)" ;;
esac

# ---- 3. repeatably ---------------------------------------------------------------------------
#
# A handshake involves fresh random every time -- a new private key, a new client random. One
# success can hide an assumption that happens to hold for one key; five cannot.
n=0
i=0
while [ $i -lt 5 ]; do
  r=$("$tmp/cli" "$port" localhost 2>/dev/null || true)
  case "$r" in *HANDSHAKE-OK*) n=$((n+1)) ;; esac
  i=$((i+1))
done
if [ "$n" -eq 5 ]; then ok "five handshakes in a row, each with fresh keys"
else bad "only $n of 5 handshakes succeeded" "fresh random exposes an assumption"; fi

# ---- 4. THE AUTHENTICATION IS LOAD-BEARING ---------------------------------------------------
#
# The check this file exists for. A client that decrypts without verifying the tag behaves
# exactly like a correct one until an attacker changes a byte -- and then accepts it.
#
# Rather than attack the socket from outside, the client is rebuilt with one byte of every
# ENCRYPTED record flipped before it is opened. The correct behaviour is a refusal.
#
# MEASURED 22-09-2026: flipping a byte in an UNENCRYPTED record (the ServerHello) changes
# nothing, because there is no tag on it yet -- the first version of this check did exactly
# that and passed while proving nothing. The byte has to land inside a record that carries a
# tag.
# THE SABOTAGED BUILD NEEDS ITS OWN COMPILER BESIDE ITS OWN lib/, because the compiler
# resolves the standard library relative to its OWN location -- `wantzel --version` prints
# the path it will use. Copying only the sources and pointing at them does not work, and a
# first version of this check did exactly that: it silently built the GOOD client and then
# reported that a tampered record had been accepted.
mkdir -p "$tmp/pg/lib" "$tmp/pg/bin"
cp "$here"/lib/*.wz "$tmp/pg/lib/"
cp "$here/bin/wantzel" "$tmp/pg/bin/"
awk '/tls\.mknonce\(tls\.siv, tls\.sseq\);/ && !done {
       print "  tls.plain[0] := chr(bxor(ord(tls.plain[0]), 1));"; done=1 }
     { print }' "$here/lib/tls.wz" > "$tmp/pg/lib/tls.wz"

# THE SABOTAGE MUST ACTUALLY BE IN THE FILE. An awk pattern that matches nothing leaves a
# perfect copy, and then this whole check passes while testing the unmodified client.
if ! grep -q "bxor(ord(tls.plain\[0\]), 1)" "$tmp/pg/lib/tls.wz"; then
  bad "the sabotage did not apply" "tls.mknonce(tls.siv, ...) not found in lib/tls.wz"
elif "$tmp/pg/bin/wantzel" "$tmp/cli.wz" "$tmp/cli_sab" >/dev/null 2>&1; then
  sab=$("$tmp/cli_sab" "$port" localhost 2>&1 || true)
  case "$sab" in
    *HANDSHAKE-OK*) bad "a tampered record was ACCEPTED" \
                        "the tag is not being checked; encryption without authentication" ;;
    *authenticate*) ok "a tampered record is refused, so the tag is really checked" ;;
    *) bad "a tampered record failed for the wrong reason" "got: $(echo "$sab" | head -2)" ;;
  esac
else
  bad "the sabotaged client does not build" "$("$tmp/pg/bin/wantzel" "$tmp/cli.wz" "$tmp/cli_sab" 2>&1 | head -2)"
fi

# ---- 5. AND THE OTHER DIRECTION: OUR SERVER, OPENSSL'S CLIENT --------------------------------
#
# Everything above tests our CLIENT against their server. This is the mirror, and it is not
# a formality: the two directions share the record layer and the key schedule but use the
# traffic secrets the opposite way round. A server that writes with the client's secret
# encrypts happily and can be read by nobody -- and the first symptom is a tag failure,
# which reads like a corrupted record rather than a swapped key.
#
# It also exercises the half of the handshake the client never runs: building a ServerHello,
# sending the certificate, and SIGNING the transcript rather than verifying it.
srvport=$(( port + 2 ))
D=$(openssl ec -in "$tmp/k.pem" -text -noout 2>/dev/null \
    | sed -n '/priv:/,/pub:/p' | tr -d ' :\n' | sed 's/priv//;s/pub//' | tail -c 65)
openssl x509 -in "$tmp/c.pem" -outform DER -out "$tmp/c.der" 2>/dev/null

cat > "$tmp/srv.wz" <<WZ
include "io.wz";
include "net.wz";
include "fs.wz";
include "tls.wz";
var lfd, fd, base, n, i: int;
    cert: array[0..8191] of char;
    d: array[0..P.N-1] of int;
    path: array[0..255] of char;
    body: array[0..511] of char;
    ts: array[0..15] of char;
procedure nap(ns: int);
var k: int;
begin
  k := 0;
  while k < 16 do begin ts[k] := chr(0); k := k + 1; end;
  k := 8;
  while k < 16 do begin ts[k] := chr(band(ns, 255)); ns := ns shr 8; k := k + 1; end;
  sys2(SYS.nanosleep, addr(ts[0]), 0);
end;
procedure setpath(s: str);
var k: int;
begin
  k := 0;
  while k < slen(s) do begin path[k] := schar(s, k); k := k + 1; end;
  path[k] := chr(0);
end;
begin
  p256.setup;
  p256.hexto(d, "$D");
  setpath("c.der");
  base := fs.map(addr(path[0]));
  if base < 0 then begin io.puts(STDERR, "no certificate\n"); halt(1); end;
  n := fs.size;
  i := 0;
  while i < n do begin cert[i] := chr(peek(base + i)); i := i + 1; end;
  fs.unmap(base, n);
  if not tls.setcert(cert, n, d) then halt(1);
  lfd := net.listen($srvport, 8, false);
  if lfd < 0 then halt(1);
  io.puts(STDOUT, "LISTENING\n");
  // A NON-BLOCKING accept RETURNS IMMEDIATELY, so a bounded loop without a pause runs out
  // in milliseconds and the program exits before any client arrives -- measured, and it
  // looked exactly like "connection refused" while the process was still alive.
  i := 0;
  while i < 30000 do
  begin
    fd := net.accept(lfd);
    if fd < 0 then nap(1000000);
    if fd >= 0 then
    begin
      if tls.accept(fd) then
      begin
        io.puts(STDOUT, "SERVED\n");
        n := io.push(body, 0, "HTTP/1.0 200 OK\r\nContent-Length: 12\r\n\r\nfrom wantzel");
        if tls.write(body, n) then i := i;
      end
      else
      begin
        io.puts(STDOUT, "SRVFAIL ");
        io.puts(STDOUT, tls.errmsg);
        io.puts(STDOUT, "\n");
      end;
      net.close(fd);
      return;
    end;
    i := i + 1;
  end;
end.
WZ
if "$here/bin/wantzel" "$tmp/srv.wz" "$tmp/srvbin" >/dev/null 2>&1; then
  ( cd "$tmp" && ./srvbin > srv.out 2>&1 & )
  i=0
  while [ $i -lt 50 ]; do
    ss -tln 2>/dev/null | grep -q ":$srvport " && break
    sleep 0.1; i=$((i+1))
  done
  # A REQUEST, AND THEN A PAUSE BEFORE CLOSING. `</dev/null` makes s_client send EOF the
  # instant the handshake is done, so it can be gone before the server's reply arrives --
  # measured: the standalone run won that race and the same file under wztest lost it, which
  # is the classic "passes alone, fails in the suite" shape.
  #
  # Sending a request and waiting a second makes the outcome depend on the server rather than
  # on scheduling.
  cli=$( (printf 'GET / HTTP/1.0\r\n\r\n'; sleep 2) \
         | timeout 25 openssl s_client -connect "127.0.0.1:$srvport" -tls1_3 \
           -servername localhost -brief 2>&1 || true)
  sleep 1
  case "$cli" in
    *"CONNECTION ESTABLISHED"*) ok "openssl's client completes a handshake with OUR server" ;;
    *) bad "openssl could not connect to our server" "$(echo "$cli" | head -3)" \
           "$(cat "$tmp/srv.out" 2>/dev/null | head -3)" ;;
  esac
  # THE NEGOTIATED PARAMETERS, not just "it connected". A fallback to another suite or group
  # would still say CONNECTION ESTABLISHED and would mean the server is not doing what it
  # claims.
  case "$cli" in
    *TLS_CHACHA20_POLY1305_SHA256*) ok "and negotiates the suite we implement" ;;
    *) bad "an unexpected cipher suite was negotiated" "$(echo "$cli" | grep -i cipher)" ;;
  esac
  case "$cli" in
    *X25519*) ok "and X25519 for the key exchange" ;;
    *) bad "an unexpected group was used" "$(echo "$cli" | grep -i 'Temp Key')" ;;
  esac
  # THE SIGNATURE IS THE PART ONLY THE SERVER DOES. openssl reports the type it verified, so
  # this says our CertificateVerify was accepted by an independent implementation.
  case "$cli" in
    *"Signature type: ECDSA"*) ok "and openssl accepted the transcript signature we made" ;;
    *) bad "our CertificateVerify was not accepted" "$(echo "$cli" | grep -i signature)" ;;
  esac
  case "$cli" in
    *"from wantzel"*) ok "and application data flows back from our server" ;;
    *) bad "no application data came through" "$(echo "$cli" | tail -3)" ;;
  esac
else
  bad "the server program does not compile" \
      "$("$here/bin/wantzel" "$tmp/srv.wz" "$tmp/srvbin" 2>&1 | head -2)"
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
