# lib/der.wz and lib/x509.wz: reading a real certificate, and refusing a malformed one.
#
# THE CERTIFICATES ARE MADE BY OPENSSL, for the same reason the TLS test talks to OpenSSL:
# a parser tested only against bytes it produced itself agrees with its own misunderstanding.
# These are ordinary certificates, encoded by a different implementation.
#
# WHAT IS ESTABLISHED:
#   1. the fields a client needs come out, and match what OpenSSL says they are
#   2. hostname matching follows RFC 6125, INCLUDING the cases that are security bugs when
#      they go the other way -- a wildcard must not cross a dot, and *.com must be refused
#   3. a truncated or corrupted certificate is REFUSED rather than read past the end
#
# That third one is why der.wz checks a length on every single step: these bytes arrive from
# whoever answered the socket, before anything about them is trusted.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "  skip  openssl is not installed, so there are no certificates to read"
  exit 0
fi

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

# A certificate with several SANs and a wildcard, so the name matching has something to work
# with. -addext puts them in as a real extension rather than only in the subject.
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/k.pem" -out "$tmp/c.pem" \
  -days 30 -nodes -subj "/CN=example.com" \
  -addext "subjectAltName=DNS:example.com,DNS:www.example.com,DNS:*.api.example.com" \
  >/dev/null 2>&1 || { echo "  FAIL  cannot make a test certificate"; exit 1; }
openssl x509 -in "$tmp/c.pem" -outform DER -out "$tmp/c.der" 2>/dev/null

# WHAT OPENSSL SAYS THE ANSWER IS. Read here rather than hard-coded, so the expected values
# come from the other implementation and not from what this parser happens to produce.
want_notafter=$(openssl x509 -in "$tmp/c.pem" -noout -enddate | sed 's/notAfter=//')
want_epoch=$(date -u -d "$want_notafter" +%s)

cat > "$tmp/t.wz" <<WZ
include "io.wz";
include "fs.wz";
include "x509.wz";
var base, n, i, failures: int;
    cert: array[0..8191] of char;
    path: array[0..511] of char;
procedure setpath(s: str);
var k: int;
begin
  k := 0;
  while (k < slen(s)) and (k < len(path) - 1) do begin path[k] := schar(s, k); k := k + 1; end;
  path[k] := chr(0);
end;
procedure expect(good: bool; what: str);
begin
  if good then io.puts(STDOUT, "ok   ")
  else begin io.puts(STDOUT, "FAIL "); failures := failures + 1; end;
  io.puts(STDOUT, what);
  io.puts(STDOUT, "\n");
end;
begin
  failures := 0;
  setpath("cert.der");
  base := fs.map(addr(path[0]));
  if base < 0 then begin io.puts(STDOUT, "FAIL cannot map the certificate\n"); halt(1); end;
  n := fs.size;
  i := 0;
  while i < n do begin cert[i] := chr(peek(base + i)); i := i + 1; end;
  fs.unmap(base, n);

  expect(x509.parse(cert, 0, n), "a real certificate parses");
  io.puts(STDOUT, "NOTAFTER ");
  io.putn(STDOUT, x509.notafter);
  io.puts(STDOUT, "\n");

  // THE KEY IS FOUND AND IS RSA. A parser that walked to the wrong element would still set
  // some offset; checking the algorithm as well as the presence is what makes this mean
  // something.
  expect(x509.keyalg = 1, "the public key is recognised as RSA");
  expect(x509.keyn > 200, "and the key is a plausible size");
  expect(x509.sigalg = 1, "the signature algorithm is sha256WithRSA");
  expect(x509.sign > 200, "and the signature has a plausible length");

  // THE SIGNED BYTES. The tbsCertificate must start with a SEQUENCE tag and be most of the
  // certificate -- if the slice were off by even its own header the signature could never
  // verify, and that failure would look like a bad key.
  expect(ord(cert[x509.tbsat]) = 0x30, "the signed bytes start at a SEQUENCE");
  expect((x509.tbsn > n div 2) and (x509.tbsn < n), "and cover most of the certificate");

  expect(x509.names = 3, "all three subjectAltName entries are found");

  // ---- hostname matching, RFC 6125 -------------------------------------------------------
  expect(x509.matches(cert, "example.com"), "the exact name matches");
  expect(x509.matches(cert, "www.example.com"), "a second listed name matches");
  expect(x509.matches(cert, "EXAMPLE.COM"), "and matching ignores case");
  expect(x509.matches(cert, "v1.api.example.com"), "a wildcard matches one label");

  // THE REFUSALS, and each one is a real vulnerability when it goes the other way.
  expect(not x509.matches(cert, "other.com"), "an unlisted name does not match");
  expect(not x509.matches(cert, "api.example.com"),
         "a wildcard does NOT match the bare domain it wildcards");
  expect(not x509.matches(cert, "a.b.api.example.com"),
         "a wildcard does NOT cross a dot");
  expect(not x509.matches(cert, "example.com.evil.com"),
         "a name is not matched by a suffix of a longer one");

  // ---- malformed input -------------------------------------------------------------------
  //
  // A TRUNCATED CERTIFICATE MUST BE REFUSED, not read past the end. This is the case the
  // bounds checks in der.wz exist for: the outer SEQUENCE still claims the full length while
  // only half the bytes are present.
  expect(not x509.parse(cert, 0, n div 2), "a truncated certificate is refused");

  // A LENGTH THAT CLAIMS MORE THAN THE BUFFER. Byte 2 and 3 are the outer length in a
  // two-byte long form; setting them high makes the certificate claim far more than it has.
  cert[2] := chr(255);
  cert[3] := chr(255);
  expect(not x509.parse(cert, 0, n), "a length running past the buffer is refused");

  // ---- THE TWO-DIGIT YEAR RULE -----------------------------------------------------------
  //
  // UTCTime has no century, and RFC 5280 4.1.2.5.1 fixes it by fiat: 50..99 is 19xx and
  // 00..49 is 20xx. The certificate above expires in 2026, so "always 20xx" gives the right
  // answer for it -- MEASURED 22-09-2026: sabotaging the rule left this file GREEN at 19 ok.
  // The rule is therefore checked directly, on both sides of the boundary.
  //
  // 490101000000Z is 2049-01-01 and 500101000000Z is 1950-01-01, one year apart in the text
  // and ninety-nine apart in meaning.
  setpath("490101000000Z");
  expect(x509.time(path, 0, 13, true) = 2493072000, "year 49 in a UTCTime means 2049");
  setpath("500101000000Z");
  expect(x509.time(path, 0, 13, true) < 0 - 600000000, "and year 50 means 1950, not 2050");

  // AND A LEAP YEAR IS A LEAP YEAR. 2000 was one (divisible by 400) and 1900 was not.
  // 2000-03-01 is 951868800; getting February wrong moves it by a day.
  setpath("000301000000Z");
  expect(x509.time(path, 0, 13, true) = 951868800, "2000 counts as a leap year");

  if failures > 0 then halt(1);
end.
WZ

cp "$tmp/c.der" "$tmp/cert.der"
"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" >/dev/null 2>&1 \
  || { echo "  FAIL  the test program does not compile"; exit 1; }

out=$(cd "$tmp" && ./t 2>&1) || true
echo "$out" | grep -v NOTAFTER | sed 's/^/  /'
if echo "$out" | grep -q FAIL; then
  fail=$((fail + $(echo "$out" | grep -c FAIL)))
else
  pass=$((pass + $(echo "$out" | grep -c '^ok')))
fi

# ---- THE DATE AGREES WITH OPENSSL ------------------------------------------------------------
#
# The one field where a parser can be confidently, consistently wrong: the two-digit year
# rule, leap years, and the epoch arithmetic all have to be right at once, and a wrong answer
# is still a plausible timestamp. Compared against `date`, which computed it independently.
got_epoch=$(echo "$out" | grep NOTAFTER | awk '{print $2}')
if [ "$got_epoch" = "$want_epoch" ]; then
  ok "notAfter agrees with openssl to the second ($got_epoch)"
else
  bad "the parsed notAfter does not match openssl" \
      "ours: $got_epoch   openssl: $want_epoch ($want_notafter)" \
      "a wrong date is still a plausible timestamp, which is why this is checked"
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
