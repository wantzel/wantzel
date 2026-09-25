# lib/dns.wz's AAAA support and lib/net.wz's IPv6 sockets, together: a fake resolver that
# answers AAAA (and, for some names, A too), and dns.connect reaching a REAL listener this
# same process opens on ::1 and on 127.0.0.1.
#
# The server is tests/helpers/dnsfake.wz (the same fixture as tests/lib/dns.sh, extended
# with v6only.test, v6dual.test, v6cname.test, v6loop.test and dualoop.test -- see the
# comment at the top of that file for what each answers). The client is
# tests/helpers/dnsprobe.wz, extended with !6=<name> (dns.resolve6), !listen4=/!listen6=
# (open a real loopback listener) and !connect=<name>:<port> (dns.connect, reporting which
# listener actually took the connection).
#
# WHAT A GREEN RUN ESTABLISHES:
#   - dns.resolve6 reads AAAA records: plain, through a CNAME chain, and NODATA when a name
#     has no AAAA record (v6only.test asked for its A record) or no A record (a.test asked
#     for AAAA) -- the type asked decides what answers, not just what exists
#   - dns.connect resolves BOTH families and reaches an AAAA-only host over a real IPv6
#     socket -- an AAAA-only host is reachable by name
#   - given a choice, dns.connect tries IPv6 first, and only falls back to IPv4 when no v6
#     address accepts (checked by which of two listeners on the SAME port actually took
#     the connection, not merely that a connection was made)
#   - no listener at all: dns.connect fails cleanly (DNS.NOCONNECT), not a hang -- a real
#     regression during development of this test: a resolved address that is not
#     LOOPBACK blocks in net.connect's TCP handshake for a long time, so every address a
#     fake nameserver hands out here must be one this test can actually reach or refuse
#   - net.listen6 sets IPV6_V6ONLY, so an IPv4 and an IPv6 listener can share one port
#     number without EADDRINUSE -- needed for the "tries v6 first" check above
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }
has() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1" "wanted: $3" "got:" "$2"; fi; }

set -- $(free_ports 6)
good=$1; cport1=$2; cport2=$3; cport3=$4; cport4=$5; cport5=$6

compile "$ROOT/tests/helpers/dnsfake.wz" "$T/dnsfake"
compile "$ROOT/tests/helpers/dnsprobe.wz" "$T/probe"

pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

"$T/dnsfake" "$good" normal >"$T/normal.log" 2>&1 &
pids="$pids $!"
_n=0
while [ $_n -lt 50 ]; do
  grep -q '^ready$' "$T/normal.log" 2>/dev/null && break
  _n=$((_n + 1)); sleep 0.1
done
grep -q '^ready$' "$T/normal.log" 2>/dev/null || { echo "dnsfake did not start:"; cat "$T/normal.log"; exit 1; }

probe() { timeout 20 "$T/probe" "$good" 1000 3000 "$@"; }

# ---- dns.resolve6: plain, CNAME chain, and NODATA both ways -----------------------------------
out=$(probe '!6=v6loop.test')
has "AAAA-only: dns.resolve6 gets its address" "$out" "v6loop.test 0000:0000:0000:0000:0000:0000:0000:0001"
out=$(probe '!6=v6dual.test' v6dual.test)
has "a name with both records: AAAA via dns.resolve6" "$out" "v6dual.test 2001:0db8:0000:0000:0000:0000:0000:0053"
out=$(probe '!6=v6dual.test' v6dual.test)
has "  and A via dns.resolve, the SAME name" "$out" "v6dual.test 10.11.12.13"
out=$(probe '!6=v6cname.test')
has "a CNAME chain is followed under AAAA too" "$out" "v6cname.test 2001:0db8:0000:0000:0000:0000:0000:0001"
out=$(probe '!6=v6loop.test' v6loop.test)
has "AAAA-only host: A comes back NODATA, not the AAAA address" "$out" "v6loop.test error -2 the name exists but has no IPv4 address"
out=$(probe a.test '!6=a.test')
has "an A-only host: AAAA comes back NODATA" "$out" "a.test error -2 the name exists but has no IPv4 address"

# ---- the main check: dns.connect reaches an AAAA-only host -----------------------------
cport=$cport1
out=$(probe "!listen6=$cport" "!connect=v6loop.test:$cport")
has "dns.connect reaches an AAAA-only host over a real IPv6 socket" "$out" "v6loop.test connect ok via v6"

cport=$cport2
out=$(probe "!connect=v6loop.test:$cport")
has "no listener at all: dns.connect fails cleanly, not a hang" "$out" "v6loop.test error -10 the name resolved, but no address accepted the connection"

# ---- ordering: IPv6 first, IPv4 as the fallback --------------------------------------------------
cport=$cport3
out=$(probe "!listen4=$cport" "!listen6=$cport" "!connect=dualoop.test:$cport")
has "both families reachable, same port: IPv6 is tried first" "$out" "dualoop.test connect ok via v6"

cport=$cport4
out=$(probe "!listen4=$cport" "!connect=dualoop.test:$cport")
has "only IPv4 reachable: falls back to it" "$out" "dualoop.test connect ok via v4"

cport=$cport5
out=$(probe "!listen6=$cport" "!connect=dualoop.test:$cport")
has "only IPv6 reachable: connects over it" "$out" "dualoop.test connect ok via v6"

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
