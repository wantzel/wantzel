# lib/dns.wz against a nameserver of our own: every answer shape the resolver must handle,
# and every way a lookup can fail, with nothing from the internet.
#
# The server is tests/helpers/dnsfake.wz, three of them on kernel-assigned free ports (see
# tests/lib/portlib.sh): one that answers, one that never does, one that answers everything
# with SERVFAIL -- and a fourth port where nothing listens. The client is
# tests/helpers/dnsprobe.wz, which prints each
# outcome as "<name> <address>..." or "<name> error <code> <message>", and the time each
# lookup took on stderr.
#
# WHAT A GREEN RUN ESTABLISHES:
#   - A records, a CNAME chain through compressed names (an unrelated A record in the same
#     reply is NOT taken), a chain that stops short and is asked for again
#   - NXDOMAIN, SERVFAIL, REFUSED and "no address" come back as four different codes
#   - records outside the answer (an SOA with compressed RDATA, NS and glue, OPT) and a
#     record of an unknown type are skipped, not taken and not a reason to reject the reply
#   - a truncated UDP reply is asked again over TCP
#   - a reply under the wrong id, and one for the wrong question, are both ignored
#   - compression pointers that loop, and a CNAME chain that loops, end in an error, fast
#   - answers are cached by TTL (a second lookup reaches no server; TTL 0 is not cached)
#   - a literal address and "localhost" need no server; a malformed name is refused
#   - a silent server costs one attempt's timeout and the next server answers; a closed
#     port or a SERVFAIL moves on at once; all servers silent ends within the total bound
#   - several lookups at once, driven from an epoll loop that watches dns.fd
#   - resolv.conf: comments, several nameservers, an IPv6 one skipped, options
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }
# has <label> <text> <line>: the text contains that exact line
has() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1" "wanted: $3" "got:" "$2"; fi; }
count() { grep -cxF -- "$2" "$1" || true; }

set -- $(free_ports 4)
good=$1; silent=$2; sfail=$3; closed=$4

compile "$ROOT/tests/helpers/dnsfake.wz" "$T/dnsfake"
compile "$ROOT/tests/helpers/dnsprobe.wz" "$T/probe"

pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

start() {   # start <port> <mode>: a server, and wait until it says it is listening
  "$T/dnsfake" "$1" "$2" >"$T/$2.log" 2>&1 &
  pids="$pids $!"
  _n=0
  while [ $_n -lt 50 ]; do
    grep -q '^ready$' "$T/$2.log" 2>/dev/null && return 0
    _n=$((_n + 1)); sleep 0.1
  done
  echo "the $2 server did not start on port $1:"; cat "$T/$2.log"; exit 1
}
start "$good" normal
start "$silent" silent
start "$sfail" sfail

probe() { timeout 20 "$T/probe" "$@" 2>"$T/ms"; }
ms() { sed -n 's/^ms //p' "$T/ms" | tail -1; }

# ---- a slow local resolver, with the DEFAULT timeouts -------------------------------------------
# slow.test is answered after three seconds, the way systemd-resolved answers while it
# re-probes its upstream server. The defaults (0 0) must wait for it: with two seconds an
# attempt the reply to the first attempt came to a socket already closed, and the lookup
# reported "no nameserver answered in time".
out=$(probe "$good" 0 0 slow.test)
has "a resolver that takes three seconds is waited for with the default timeouts" "$out" "slow.test 10.3.3.30"

# ---- answers ---------------------------------------------------------------------------------
out=$(probe "$good" 1000 3000 a.test A.Test. chain.test partial.test)
has "two A records"                           "$out" "a.test 10.1.2.3 10.1.2.4"
has "the name is case-insensitive and may end in a dot" "$out" "A.Test. 10.1.2.3 10.1.2.4"
has "a compressed CNAME chain is followed, and the A record off the chain ignored" "$out" "chain.test 10.9.8.7"
has "a chain that stops short is asked for again under its last name" "$out" "partial.test 10.1.2.3 10.1.2.4"
if grep -q "^udp a.test$" "$T/normal.log" && [ "$(count "$T/normal.log" "udp a.test")" = 2 ]; then
  ok "  (and that second question went to the server: a.test asked twice, once for partial.test)"
else bad "partial.test did not make the resolver ask for a.test" "$(cat "$T/normal.log")"; fi

# ---- four failures, four codes ---------------------------------------------------------------
out=$(probe "$good" 1000 3000 nx.test fail.test refused.test empty.test)
has "NXDOMAIN"                 "$out" "nx.test error -1 the name does not exist (NXDOMAIN)"
has "SERVFAIL"                 "$out" "fail.test error -3 the nameserver could not resolve the name (SERVFAIL)"
has "REFUSED"                  "$out" "refused.test error -4 the nameserver refused the query"
has "no answer is NODATA"      "$out" "empty.test error -2 the name exists but has no IPv4 address"
[ "$(count "$T/normal.log" "udp nx.test")" = 1 ] && ok "NXDOMAIN is final: asked once" \
  || bad "NXDOMAIN was retried" "$(grep nx.test "$T/normal.log")"

# ---- records beyond the answer: authority and additional sections ----------------------------
# Each lookup gets a 3 s bound: a reply that is not recognised would show up as a timeout.
out=$(probe "$good" 1000 3000 nxsoa.test nodatasoa.test unknown.test opt.test referral.test)
has "NXDOMAIN with an SOA (compressed RDATA) in the authority section" "$out" "nxsoa.test error -1 the name does not exist (NXDOMAIN)"
has "no answer with an SOA in the authority section is NODATA" "$out" "nodatasoa.test error -2 the name exists but has no IPv4 address"
has "a record of an unknown type is skipped by its RDLENGTH" "$out" "unknown.test 10.6.6.6"
has "an OPT record in the additional section is skipped" "$out" "opt.test 10.4.4.4"
has "NS records and their glue are not answers" "$out" "referral.test 10.3.3.3"
[ "$(count "$T/normal.log" "udp nxsoa.test")" = 1 ] && ok "  (the NXDOMAIN with an SOA was taken at once: asked once)" \
  || bad "nxsoa.test was asked more than once" "$(grep nxsoa.test "$T/normal.log")"

# ---- truncation, forged replies, loops -------------------------------------------------------
out=$(probe "$good" 1000 3000 big.test)
has "a truncated reply is asked again over TCP" "$out" "big.test 10.5.5.5 10.5.5.6 10.5.5.7"
grep -q "^tcp big.test$" "$T/normal.log" && ok "  (the server saw the TCP query)" \
  || bad "no TCP query reached the server" "$(cat "$T/normal.log")"

out=$(probe "$good" 1000 3000 wrongid.test)
has "replies under the wrong id or for the wrong question are ignored" "$out" "wrongid.test 10.7.7.7"

out=$(probe "$good" 1000 3000 loop.test loop2.test cnameloop.test)
has "a compression pointer to itself"         "$out" "loop.test error -7 the nameserver sent a reply that does not parse, or a CNAME chain that loops"
has "a compression pointer back into its own name" "$out" "loop2.test error -7 the nameserver sent a reply that does not parse, or a CNAME chain that loops"
has "a CNAME chain that loops"                "$out" "cnameloop.test error -7 the nameserver sent a reply that does not parse, or a CNAME chain that loops"

# ---- the cache ---------------------------------------------------------------------------------
before=$(count "$T/normal.log" "udp a.test")
out=$(probe "$good" 1000 3000 a.test a.test '!flush' a.test ttl0.test ttl0.test)
after=$(count "$T/normal.log" "udp a.test")
if [ $((after - before)) = 2 ]; then ok "a cached answer reaches no server; after dns.flush it does again"
else bad "the cache did not behave" "a.test queries: $((after - before)), wanted 2"; fi
[ "$(count "$T/normal.log" "udp ttl0.test")" = 2 ] && ok "an answer with TTL 0 is not cached" \
  || bad "TTL 0 was cached" "$(grep ttl0 "$T/normal.log")"

# ---- no server needed ----------------------------------------------------------------------------
out=$(probe "$closed" 200 500 10.20.30.40 localhost 'bad..name' 10.1.2 256.0.0.1)
has "a dotted IPv4 literal is itself" "$out" "10.20.30.40 10.20.30.40"
has "localhost is 127.0.0.1"          "$out" "localhost 127.0.0.1"
has "an empty label is not a hostname" "$out" "bad..name error -6 that is not a valid hostname"
# A resolver that guesses an address from three octets exists (10.1.2 came back as 10.1.0.2
# from one); a last label of digits only is refused before any server is asked.
has "three octets are not a hostname either" "$out" "10.1.2 error -6 that is not a valid hostname"
has "nor is an octet above 255"                "$out" "256.0.0.1 error -6 that is not a valid hostname"
[ "$(ms)" -lt 100 ] 2>/dev/null && ok "  (none of them waited for a server)" || bad "a lookup without a server took $(ms) ms"

# ---- more than one server ---------------------------------------------------------------------
out=$(probe "$silent,$good" 300 3000 a.test)
t=$(ms)
has "a silent server: the next one answers" "$out" "a.test 10.1.2.3 10.1.2.4"
if [ "$t" -ge 250 ] && [ "$t" -lt 2000 ]; then ok "  (after one attempt's timeout: $t ms for a 300 ms attempt)"
else bad "the move to the next server took $t ms, for a 300 ms attempt"; fi
grep -q "^udp a.test$" "$T/silent.log" && ok "  (the silent server was asked first)" || bad "the silent server was never asked"

out=$(probe "$closed,$good" 1000 3000 a.test)
t=$(ms)
has "a port where nothing listens: the next server answers" "$out" "a.test 10.1.2.3 10.1.2.4"
[ "$t" -lt 250 ] && ok "  (without waiting out the timeout: $t ms)" || bad "a closed port cost $t ms"

out=$(probe "$sfail,$good" 1000 3000 a.test)
has "SERVFAIL from one server: the next one answers" "$out" "a.test 10.1.2.3 10.1.2.4"

out=$(probe "$silent" 200 700 a.test)
t=$(ms)
has "no server answers: a timeout" "$out" "a.test error -5 no nameserver answered in time"
[ "$t" -lt 1500 ] && ok "  (within the bound: $t ms for a 700 ms lookup)" || bad "the timeout took $t ms, for a 700 ms lookup"

out=$(probe "$sfail,$silent" 200 1500 a.test)
has "SERVFAIL and silence: the SERVFAIL is what is reported" "$out" "a.test error -3 the nameserver could not resolve the name (SERVFAIL)"

# ---- several at once, from an epoll loop ------------------------------------------------------
out=$(probe "$silent,$good" 300 3000 '!async' a.test chain.test big.test nx.test wrongid.test)
has "at once: a.test"       "$out" "a.test 10.1.2.3 10.1.2.4"
has "at once: chain.test"   "$out" "chain.test 10.9.8.7"
has "at once: big.test"     "$out" "big.test 10.5.5.5 10.5.5.6 10.5.5.7"
has "at once: nx.test"      "$out" "nx.test error -1 the name does not exist (NXDOMAIN)"
has "at once: wrongid.test" "$out" "wrongid.test 10.7.7.7"

# ---- resolv.conf ------------------------------------------------------------------------------
cat > "$T/resolv.conf" <<'EOF'
# a comment
; another comment
search example.internal
nameserver 10.0.0.1
nameserver ::1
  nameserver	10.0.0.2   # the rest of the line is a comment
nameserver 10.0.0.3
nameserver 10.0.0.4
options ndots:1 timeout:3 attempts:4
EOF
out=$(probe - 0 0 "!conf=$T/resolv.conf")
has "resolv.conf: three IPv4 nameservers, the IPv6 one skipped, options read" "$out" \
  "conf 3 10.0.0.1:53 10.0.0.2:53 10.0.0.3:53 timeout 3000 attempts 4"
out=$(probe - 0 0 "!conf=$T/nonexistent")
has "a missing resolv.conf is an error, not an empty list" "$out" "conf -2 timeout 0 attempts 0"

# ---- examples/host.wz, the resolver as a tool ---------------------------------------------------
compile "$ROOT/examples/host.wz" "$T/host"
out=$(timeout 20 "$T/host" chain.test "@127.0.0.1:$good" 2>&1); rc=$?
has "examples/host.wz prints the address"   "$out" "chain.test has address 10.9.8.7"
[ $rc = 0 ] && ok "  (and exits 0)" || bad "host exited $rc on success"
out=$(timeout 20 "$T/host" nx.test "@127.0.0.1:$good" 2>&1); rc=$?
has "examples/host.wz says why a name did not resolve" "$out" "host: nx.test: the name does not exist (NXDOMAIN)"
[ $rc = 1 ] && ok "  (and exits 1)" || bad "host exited $rc on NXDOMAIN"

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
