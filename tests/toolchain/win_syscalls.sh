# The system calls behave the same in a Windows executable (under Wine) as in the ELF:
# storage, epoll sets, and the process and network calls a server needs at startup.
. "$ROOT/tests/helpers.sh"
[ -x "${WINE:-/usr/lib/wine/wine64}" ] || command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || { echo "wine is missing"; exit 1; }
compile_win "$ROOT/tests/compiler/syscalls_storage.wz" "$T/sc.exe"
got=$(cd "$T" && run_win "$T/sc.exe" 2>/dev/null)
want=$(cat "$ROOT/tests/compiler/syscalls_storage.out")
assert_eq "windows storage syscalls" "$got" "$want"

# EPOLL SETS ARE INDEPENDENT. The Windows runtime emulates epoll over WSAPoll, and it once
# kept a single interest table for the whole process: every epoll_create returned the same
# handle, so an fd added to one set was reported by all of them, and a DEL on one set
# removed it from the other. A program with two event loops -- an HTTP server and a
# WebSocket poller -- then lost connections on Windows only. epollsets.wz makes three sets,
# nests one in another, and names what each wait reports; the ELF is the reference.
compile "$ROOT/tests/helpers/epollsets.wz" "$T/eps"
compile_win "$ROOT/tests/helpers/epollsets.wz" "$T/eps.exe"
compile "$ROOT/tests/helpers/epollcli.wz" "$T/epcli"

# epsrun <out> <server...>: start the server on two ports, connect the client once the
# server listens (the first Wine start of a prefix takes seconds), wait for the server
epsrun() {
  _out=$1; shift
  _pa=$(( 20000 + $$ % 20000 )); _pb=$((_pa + 1))
  # no timeout here: run_win is a function; the server gives up by itself after 60 s
  "$@" "$_pa" "$_pb" x > "$_out" 2>&1 &
  _sp=$!
  _n=0
  until timeout 60 "$T/epcli" "$_pa" "$_pb"; do
    _n=$((_n + 1)); [ $_n -lt 100 ] || break; sleep 0.3
  done
  wait $_sp
}
epsrun "$T/eps.lin" "$T/eps"
epsrun "$T/eps.win" run_win "$T/eps.exe"

want='two sets
A into e1: 0
B into e2: 0
e1: A
e2: B
A out of e1: 0
e1: nothing
e2: B
A into e1 again: 0
e1: A
e2 into e3: 0
e3: e2
e3 into e2, a loop: -40
e2 into itself: -22
B out of e2: 0
e3: nothing
B into e2 again: 0
e3: e2
e3 after closing e2: nothing
e1: A'
# the last line is how many sets fit: the kernel's limit is the fd limit, far beyond 64
assert_eq "epoll sets in the ELF" "$(sed '$d' "$T/eps.lin")" "$want"
assert_eq "epoll sets in the .exe (the ELF is the reference)" "$(sed '$d' "$T/eps.win")" "$want"
# the runtime has a fixed number of sets, and one more is EMFILE rather than a crash
assert_eq "one epoll set too many in the .exe" "$(tail -n 1 "$T/eps.win")" "the set that did not fit: -24"

# ---- process and network calls: getpid, kill, connect, nanosleep --------------------
# A number the runtime does not know stops the program with "an unsupported system call
# was made on Windows". getpid, kill and connect were missing, so a server that writes its
# pid to a lock file at startup could not start on Windows at all -- it compiled, and
# stopped on its first line. And nanosleep slept 1 ms whatever it was asked.

# ---- one process: pid, alive, connect, sleep -- the ELF is the reference ----------
compile "$ROOT/tests/helpers/procnet.wz" "$T/pn"
compile_win "$ROOT/tests/helpers/procnet.wz" "$T/pn.exe"
port=$(( 21000 + $$ % 20000 ))
want='own pid: positive
alive(own pid): yes
alive(999999): no
kill(999999, 15): -3
connect to a listening port: ok
accept: ok
connect to a closed port: -111
nanosleep 300 ms: slept at least 290 ms'
assert_eq "process and network calls in the ELF" "$("$T/pn" "$port")" "$want"
got=$(cd "$T" && run_win "$T/pn.exe" "$((port + 2))" 2>&1 | tr -d '\r')
assert_eq "process and network calls in the .exe (the ELF is the reference)" "$got" "$want"

# ---- two processes: one stops the other --------------------------------------------
# stopkill <sleeper...> -- <stopper...>: start the sleeper, read its pid, let the stopper
# end it, and print what both said.
compile "$ROOT/tests/helpers/sleeper.wz" "$T/sl"
compile "$ROOT/tests/helpers/stopper.wz" "$T/st"
compile_win "$ROOT/tests/helpers/sleeper.wz" "$T/sl.exe"
compile_win "$ROOT/tests/helpers/stopper.wz" "$T/st.exe"
stopkill() {
  _out=$1; _slp=$2; _stp=$3
  : > "$_out.sleeper"
  $_slp > "$_out.sleeper" 2>&1 &
  _bg=$!
  _n=0
  until [ -s "$_out.sleeper" ]; do _n=$((_n + 1)); [ $_n -lt 200 ] || break; sleep 0.1; done
  _pid=$(head -1 "$_out.sleeper" | tr -d '\r')
  $_stp "$_pid" 2>&1 | tr -d '\r' > "$_out"
  wait $_bg 2>/dev/null
  tail -n +2 "$_out.sleeper" | tr -d '\r' >> "$_out"
}
want='before: alive
kill: 0
after: gone'
stopkill "$T/sk.lin" "$T/sl" "$T/st"
assert_eq "kill between two processes in the ELF" "$(cat "$T/sk.lin")" "$want"
stopkill "$T/sk.win" "run_win $T/sl.exe" "run_win $T/st.exe"
assert_eq "kill between two processes in the .exe (the sleeper never wakes)" "$(cat "$T/sk.win")" "$want"
