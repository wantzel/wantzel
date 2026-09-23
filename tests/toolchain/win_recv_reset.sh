# A peer that resets or closes a keep-alive connection must not kill an HTTP server on
# Windows. Behind --windows: it runs an .exe under Wine.
#
# The runtime's Winsock recv path took SOCKET_ERROR -- a 32-bit -1, which the register does
# not sign-extend -- for 4294967295 bytes received, and lib/http.wz then died in http.parse
# with "scan() range lies outside the array". A browser or curl closing an idle keep-alive
# connection was enough. So: a server built from lib/http.wz for Windows, a Linux client
# that talks to it, closes normally once and with SO_LINGER(0) once (a reset), and after
# each the server must still answer and must not have printed a runtime error.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

WINE=$(command -v wine64 || command -v wine || echo /usr/lib/wine/wine64)
[ -x "$WINE" ] || { echo "wine is missing; install wine64 for the --windows tests"; exit 1; }
export WINEPREFIX="$T/wp" WINEDEBUG=-all WINEDLLOVERRIDES=winedbg.exe=d

# the same own-prefix cleanup as win_exe_runs.sh: the prefix is in the environment, not
# on the command line, so /proc/<pid>/environ is what identifies our processes
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
  for _p in $(mine); do kill -9 "$_p" 2>/dev/null || true; done
  _n=0
  while [ $_n -lt 20 ] && [ -n "$(mine)" ]; do _n=$((_n + 1)); sleep 0.1; done
}
trap cleanup_win EXIT

port=$(( 20000 + $$ % 20000 ))

# the server: the smallest program on lib/http.wz, one worker (no fork on Windows)
cat > "$T/srv.wz" <<EOF
include "http.wz";
procedure app.request;
begin
  http.add("ok\\n");
  http.finish(200, "text/plain");
end;
begin
  http.serve($port, 1);
end.
EOF
compile_win "$T/srv.wz" "$T/srv.exe"

# the client, on Linux: <port> <mode>. It sends one request, reads the reply and closes;
# mode r closes with SO_LINGER(0), which sends a reset instead of a FIN. Exit 0 when the
# reply carried a 200.
cat > "$T/cli.wz" <<'EOF'
include "net.wz";
var
  buf: array[0..4095] of char;
  lng: array[0..7] of char;
  fd, i, n, port, got: int;
  ok: bool;
begin
  port := 0;
  i := 0;
  while argch(1, i) <> chr(0) do
  begin
    port := port * 10 + (ord(argch(1, i)) - 48);
    i := i + 1;
  end;
  fd := net.connect(127, 0, 0, 1, port);
  if fd < 0 then halt(2);
  n := io.push(buf, 0, "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
  if net.send(fd, addr(buf[0]), n) <> n then halt(3);
  got := 0;
  ok := false;
  while (not ok) and (got < 4000) do
  begin
    n := net.recv(fd, addr(buf[got]), 4000 - got);
    if n <= 0 then break;
    got := got + n;
    // the body ends the reply: "ok" and a newline, after the blank line
    i := 0;
    while i + 2 < got do
    begin
      if (buf[i] = 'o') and (buf[i + 1] = 'k') and (buf[i + 2] = chr(10)) then ok := true;
      i := i + 1;
    end;
  end;
  if argch(2, 0) = 'r' then
  begin
    // struct linger { int l_onoff = 1; int l_linger = 0 }: close sends RST, not FIN
    lng[0] := chr(1);
    i := 1;
    while i < 8 do begin lng[i] := chr(0); i := i + 1; end;
    sys5(SYS.setsockopt, fd, 1, 13, addr(lng[0]), 8);   // SOL_SOCKET, SO_LINGER
  end;
  net.close(fd);
  if not ok then halt(1);
end.
EOF
compile "$T/cli.wz" "$T/cli"

"$WINE" "$T/srv.exe" >"$T/srv.out" 2>&1 &
# up to 30 s: the first start of a fresh prefix builds it
_n=0
while [ $_n -lt 100 ]; do
  "$T/cli" "$port" p 2>/dev/null && break
  _n=$((_n + 1)); sleep 0.3
done
[ $_n -lt 100 ] || { echo "  FAIL  the server never answered on port $port:"; cat "$T/srv.out"; cleanup_win; exit 1; }

fail=0
step() {   # step <name> <mode>: talk once in that mode, then the server must still answer
  "$T/cli" "$port" "$2" || { echo "  FAIL  $1: no 200 reply"; fail=1; }
  sleep 0.5
  "$T/cli" "$port" p || { echo "  FAIL  after $1 the server no longer answers"; fail=1; }
  if grep -q "runtime error" "$T/srv.out"; then
    echo "  FAIL  after $1 the server printed:"; cat "$T/srv.out"; fail=1
  fi
}
step "a normal close" f
step "a reset (SO_LINGER 0)" r
step "a second reset" r

cleanup_win
[ $fail -eq 0 ] && echo "  the server survives a closed and a reset keep-alive connection"
exit $fail
