# examples/serve.wz: one binary, one loop, HTTP and HTTPS and the ACME challenge together.
#
# TOETSGROEP: lib
# DEKT: examples/serve.wz
#
# THIS IS AN ARCHITECTURE TEST, not a crypto one. The algorithms are covered by tls.sh,
# chain.sh and the rest; what is checked here is that there is ONE process doing all of it --
# no reverse proxy, no certbot, no cron, no shell hook.
#
# WHAT IS ESTABLISHED:
#   1. plain HTTP is served
#   2. HTTPS is served from the same binary, with its own certificate
#   3. the ACME challenge path is answered by the SAME listener that serves HTTP, which is
#      the whole point -- the authority fetches it while the server is running
#   4. with a certificate, plain HTTP redirects; without one it does not, because during a
#      first order there is nowhere to redirect TO
#   5. exactly ONE process, which is the claim this file exists to check
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
. "$here/tests/lib/portlib.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

if ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  skip  openssl and curl are both needed"
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

"$here/bin/wantzel" "$here/examples/serve.wz" "$tmp/serve" >build.log 2>&1 \
  || { echo "  FAIL  serve.wz does not compile"; cat build.log; exit 1; }
ok "the server builds, $(stat -c%s "$tmp/serve") bytes"

# FOUR free ports (two servers, each with its own plain and TLS port), from the kernel via
# tests/lib/portlib.sh -- not guessed from a range "picked high enough to avoid the usual
# suspects", which is exactly the guess that collides under many parallel ./wztest runs.
set -- $(free_ports 4)
p80=$1; p443=$2; p80b=$3; p443b=$4

# ---- 1. WITHOUT A CERTIFICATE ------------------------------------------------------------
"$tmp/serve" "$p80" "$p443" local.wantzel.com >nocert.log 2>&1 &
started="$started $!"
i=0; while [ $i -lt 50 ]; do ss -tln 2>/dev/null | grep -q ":$p80 " && break; sleep 0.1; i=$((i+1)); done

body=$(curl -s --max-time 5 "http://127.0.0.1:$p80/" || true)
case "$body" in
  *"no certificate"*) ok "without a certificate it serves plain HTTP and says so" ;;
  *) bad "the plain page was not what it should be" ;;
esac

# NO REDIRECT WITHOUT A CERTIFICATE. Sending the authority to a port that cannot answer yet
# is how a first order fails in a way that looks like a network problem.
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$p80/" || true)
[ "$code" = "200" ] && ok "and it does NOT redirect to a port that cannot answer yet" \
                    || bad "it redirected with no certificate to redirect to (got $code)"

# THE CHALLENGE PATH IS ANSWERED BY THIS LISTENER, not 404'd by a different server. With no
# order open the honest answer is 404 -- what matters is that the path is recognised.
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
       "http://127.0.0.1:$p80/.well-known/acme-challenge/sometoken" || true)
[ "$code" = "404" ] && ok "the ACME challenge path is handled by the same listener" \
                    || bad "the challenge path gave $code, so something else is serving it"

# STOP THE FIRST SERVER BY ITS PID, not with %1: job control is not reliable in a script
# run with sh, and the count at the end then finds two processes and blames the program.
first=$(echo $started | awk '{print $1}')
kill "$first" 2>/dev/null || true
i=0; while [ $i -lt 30 ] && kill -0 "$first" 2>/dev/null; do sleep 0.1; i=$((i+1)); done

# ---- 2. WITH A CERTIFICATE ---------------------------------------------------------------
openssl ecparam -name prime256v1 -genkey -noout -out k.pem 2>/dev/null
openssl req -x509 -key k.pem -out c.pem -days 30 -subj "/CN=local.wantzel.com" \
  -addext "subjectAltName=DNS:local.wantzel.com" 2>/dev/null
openssl x509 -in c.pem -outform DER -out cert.der 2>/dev/null
# The private scalar as 64 hex digits: openssl prints it under "priv:" as indented lines of
# colon-separated bytes, sometimes with a leading 00 -- so keep the LAST 64 digits, and pad a
# short one on the left.
h=$(openssl ec -in k.pem -noout -text 2>/dev/null \
    | awk '/^priv:/{f=1;next} f&&/^[ \t]/{print;next} {f=0}' | tr -dc '0-9a-f')
h=$(printf '%s' "$h" | tail -c 64)
while [ ${#h} -lt 64 ]; do h="0$h"; done
printf '%s' "$h" > key.hex

"$tmp/serve" "$p80b" "$p443b" local.wantzel.com >cert.log 2>&1 &
started="$started $!"
i=0; while [ $i -lt 50 ]; do ss -tln 2>/dev/null | grep -q ":$p443b " && break; sleep 0.1; i=$((i+1)); done

grep -q "certificate loaded" cert.log && ok "the certificate is picked up from disk at startup" \
                                      || bad "the certificate on disk was not loaded"

body=$(curl -s --max-time 10 --resolve "local.wantzel.com:$p443b:127.0.0.1" \
       --cacert c.pem "https://local.wantzel.com:$p443b/" || true)
case "$body" in
  *"over its own TLS"*) ok "it serves HTTPS from the same binary, with a verified certificate" ;;
  *) bad "the HTTPS fetch failed" "got: $(echo "$body" | head -1)" ;;
esac

# AND NOW THE REDIRECT, because there is somewhere to redirect to.
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$p80b/" || true)
[ "$code" = "301" ] && ok "and plain HTTP now redirects to it" \
                    || bad "expected a redirect once a certificate exists, got $code"

# ---- 3. ONE PROCESS, which is the claim ---------------------------------------------------
n=$(pgrep -c -f "$tmp/serve" 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "exactly one process serves HTTP, HTTPS and the challenge" \
               || bad "expected one process, found $n"

echo "serve: $pass ok, $fail fail"
[ "$fail" -eq 0 ]
