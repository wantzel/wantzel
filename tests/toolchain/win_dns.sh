# lib/dns.wz in a .exe: the resolver on Windows, under Wine. Behind --windows.
#
# WHY THIS HAS TO RUN THE PROGRAM. Four things the resolver needs from the Windows runtime
# are invisible in the bytes of the executable:
#   - socket(AF_INET, SOCK_DGRAM) must give a UDP socket, where it used to give TCP always
#   - a non-blocking connect must report EINPROGRESS, not "refused" (the TCP fallback)
#   - an open of /etc/resolv.conf must be answered from GetNetworkParams, the one call
#     that knows which DNS servers Windows uses -- and a named import is only proven by
#     calling it
#   - the resolver's epoll set nested in the program's own, over WSAPoll
# The nameserver is the fixture tests/lib/dns.sh uses, run natively on 127.0.0.1; the
# client is the same probe, built for Windows. Nothing from the internet is asked.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

WINE=$(command -v wine64 || command -v wine || echo /usr/lib/wine/wine64)
[ -x "$WINE" ] || { echo "wine is missing; install wine64 for the --windows tests"; exit 1; }
export WINEPREFIX="$T/wp" WINEDEBUG=-all WINEDLLOVERRIDES=winedbg.exe=d

# the own-prefix cleanup of win_recv_reset.sh: the prefix is in the environment, not on
# the command line, so /proc/<pid>/environ is what identifies our processes
mine() {
  {
    for _d in /proc/[0-9]*; do
      case "$(cat "$_d/comm")" in
        wine*|*.exe) ;;
        *) continue ;;
      esac
      if tr '\0' '\n' < "$_d/environ" | grep -qxF "WINEPREFIX=$WINEPREFIX"; then
        echo "${_d#/proc/}"
      fi
    done
  } 2>/dev/null
}
pids=""
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  "${WINESERVER:-wineserver}" -k 2>/dev/null || true
  _n=0
  while [ $_n -lt 50 ] && [ -n "$(mine)" ]; do _n=$((_n + 1)); sleep 0.1; done
  for _p in $(mine); do kill -9 "$_p" 2>/dev/null || true; done
  _n=0
  while [ $_n -lt 20 ] && [ -n "$(mine)" ]; do _n=$((_n + 1)); sleep 0.1; done
}
trap cleanup EXIT

base=$(( 23000 + ($$ % 2500) * 2 ))
good=$base; silent=$((base + 1))
compile "$ROOT/tests/helpers/dnsfake.wz" "$T/dnsfake"
compile_win "$ROOT/tests/helpers/dnsprobe.wz" "$T/probe.exe"
for m in "$good normal" "$silent silent"; do
  set -- $m
  "$T/dnsfake" "$1" "$2" >"$T/$2.log" 2>&1 &
  pids="$pids $!"
done
_n=0
until grep -q '^ready$' "$T/normal.log" 2>/dev/null && grep -q '^ready$' "$T/silent.log" 2>/dev/null; do
  _n=$((_n + 1)); [ $_n -lt 50 ] || { echo "the fixture servers did not start"; cat "$T"/*.log; exit 1; }
  sleep 0.1
done

fail=0
has() { printf '%s\n' "$2" | grep -qxF -- "$3" && echo "  ok    $1" || { echo "  FAIL  $1"; echo "        wanted: $3"; echo "        got:"; printf '%s\n' "$2" | sed 's/^/          /'; fail=1; }; }

# ---- lookups: UDP, TCP, a forged reply ignored, a silent server skipped, and at once ----
# The first run of a fresh prefix builds it, which is most of this test's time.
out=$(timeout 60 "$WINE" "$T/probe.exe" "$silent,$good" 300 3000 a.test big.test wrongid.test nx.test \
      '!async' chain.test partial.test 2>/dev/null | tr -d '\r')
has "UDP: two A records, after a silent first server"     "$out" "a.test 10.1.2.3 10.1.2.4"
has "TCP after a truncated reply (a non-blocking connect)" "$out" "big.test 10.5.5.5 10.5.5.6 10.5.5.7"
has "a reply under the wrong id is ignored"                "$out" "wrongid.test 10.7.7.7"
has "NXDOMAIN"                                             "$out" "nx.test error -1 the name does not exist (NXDOMAIN)"
has "at once, from an epoll loop: a CNAME chain"           "$out" "chain.test 10.9.8.7"
has "at once: a chain asked for again"                     "$out" "partial.test 10.1.2.3 10.1.2.4"
grep -q '^tcp big.test$' "$T/normal.log" && echo "  ok      (the TCP query reached the server)" \
  || { echo "  FAIL  no TCP query reached the server"; fail=1; }

# ---- /etc/resolv.conf, from GetNetworkParams -----------------------------------------------
# Wine answers GetNetworkParams from the host's own resolver configuration, so the first
# IPv4 nameserver in the host's /etc/resolv.conf is what the .exe must find.
#
# THE FILE MUST COME FROM THE RUNTIME, and that needs its own check: Wine reads a path
# that starts with '/' as a HOST path, so "/etc/resolv.conf" opens the host's real file
# whether or not the runtime intercepts it -- measured: with the interception switched off
# the parse below stayed green. The synthesised file opens with a comment line of its own,
# and that line is what proves the runtime answered.
first=$(timeout 60 "$WINE" "$T/probe.exe" - 0 0 '!cat=/etc/resolv.conf' 2>/dev/null | tr -d '\r' | head -1)
if [ "$first" = "# the DNS servers Windows uses, from GetNetworkParams" ]; then
  echo "  ok    /etc/resolv.conf in a .exe is the runtime's, from GetNetworkParams"
else
  echo "  FAIL  /etc/resolv.conf in a .exe was not synthesised by the runtime; its first line: $first"; fail=1
fi
out=$(timeout 60 "$WINE" "$T/probe.exe" - 0 0 '!conf=/etc/resolv.conf' 2>/dev/null | tr -d '\r')
case "$out" in
  "conf -"*) echo "  FAIL  the .exe could not open /etc/resolv.conf: $out"; fail=1 ;;
  "conf "*)  echo "  ok    /etc/resolv.conf opens in a .exe: $out" ;;
  *)         echo "  FAIL  no answer from the resolv.conf probe: $out"; fail=1 ;;
esac
host=$(sed -n 's/^[ \t]*nameserver[ \t]*\([0-9][0-9.]*\)[ \t]*$/\1/p' /etc/resolv.conf 2>/dev/null | head -1)
if [ -n "$host" ]; then
  case "$out" in
    "conf "[1-9]*" $host:53 "*) echo "  ok    and it names the host's nameserver, $host" ;;
    *) echo "  FAIL  the host's nameserver is $host, the .exe found: $out"; fail=1 ;;
  esac
else
  echo "  note  the host's /etc/resolv.conf names no IPv4 nameserver; only the open was checked"
fi

exit $fail
