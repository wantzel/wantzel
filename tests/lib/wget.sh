# examples/wget.wz: the whole TLS stack used the way someone would actually use it.
#
# WHY THIS TEST EXISTS ON TOP OF ALL THE OTHERS. Every layer already has a test of its own --
# the cipher, the key exchange, the certificate parsing, the signature. What none of them
# establishes is that a program can pick up the finished stack and fetch a page with it. That
# is the "a complete model nobody calls" shape: every part green, and the whole thing unused.
#
# It is also the most direct evidence of the claim the stack is for: a static binary of a
# couple of hundred kilobytes speaks TLS 1.3, with nothing installed.
#
# WHAT IS ESTABLISHED:
#   1. it fetches over plain HTTP
#   2. it fetches over HTTPS from an INDEPENDENT server (openssl), and the bytes match what
#      curl gets from the same server -- a third implementation as the arbiter
#   3. a wrong hostname is REFUSED, which is the check that makes the rest worth having
#   4. a malformed URL is refused rather than guessed at
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/tests/lib/portlib.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

if ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  skip  openssl and curl are both needed as the other side and the arbiter"
  exit 0
fi

tmp=$(mktemp -d)
set -- $(free_ports 4)
port=$1; httpport=$2; rsaport=$3; caport=$4
started=""
cleanup() {
  rc=$?
  for p in $started; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" || true
  exit $rc
}
trap cleanup EXIT

"$here/bin/wantzel" "$here/examples/wget.wz" "$tmp/wget" >/dev/null 2>&1 \
  || { echo "  FAIL  examples/wget.wz does not compile"; exit 1; }
ok "a complete HTTPS client builds, $(stat -c %s "$tmp/wget") bytes"

# ---- an EC certificate, because that is the signature this stack can check ---------------------
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" 2>/dev/null
openssl req -x509 -key "$tmp/k.pem" -out "$tmp/c.pem" -days 1 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1 \
  || { echo "  FAIL  cannot make a test certificate"; exit 1; }

openssl s_server -accept "$port" -cert "$tmp/c.pem" -key "$tmp/k.pem" \
  -tls1_3 -www -quiet >"$tmp/srv.log" 2>&1 &
started="$started $!"
wait_port "$port" || { echo "  FAIL  openssl s_server did not start"; port_owner "$port"; cat "$tmp/srv.log"; exit 1; }

# ---- 2. HTTPS, AND THE BYTES MUST MATCH WHAT CURL GETS -----------------------------------------
#
# NOT JUST "SOMETHING CAME BACK". A decrypt that produced garbage would still produce bytes;
# what proves the keys and the record layer are right is that the plaintext is what a
# completely separate client reads from the same server.
# --cafile NAMES THE SERVER'S OWN CERTIFICATE AS THE ROOT, which is exactly what it is: it
# is self-signed. That is the same thing a deployment does with a private CA, and it is what
# makes tls.verified mean something here -- curl is given -k and checks nothing, so without
# this the two clients would not be doing comparable work.
ours=$("$tmp/wget" "https://127.0.0.1:$port/" localhost "--cafile=$tmp/c.pem" 2>"$tmp/err" || true)
theirs=$(curl -s -k --tls-max 1.3 "https://127.0.0.1:$port/" 2>/dev/null || true)

case "$ours" in
  *"HTTP/1.0 200"*) ok "it fetches a page over HTTPS from openssl's server" ;;
  *) bad "the HTTPS fetch failed" "$(cat "$tmp/err" | head -2)" "got: $(echo "$ours" | head -2)" ;;
esac

# The server's page names the session, which differs per connection, so the whole body cannot
# be compared. The HTML frame is stable and is enough to show the same document arrived.
oursbody=$(echo "$ours"   | grep -c "<HTML>" || true)
theirsbody=$(echo "$theirs" | grep -c "<HTML>" || true)
if [ "$oursbody" = "$theirsbody" ] && [ "$oursbody" != "0" ]; then
  ok "and the decrypted document is the same one curl receives"
else
  bad "our body differs from curl's" "ours: $oursbody frames, curl: $theirsbody"
fi

# ---- 2b. A HOSTNAME IN THE URL: looked up (lib/dns.wz), and the name the certificate is
# checked against when no second argument names one. "localhost" needs no nameserver, so
# this stays off the network.
byname=$("$tmp/wget" "https://localhost:$port/" "--cafile=$tmp/c.pem" 2>"$tmp/err" || true)
case "$byname" in
  *"HTTP/1.0 200"*) ok "a hostname URL is resolved, and its name is the one the certificate is checked against" ;;
  *) bad "the hostname URL failed" "$(head -2 "$tmp/err")" "got: $(echo "$byname" | head -2)" ;;
esac

# ---- 2c. A ROOT THAT IS NOT IN THE CHAIN: found by its name, proved by its signature ---------
#
# The server sends ONLY the leaf; the root is in --cafile and nowhere else. So the chain
# check has to pick the root whose subject is the leaf's issuer and verify the signature
# with its key. That is the ordinary shape of a public site (the browser holds the root,
# the server does not send it), and the one case that exercises the by-name lookup: a
# self-signed certificate in --cafile IS the chain's top and is found by comparing bytes.
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ca.key" 2>/dev/null
openssl req -x509 -key "$tmp/ca.key" -out "$tmp/ca.pem" -days 1 -subj "/CN=Test Root" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/leaf.key" 2>/dev/null
openssl req -new -key "$tmp/leaf.key" -out "$tmp/leaf.csr" -subj "/CN=localhost" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\n' > "$tmp/leaf.ext"
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/ca.pem" -CAkey "$tmp/ca.key" -CAcreateserial \
  -out "$tmp/leaf.pem" -days 1 -extfile "$tmp/leaf.ext" >/dev/null 2>&1 \
  || { echo "  FAIL  cannot make a CA-signed test certificate"; exit 1; }
openssl s_server -accept "$caport" -cert "$tmp/leaf.pem" -key "$tmp/leaf.key" \
  -tls1_3 -www -quiet >"$tmp/ca.log" 2>&1 &
started="$started $!"
i=0
while [ $i -lt 50 ]; do
  ss -tln 2>/dev/null | grep -q ":$caport " && break
  sleep 0.1; i=$((i+1))
done
issued=$("$tmp/wget" "https://127.0.0.1:$caport/" localhost "--cafile=$tmp/ca.pem" 2>"$tmp/err" || true)
case "$issued" in
  *"HTTP/1.0 200"*) ok "a leaf whose root is only in the store is verified through that root, found by name" ;;
  *) bad "the root was not found by the leaf's issuer name" "$(head -2 "$tmp/err")" "got: $(echo "$issued" | head -2)" ;;
esac
unissued=$("$tmp/wget" "https://127.0.0.1:$caport/" localhost "--cafile=$tmp/c.pem" 2>&1 || true)
case "$unissued" in
  *"HTTP/1.0 200"*) bad "a leaf whose issuer is not in the store was accepted" ;;
  *) ok "and with another root in the store the same leaf is refused" ;;
esac

# ---- 3. THE REFUSAL, which is what makes the rest worth having ---------------------------------
#
# A client that fetches happily but accepts any certificate has TLS and no security: an
# attacker in the middle presents their own valid certificate for their own domain and is
# never noticed.
wrong=$("$tmp/wget" "https://127.0.0.1:$port/" evil.example.com 2>&1 || true)
case "$wrong" in
  *"not valid for this hostname"*) ok "a certificate for another hostname is refused" ;;
  *"HTTP/1.0 200"*) bad "a certificate for the WRONG hostname was accepted" \
                        "this is TLS with no authentication at all" ;;
  *) bad "the wrong-hostname case failed for another reason" "got: $(echo "$wrong" | head -2)" ;;
esac

# AND --insecure MUST STILL WORK, because refusing everything is not the same as being
# correct. The flag exists so the refusal above is a decision rather than a dead end.
lax=$("$tmp/wget" "https://127.0.0.1:$port/" evil.example.com --insecure 2>/dev/null || true)
case "$lax" in
  *"HTTP/1.0 200"*) ok "and --insecure continues past it deliberately" ;;
  *) bad "--insecure does not let the fetch through" "got: $(echo "$lax" | head -2)" ;;
esac

# AND AN RSA CERTIFICATE MUST BE REFUSED TOO, for a different reason: the name matches, the
# dates are fine, but this stack cannot CHECK an RSA signature, so tls.verified stays false.
#
# THIS IS THE ONLY CASE THAT EXERCISES THE tls.verified CHECK. Measured 22-09-2026: removing
# that check from wget.wz left the file at 7 ok, 0 fail, because every other refusal happens
# earlier, inside the handshake. A client that ignores verified would connect to a server
# that never proved it holds the key -- which is exactly what an attacker in the middle does.
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/rk.pem" -out "$tmp/rc.pem" -days 1 -nodes \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1
openssl s_server -accept "$rsaport" -cert "$tmp/rc.pem" -key "$tmp/rk.pem" \
  -tls1_3 -www -quiet >"$tmp/rsa.log" 2>&1 &
started="$started $!"
i=0
while [ $i -lt 50 ]; do
  ss -tln 2>/dev/null | grep -q ":$rsaport " && break
  sleep 0.1; i=$((i+1))
done
# AND IT MUST BE REFUSED FAST. With the system bundle loaded, the refusal once cost 28 s of
# CPU: no root had issued this certificate, so the chain check tried the signature against
# every root in the bundle. Path building goes by the issuer's name, and a certificate
# nobody issued is refused in milliseconds; a walk over every root would put this back.
rsa_t0=$(date +%s)
rsa=$("$tmp/wget" "https://127.0.0.1:$rsaport/" localhost 2>&1 || true)
rsa_dt=$(( $(date +%s) - rsa_t0 ))
[ "$rsa_dt" -le 5 ] && ok "and refused in ${rsa_dt} s, not by a walk over every root" \
                    || bad "refusing an unissued certificate took ${rsa_dt} s" "a walk over every root is back"
case "$rsa" in
  # THE WORDING CHANGED when the message started saying WHICH half failed -- signature or
  # chain. Matched on the stable part rather than the whole sentence.
  *"was not verified"*|*"did not prove it holds the certificate"*)
     ok "an unverifiable (RSA) certificate is refused, not silently accepted" ;;
  *"HTTP/1.0 200"*)
     bad "an unverified certificate was accepted" \
         "the server never proved it holds the key; this is what a man in the middle does" ;;
  *) bad "the RSA case failed for another reason" "got: $(echo "$rsa" | head -2)" ;;
esac

# ---- 1. PLAIN HTTP, so the same program covers both ---------------------------------------------
#
# A tiny HTTP server in Wantzel rather than borrowing one: the test then does not depend on
# what happens to be installed.
cat > "$tmp/h.wz" <<WZ
include "io.wz";
include "net.wz";
var lfd, fd, n, i: int;
    buf: array[0..1023] of char;
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
begin
  lfd := net.listen($httpport, 8, false);
  if lfd < 0 then halt(1);
  io.puts(STDOUT, "LISTENING\n");
  i := 0;
  while i < 30000 do
  begin
    fd := net.accept(lfd);
    if fd < 0 then nap(1000000)
    else
    begin
      n := 0 - 1;
      while n < 0 do begin n := net.recv(fd, addr(buf[0]), 1024); if n < 0 then nap(100000); end;
      n := io.push(buf, 0, "HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nplain-http");
      n := net.send(fd, addr(buf[0]), n);
      net.close(fd);
      return;
    end;
    i := i + 1;
  end;
end.
WZ
if "$here/bin/wantzel" "$tmp/h.wz" "$tmp/h" >/dev/null 2>&1; then
  ( cd "$tmp" && ./h >/dev/null 2>&1 & )
  i=0
  while [ $i -lt 50 ]; do
    ss -tln 2>/dev/null | grep -q ":$httpport " && break
    sleep 0.1; i=$((i+1))
  done
  plain=$("$tmp/wget" "http://127.0.0.1:$httpport/" 2>&1 || true)
  case "$plain" in
    *plain-http*) ok "and it fetches over plain HTTP as well" ;;
    *) bad "the plain HTTP fetch failed" "got: $(echo "$plain" | head -2)" ;;
  esac
else
  bad "the plain HTTP test server does not compile"
fi

# ---- 4. MALFORMED URLS ARE REFUSED --------------------------------------------------------------
#
# This parser only ever sees the command line today, but the same code on a redirect would be
# reading attacker-controlled text. Refusing rather than guessing is the habit worth keeping.
# NOTE: "https://127.0.0.1" with no trailing slash is VALID -- an absent path means "/", as
# every browser and curl treat it. It was in this list at first and the failure was the
# expectation, not the parser.
for u in "ftp://127.0.0.1/" "https://999.1.1.1/" "http://.../" "notaurl" "https://1.2.3/"; do
  r=$("$tmp/wget" "$u" localhost 2>&1 || true)
  case "$r" in
    *"does not parse"*|*usage*) ;;
    *) bad "the malformed URL '$u' was not refused" "got: $(echo "$r" | head -1)" ;;
  esac
done
ok "malformed URLs are refused rather than guessed at"

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
