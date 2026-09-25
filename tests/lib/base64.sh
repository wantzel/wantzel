# lib/base64.wz: both alphabets, both padding modes, against an independent encoder.
#
# WHY IT EARNS A TEST NOW. JWS depends on it completely: every field of an ACME request is
# base64url, and the rule there is unforgiving -- a padded value is a DIFFERENT string, so
# it changes the signed bytes and the key thumbprint, and the certificate authority answers
# with an error that points nowhere near here.
#
# THE EXPECTATIONS COME FROM THE `base64` TOOL, not from this implementation. The URL form is
# derived from it by the RFC 4648 rule itself: swap + and / for - and _, drop the padding.
#
# WHAT IS CHECKED, and the awkward cases are the point:
#   - the three length classes mod 3, which is where padding is decided
#   - the empty input
#   - bytes 62 and 63, the only two that DIFFER between the standard and URL alphabets
#     (+/ against -_), so an encoder using the wrong table is identical everywhere else
#   - a round trip through the decoder
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
import base64;
var src: array[0..63] of char;
    dst: array[0..255] of char;
    back: array[0..63] of char;
    i, n, m: int;
// Encode the first n bytes of src, both alphabets, and print both.
procedure show(n: int);
var k: int;
begin
  k := base64.enc(dst, 0, view(addr(src[0]), n), false, true);
  io.puts(STDOUT, "STD ");
  io.out(STDOUT, addr(dst[0]), k);
  io.puts(STDOUT, "\n");
  k := base64.enc(dst, 0, view(addr(src[0]), n), true, false);
  io.puts(STDOUT, "URL ");
  io.out(STDOUT, addr(dst[0]), k);
  io.puts(STDOUT, "\n");
end;
begin
  // 0xFB 0xFF chosen deliberately: they encode to the symbols at index 62 and 63, which are
  // the ONLY two positions where the two alphabets differ.
  src[0] := chr(0xFB); src[1] := chr(0xEF); src[2] := chr(0xBE);
  show(3);
  // one byte left over, and two bytes left: the two padding cases
  src[0] := chr(0x4D); src[1] := chr(0x61); src[2] := chr(0x6E); src[3] := chr(0x21);
  show(4);
  show(5);
  show(1);
  show(0);
  // A round trip: encode 32 bytes, decode them, compare.
  i := 0;
  while i < 32 do begin src[i] := chr(band(i * 7 + 3, 255)); i := i + 1; end;
  n := base64.enc(dst, 0, view(addr(src[0]), 32), false, true);
  m := base64.decode(view(addr(dst[0]), n), back);
  io.puts(STDOUT, "RT ");
  if m <> 32 then io.puts(STDOUT, "length-wrong")
  else
  begin
    i := 0;
    while (i < 32) and (back[i] = src[i]) do i := i + 1;
    if i = 32 then io.puts(STDOUT, "ok") else io.puts(STDOUT, "bytes-differ");
  end;
  io.puts(STDOUT, "\n");
end.
WZ
"$here/bin/wantzel" "$tmp/t.wz" "$tmp/t" >/dev/null 2>&1 \
  || { echo "  FAIL  the test program does not compile"; exit 1; }
out=$("$tmp/t" 2>&1) || true

# The same five inputs, encoded by the system's base64 (given as hex, so the bytes are exact).
want=$(for h in fbefbe 4d616e21 4d616e2100 4d ''; do
  enc=$(printf '%s' "$h" | xxd -r -p | base64 -w0)
  printf 'STD %s\n' "$enc"
  printf 'URL %s\n' "$(printf '%s' "$enc" | tr '+/' '-_' | tr -d '=')"
done)

got=$(echo "$out" | grep -E '^(STD|URL)')
if [ "$got" = "$want" ]; then
  ok "both alphabets and both padding modes match the base64 tool, over five inputs"
else
  # NO PROCESS SUBSTITUTION: the suite runs this with sh, where `<(...)` is a bashism that
  # passes when the file is run alone and dies with "Syntax error" in the suite.
  echo "$got"  > "$tmp/got.txt"
  echo "$want" > "$tmp/want.txt"
  bad "the encoding differs from the base64 tool" "$(diff "$tmp/got.txt" "$tmp/want.txt" | head -8)"
fi

# THE TWO SYMBOLS THAT DIFFER. Checked by name, because an encoder using the standard table
# for urlencode is byte-identical on 62 of 64 symbols -- and would pass a test that only used
# ordinary text.
first_url=$(echo "$out" | awk 'NR==2{print $2}')
case "$first_url" in
  *-*|*_*) ok "the URL alphabet really uses - and _ for 62 and 63" ;;
  *) bad "the URL alphabet does not differ from the standard one" "got: $first_url" ;;
esac
case "$first_url" in
  *+*|*/*) bad "the URL alphabet still contains + or /" "got: $first_url" ;;
  *) ok "and contains neither + nor /" ;;
esac

# NO PADDING IN THE URL FORM. This is the one that breaks JWS silently.
if echo "$out" | grep -E '^URL' | grep -q '='; then
  bad "the URL form is padded" "a padded value is a different string, so it changes the signature"
else
  ok "the URL form carries no padding"
fi

case "$out" in
  *"RT ok"*) ok "a 32-byte round trip through the decoder is exact" ;;
  *) bad "the round trip failed" "$(echo "$out" | grep '^RT')" ;;
esac

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
