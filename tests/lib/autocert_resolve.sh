# lib/autocert.wz finds the authority through DNS (lib/dns.wz), with autocert.pin still
# winning over it: asked of a fake nameserver on 127.0.0.1, never the machine's own.
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

port=$(free_port)
compile "$ROOT/tests/helpers/dnsfake.wz" "$T/dnsfake"
compile "$ROOT/tests/lib/progs/resolveprobe.wz" "$T/probe"

"$T/dnsfake" "$port" normal >"$T/dns.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null' EXIT
trap 'exit 143' TERM INT
n=0
while [ $n -lt 50 ]; do grep -q '^ready$' "$T/dns.log" 2>/dev/null && break; n=$((n + 1)); sleep 0.1; done

out=$(timeout 20 "$T/probe" "$port" 2>&1)
assert_contains "a pinned name is not asked of DNS" "$out" "a.test 10.20.30.40"
assert_contains "a name is resolved through DNS, CNAMEs followed" "$out" "chain.test 10.9.8.7"
assert_contains "a name that does not exist says so" "$out" "nx.test FAIL cannot resolve the authority's name: the name does not exist"
assert_contains "a literal address needs no lookup" "$out" "192.0.2.7 192.0.2.7"
assert_contains "and neither does localhost" "$out" "localhost 127.0.0.1"
[ "$(grep -c '^udp a.test' "$T/dns.log")" = 0 ] || { echo "the pinned name was asked of DNS anyway"; exit 1; }
