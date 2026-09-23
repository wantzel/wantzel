# examples/localhttps.wz, loaded by Chromium: a browser completes the handshake and shows the page.
#
# TOETSGROEP: lib
# DEKT: lib/tls.wz lib/der.wz lib/csr.wz examples/localhttps.wz
#
# WHY CHROMIUM AND NOT ONLY OPENSSL. curl and openssl s_client completed a clean handshake
# against this example while every Chromium-based browser refused it with
# ERR_SSL_PROTOCOL_ERROR. The certificate was the cause: lib/der.wz wrote every length in
# the two-byte long form, which OpenSSL accepts and BoringSSL rejects as not being DER. The
# openssl-based tests (selfsign.sh, serve.sh) could not see it, because the arbiter shared
# the leniency. tests/lib/der_minimal.wz checks the encoding rule itself; this checks that
# the browser most people use actually loads the page.
#
# CHROMIUM IS NOT A DEPENDENCY OF THE REPOSITORY, so without it this test says so and
# skips. It looks for $CHROMIUM, then a chromium, chrome or chrome-headless-shell on PATH,
# then the headless shell a Playwright install leaves in ~/.cache/ms-playwright.
#
# --ignore-certificate-errors because the certificate is self-signed and nothing vouches
# for it. That turns off TRUST, not PARSING: a certificate BoringSSL cannot parse still
# fails the handshake, which is exactly what this guards.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

browser=""
if [ -n "${CHROMIUM:-}" ] && [ -x "$CHROMIUM" ]; then browser=$CHROMIUM; fi
if [ -z "$browser" ]; then
  for name in chrome-headless-shell chromium chromium-browser google-chrome google-chrome-stable; do
    if command -v "$name" >/dev/null 2>&1; then browser=$(command -v "$name"); break; fi
  done
fi
if [ -z "$browser" ]; then
  for f in "$HOME"/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
           "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux64/chrome; do
    if [ -x "$f" ]; then browser=$f; break; fi
  done
fi
if [ -z "$browser" ]; then
  echo "  skip  no Chromium found (set CHROMIUM, or install one); the handshake with a browser is not checked"
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

port=$(( 20000 + $$ % 5000 ))

"$here/bin/wantzel" "$here/examples/localhttps.wz" "$tmp/localhttps" >"$tmp/build.log" 2>&1 \
  || { echo "  FAIL  examples/localhttps.wz does not compile"; cat "$tmp/build.log"; exit 1; }

"$tmp/localhttps" "$port" >"$tmp/srv.log" 2>&1 &
started="$started $!"
i=0; while [ $i -lt 60 ] && ! grep -q listening "$tmp/srv.log" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
grep -q listening "$tmp/srv.log" || { echo "  FAIL  the example did not start"; cat "$tmp/srv.log"; exit 1; }
ok "examples/localhttps.wz listens on $port"

# THREE ATTEMPTS, because a headless browser can dump the page before a slow first load has
# finished. A handshake failure fails all three: it is not timing, it is the certificate.
attempt=0; page=""
while [ $attempt -lt 3 ]; do
  attempt=$((attempt+1))
  timeout 60 "$browser" --headless --no-sandbox --disable-gpu --no-first-run \
      --user-data-dir="$tmp/profile$attempt" --ignore-certificate-errors \
      --virtual-time-budget=3000 --dump-dom "https://127.0.0.1:$port/" \
      >"$tmp/page.html" 2>"$tmp/browser.log" || true
  if grep -q "served over locally-signed TLS" "$tmp/page.html"; then page=yes; break; fi
done

if [ -n "$page" ]; then
  ok "Chromium completes the TLS 1.3 handshake and shows the page"
else
  bad "Chromium did not load the page over TLS"
  grep -i "handshake\|ssl\|net_error" "$tmp/browser.log" | head -5 | sed 's/^/        /'
fi

echo "tls_chromium: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
