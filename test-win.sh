#!/bin/sh
# test-win.sh -- verify the Windows backend of the Wantzel compiler.
#
# Compiling to a name ending in .exe produces a 64-bit PE that talks to
# kernel32 instead of the Linux kernel.  This script compiles a handful of
# examples both ways and checks that the .exe, run under Wine, prints exactly
# what the Linux ELF prints.  It also checks that the C bootstrap and the
# Wantzel compiler emit byte-identical .exe files, and that the compiler
# compiles itself to a working .exe.
#
# Needs wine64 (apt install wine64).  Skips gracefully if it is absent.
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)

# CLEAN UP WITHOUT FAILING THE TEST.
#
# The WINEPREFIX lives in $T, and wineserver stays alive for seconds after the last call
# with files in that prefix open -- the httpd case below even starts a server under Wine.
# A bare 'rm -rf "$T"' then reported
#
#     rm: cannot remove '/tmp/tmp.XXXX/wp': Directory not empty
#
# and because this script runs under 'set -e' that one failed rm turned the WHOLE run
# red, right after '18 passed, 0 failed'.  A test that reports its own success and then
# trips over its cleanup is the kind of failure nobody reads correctly.
#
# So: shut wineserver down first and wait for it, and the rm afterwards must never decide
# the outcome -- that is already fixed in $fail.
cleanup_win() {
  if [ -n "$WINEPREFIX" ] && [ -d "$WINEPREFIX" ]; then
    # ONLY OUR OWN wineserver.  'wineserver -k' knows exactly one prefix -- the one in
    # the environment -- and WINEPREFIX still points at $T/wp here, so this never touches
    # the Wine of another worktree or a parallel suite.  That distinction is not
    # theoretical: a broad kill across every wineserver is the mistake this repository
    # already made once with a too-wide pgrep.
    "${WINESERVER:-wineserver}" -k 2>/dev/null || true
    _n=0
    while [ $_n -lt 50 ]; do
      # wait for OUR prefix: as long as a process holds a file in $WINEPREFIX open,
      # the rm below fails.
      pgrep -f "wineserver.*$WINEPREFIX" >/dev/null 2>&1 || break
      _n=$((_n + 1)); sleep 0.1
    done
  fi
  rm -rf "$T" 2>/dev/null || true
}
trap cleanup_win EXIT
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

WINE=$(command -v wine64 || command -v wine || echo /usr/lib/wine/wine64)
if [ ! -x "$WINE" ]; then echo "wine not found; install wine64 to run this suite" >&2; exit 0; fi
export WINEPREFIX="$T/wp" WINEDEBUG=-all
W() { "$WINE" "$@" 2>/dev/null; }

[ -x ./bin/wantzel0 ] && [ -x ./bin/wantzel ] || { echo "run ./build.sh first" >&2; exit 1; }

echo "a .exe target produces a PE32+ executable"
./bin/wantzel examples/hello.wz "$T/hello.exe"
case "$(od -An -tx1 -N2 "$T/hello.exe" | tr -d ' ')" in
  4d5a) ok "PE starts with MZ" ;; *) bad "not an MZ image" ;;
esac

echo "wantzel0 and wantzel emit identical .exe (the C bootstrap and Wantzel agree)"
for f in examples/hello.wz examples/cat.wz examples/primes.wz tests/compiler/feat.wz src/wantzel.wz; do
    ./bin/wantzel0 "$f" "$T/a.exe" 2>/dev/null && ./bin/wantzel "$f" "$T/b.exe" 2>/dev/null
    if cmp -s "$T/a.exe" "$T/b.exe"; then ok "identical .exe for $f"; else bad "differing .exe for $f"; fi
done

echo "the .exe prints what the ELF prints, under Wine"
same_out() { # name  src  args...
    n=$1; s=$2; shift 2
    ./bin/wantzel "$s" "$T/$n.elf" 2>/dev/null
    ./bin/wantzel "$s" "$T/$n.exe" 2>/dev/null
    le=$("$T/$n.elf" "$@"); we=$(W "$T/$n.exe" "$@")
    if [ "$le" = "$we" ]; then ok "$n matches"; else bad "$n differs"; fi
}
same_out hello  examples/hello.wz
same_out primes examples/primes.wz
same_out feat   tests/compiler/feat.wz XYZ
# cat: stdin path (ReadFile on the console handle)
./bin/wantzel examples/cat.wz "$T/cat.exe" 2>/dev/null
le=$(printf 'piped\n' | "$T/cat.elf" 2>/dev/null || printf 'piped\n')
we=$(printf 'piped\n' | W "$T/cat.exe")
[ "$we" = "piped" ] && ok "cat reads stdin" || bad "cat stdin: got '$we'"
# cat: a named file (CreateFileA + ReadFile)
we=$(W "$T/cat.exe" examples/hello.wz | head -1)
[ "$we" = "// hello.wz -- the smallest useful Wantzel program" ] && ok "cat reads a file" || bad "cat file: got '$we'"

echo "wantzel.exe compiles Wantzel source, under Wine (self-hosting on Windows)"
ABS="$(pwd)/examples/hello.wz"
./bin/wantzel src/wantzel.wz "$T/wantzel.exe" 2>/dev/null
W "$T/wantzel.exe" "$ABS" "$T/h_from_win.elf"
./bin/wantzel "$ABS" "$T/h_from_linux.elf" 2>/dev/null
if cmp -s "$T/h_from_win.elf" "$T/h_from_linux.elf"; then ok "wantzel.exe emits the same ELF as the native compiler"; else bad "wantzel.exe ELF differs"; fi
# and the ELF it made actually runs
chmod +x "$T/h_from_win.elf"; [ "$("$T/h_from_win.elf")" = "hello, world" ] && ok "that ELF runs" || bad "that ELF does not run"

echo "the MCP file server answers over stdin, as a .exe (stat, getdents, ReadFile, scan)"
mkdir -p "$T/proj/sub"
printf 'hello content\n' > "$T/proj/readme.txt"
printf 'x\n' > "$T/proj/sub/inner.txt"
./bin/wantzel examples/mcpfiles.wz "$T/mcpfiles.exe" 2>/dev/null
out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_dir","arguments":{"path":"."}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"readme.txt"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search","arguments":{"query":"content"}}}' \
  | W "$T/mcpfiles.exe" "$T/proj")
echo "$out" | grep -q '"protocolVersion"' && ok "mcpfiles.exe handshakes" || bad "mcpfiles.exe handshake"
echo "$out" | grep -q 'dir    sub' && ok "mcpfiles.exe lists a directory" || bad "mcpfiles.exe list_dir"
echo "$out" | grep -q 'hello content' && ok "mcpfiles.exe reads a file" || bad "mcpfiles.exe read_file"
echo "$out" | grep -q 'readme.txt:1:' && ok "mcpfiles.exe searches the tree" || bad "mcpfiles.exe search"

echo "the HTTP server binds a socket and answers, as a .exe (socket, epoll over WSAPoll)"
if command -v curl >/dev/null 2>&1; then
    port=8099
    # compile inside examples/ so the "../lib/http.wz" include resolves
    sed "s/http.serve(8080, 8)/http.serve($port, 8)/" examples/httpd.wz > examples/_httpd_test.wz
    ./bin/wantzel examples/_httpd_test.wz "$T/httpd.exe" 2>/dev/null
    rm -f examples/_httpd_test.wz
    W "$T/httpd.exe" >/dev/null 2>&1 &
    hp=$!
    sleep 6
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/probe" 2>/dev/null)
    kill "$hp" 2>/dev/null
    echo "$body" | grep -q 'hello from wantzel' && ok "httpd.exe answers a request" || bad "httpd.exe request"
else
    echo "  skip  httpd.exe (curl not installed)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
