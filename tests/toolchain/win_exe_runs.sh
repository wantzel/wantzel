# Running a .exe under Wine: the emulator part of the Windows backend.  Behind --windows,
# because it is the slowest thing in the suite and it starts processes that outlive it.
#
# The byte-level checks do NOT live here -- they need no emulator and run in every
# --toolchain run (tests/toolchain/win_backend_bytes.sh).  What is left is the question an
# emulator is actually needed for: does the .exe we produce DO what the ELF does.
#
# CLEANING UP IS PART OF THE TEST.  Measured 15-09-2026: after an evening of
# runs, 29 wine processes were still alive -- wineserver64 and winedevice.exe, the oldest
# nearly an hour old. Killing wineserver is not enough: winedevice.exe belongs to the
# server but does not die with it. So this test shuts its own prefix down, waits for it,
# kills what is left of ITS OWN prefix, and then FAILS if anything of its own survives.
# A leak that nobody reports is how 29 of them got there.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

WINE=$(command -v wine64 || command -v wine || echo /usr/lib/wine/wine64)
[ -x "$WINE" ] || { echo "wine is missing; install wine64 for the --windows tests"; exit 1; }

export WINEPREFIX="$T/wp" WINEDEBUG=-all
W() { "$WINE" "$@" 2>/dev/null; }

# Only ever OUR OWN prefix. A broad kill across every wineserver is a mistake this
# repository already made once, and it takes down a parallel suite or another worktree.
#
# HOW TO RECOGNISE OUR OWN, and this is why the cleanup never worked before: the prefix is
# NOT in the command line. A wineserver shows as '/usr/lib/wine/wineserver64 -p0' and a
# winedevice.exe as 'C:\windows\system32\winedevice.exe' whatever prefix it serves, so
# `pgrep -f "$WINEPREFIX"` matched nothing and the wait loop fell straight through.
# The prefix lives in the ENVIRONMENT, so /proc/<pid>/environ is what identifies it
# (measured 15-09-2026).
# A process of another user is unreadable and [ -r ] does not predict that, so the read
# itself is silenced; a process we cannot read is by definition not ours.
# The test itself EXPORTS WINEPREFIX, so this loop and its own subshell carry it too and
# would count themselves as leaked wine. Only a process whose executable is actually a
# wine one counts.
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
cleanup_win() {
  "${WINESERVER:-wineserver}" -k 2>/dev/null || true
  _n=0
  while [ $_n -lt 50 ] && [ -n "$(mine)" ]; do _n=$((_n + 1)); sleep 0.1; done
  # winedevice.exe and friends do not die with the server: kill what is still ours
  for _p in $(mine); do kill -9 "$_p" 2>/dev/null || true; done
  _n=0
  while [ $_n -lt 20 ] && [ -n "$(mine)" ]; do _n=$((_n + 1)); sleep 0.1; done
}
trap cleanup_win EXIT

fail=0
bad() { echo "  FAIL  $1"; fail=1; }

# the .exe prints what the ELF prints
same_out() { # name  src  args...
    n=$1; s=$2; shift 2
    compile "$s" "$T/$n.elf"
    compile_win "$s" "$T/$n.exe"
    le=$("$T/$n.elf" "$@"); we=$(W "$T/$n.exe" "$@")
    [ "$le" = "$we" ] || bad "$n: the .exe prints '$we', the ELF prints '$le'"
}
same_out hello  "$ROOT/examples/hello.wz"
same_out primes "$ROOT/examples/primes.wz"
same_out feat   "$ROOT/tests/compiler/feat.wz" XYZ

# stdin (ReadFile on the console handle) and a named file (CreateFileA + ReadFile)
compile_win "$ROOT/examples/cat.wz" "$T/cat.exe"
we=$(printf 'piped\n' | W "$T/cat.exe")
[ "$we" = "piped" ] || bad "cat.exe does not read stdin: got '$we'"
we=$(W "$T/cat.exe" "$ROOT/examples/hello.wz" | head -1)
[ "$we" = "// hello.wz -- the smallest useful Wantzel program" ] || bad "cat.exe does not read a file: got '$we'"

# self-hosting on Windows: the .exe compiler emits the same ELF as the native one
compile_win "$ROOT/src/wantzel.wz" "$T/wantzel.exe"
W "$T/wantzel.exe" "$ROOT/examples/hello.wz" "$T/h_from_win.elf"
compile "$ROOT/examples/hello.wz" "$T/h_from_linux.elf"
cmp -s "$T/h_from_win.elf" "$T/h_from_linux.elf" || bad "wantzel.exe emits a different ELF than the native compiler"
chmod +x "$T/h_from_win.elf"
[ "$("$T/h_from_win.elf" 2>/dev/null)" = "hello, world" ] || bad "the ELF made by wantzel.exe does not run"

# an MCP server over stdin, as a .exe (stat, getdents, ReadFile, scan)
mkdir -p "$T/proj/sub"
printf 'hello content\n' > "$T/proj/readme.txt"
printf 'x\n' > "$T/proj/sub/inner.txt"
compile_win "$ROOT/examples/mcpfiles.wz" "$T/mcpfiles.exe"
out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_dir","arguments":{"path":"."}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"readme.txt"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search","arguments":{"query":"content"}}}' \
  | W "$T/mcpfiles.exe" "$T/proj")
echo "$out" | grep -q '"protocolVersion"' || bad "mcpfiles.exe does not handshake"
echo "$out" | grep -q 'dir    sub'         || bad "mcpfiles.exe does not list a directory"
echo "$out" | grep -q 'hello content'      || bad "mcpfiles.exe does not read a file"
echo "$out" | grep -q 'readme.txt:1:'      || bad "mcpfiles.exe does not search the tree"

# THE LEAK CHECK. Clean up now, while the test can still report it, instead of leaving it
# to the EXIT trap where nobody sees the outcome.
cleanup_win
left=$(mine | wc -l)
if [ "$left" -ne 0 ]; then
  echo "  FAIL  $left wine process(es) of this run survived the cleanup:"
  # shellcheck disable=SC2009
  ps -o pid=,comm= -p $(mine | tr '\n' ' ') 2>/dev/null || true
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "the .exe matches the ELF, compiles itself and serves MCP under Wine; no process left behind"
