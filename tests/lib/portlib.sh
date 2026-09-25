# portlib.sh -- pick TCP ports for tests/lib/*.sh that survive many `./wztest` runs at once.
#
# THE OLD WAY, AND WHY IT COLLIDES. Every script in this directory used to compute its own
# port as `BASE + ($$ % RANGE)`, sometimes with a few more ports at fixed offsets above it.
# That guesses at a range nothing else has agreed to stay out of: under ten or more parallel
# `./wztest` runs, two scripts can land on the same number even with different $$ values (two
# different bases and ranges can overlap), or the number they land on is already an ephemeral
# SOURCE port some unrelated connection on the machine is using -- the kernel hands those out
# from 32768-60999, right where most of these ranges sat. That is exactly the class of
# failure seen under parallel runs ("cannot bind the port", "Connection
# refused", "no address accepted the connection") in tls.sh, tls_serve.sh, wget.sh,
# http_https.sh, http_https_acme.sh, http_large.sh -- one different test per run, always
# passing alone.
#
# THE FIX: ASK THE KERNEL. tests/helpers/freeport.wz binds port 0 -- "any free port" -- reads
# the real number back with getsockname, and closes again. The number was free at that
# instant, on this machine; a fixed or $$-derived guess can never promise that. There is
# still a lease-and-release gap between freeport.wz closing the socket and the caller's own
# bind, exactly as with any other "ask, then use" resource, which is why start_server below
# still retries on a failed bind instead of treating it as fatal -- but the window is a
# syscall wide, not a 900-number range shared with everyone else on the machine.
#
# Usage, from a tests/lib/*.sh script:
#   . "$ROOT/tests/lib/portlib.sh"        # or "$here/tests/lib/portlib.sh"
#   port=$(free_port)                     # one port
#   set -- $(free_ports 3); p443=$1; p80=$2; paux=$3    # several at once
#   wait_port "$port" || { echo "  FAIL  server did not start"; exit 1; }
#
# Needs the repo root: either `$here` (the scripts that compute it themselves from
# "$0") or `$ROOT` (set by wztest for scripts that source tests/helpers.sh). Either
# one is fine; a script that sourced tests/helpers.sh already has $ROOT and $WANTZEL.
_portlib_root="${here:-${ROOT:?portlib.sh: neither \$here nor \$ROOT is set}}"
_portlib_wantzel="${WANTZEL:-$_portlib_root/bin/wantzel}"
_portlib_bin="$_portlib_root/tests/helpers/.freeport-bin"

_portlib_build() {
  # Built once per worktree, not once per test: a fresh checkout has no ./bin/wantzel.new
  # race with a concurrent build because the compiler writes to a temp file and renames
  # (see build.sh) -- but we still avoid recompiling on every single test run.
  if [ ! -x "$_portlib_bin" ] || [ "$_portlib_root/tests/helpers/freeport.wz" -nt "$_portlib_bin" ]; then
    "$_portlib_wantzel" "$_portlib_root/tests/helpers/freeport.wz" "$_portlib_bin.new.$$" 2>&1 \
      || { echo "portlib.sh: freeport.wz does not compile" >&2; exit 1; }
    mv -f "$_portlib_bin.new.$$" "$_portlib_bin"
  fi
}

# free_port -- print one free TCP port
free_port() { _portlib_build; "$_portlib_bin" 1; }

# free_ports <n> -- print <n> free TCP ports, one per line; always distinct from each other
# (the kernel never hands the same fd's port back twice while sockets from this same run
# are still held), so callers needing several related ports (a CA and a front end, a plain
# and a TLS port) should call this once rather than adding fixed offsets to one port.
free_ports() { _portlib_build; "$_portlib_bin" "$1"; }

# wait_port <port> [<tries>] -- poll until something listens on 127.0.0.1:<port>, 100ms per
# try, <tries> defaults to 50 (5s). Prints nothing on success. On failure the CALLER decides
# what to do (usually: print the log and exit 1) -- this only tells you whether to give up,
# port_owner below says who is in the way.
wait_port() {
  p="$1"; tries="${2:-50}"; i=0
  while [ "$i" -lt "$tries" ]; do
    ss -tln 2>/dev/null | grep -q ":$p " && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# port_owner <port> -- one line naming who (if anyone) holds <port> right now, for a FAIL
# message. Answers "nothing is listening on <port>" rather than leaving the reader to guess
# whether the server never started or something else got there first.
port_owner() {
  owner=$(ss -ltnp 2>/dev/null | grep ":$1 ")
  if [ -n "$owner" ]; then printf 'port %s is held by: %s\n' "$1" "$owner"
  else printf 'nothing is listening on port %s\n' "$1"; fi
}
