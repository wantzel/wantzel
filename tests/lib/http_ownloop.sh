# lib/http.wz: a program that runs its own epoll loop out of the fd-based routines --
# http.accept, http.readable, http.flush, http.drop and http.open[fd], the shape written
# before http.listen and http.poll existed -- still compiles and still serves: hundreds of
# connections at once, pipelined requests, and a reply that has to wait for the socket.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(free_port)
ulimit -Sn 4096 2>/dev/null

cat > "$T/own.wz" <<'EOF'
include "http.wz";

var
  big: array[0..299999] of char;
  sndbuf: array[0..3] of char;
  ev: array[0..255 * 12 - 1] of char;

procedure app.request;
var i: int;
begin
  if http.pathis("/big") then
  begin
    // a small send buffer, so this reply cannot leave in one send
    io.put32(sndbuf, 0, 8192);
    i := sys5(SYS.setsockopt, http.fd, SOL_SOCKET, 7, addr(sndbuf[0]), 4);
    for i := 0 to 299999 do big[i] := 'q';
    http.addb(big, 0, 300000);
    http.finish(200, "text/plain");
    return;
  end;
  http.add("ok");
  http.finish(200, "text/plain");
end;

procedure runloop(port: int);
var n, i, e, fd: int;
begin
  http.lfd := net.listen(port, 1024, false);
  if http.lfd < 0 then io.fatal("cannot bind the port");
  http.ep := net.epoll;
  if http.ep < 0 then io.fatal("cannot create the epoll set");
  if not net.watch(http.ep, EPOLL_ADD, http.lfd, EPOLLIN) then
    io.fatal("cannot watch the listening socket");
  while true do
  begin
    n := net.wait(http.ep, addr(ev[0]), 255, 50);
    if n < 0 then begin if n <> EINTR then io.fatal("epoll_wait failed"); n := 0; end;
    i := 0;
    while i < n do
    begin
      e := io.get32(ev, i * 12);
      fd := io.get32(ev, i * 12 + 4);
      if fd = http.lfd then http.accept
      else if (fd >= 0) and (fd < MAXCONN) and http.open[fd] then
      begin
        if band(e, bor(EPOLLERR, EPOLLHUP)) <> 0 then http.drop(fd)
        else
        begin
          if band(e, EPOLLOUT) <> 0 then http.flush(fd);
          if http.open[fd] and (band(e, EPOLLIN) <> 0) then http.readable(fd);
        end;
      end;
      i := i + 1;
    end;
  end;
end;

begin
  runloop(PORT);
end.
EOF
sed -i "s/PORT/$port/" "$T/own.wz"
compile "$T/own.wz" "$T/own"
compile "$ROOT/tests/helpers/httpload.wz" "$T/load"

"$T/own" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

out=$("$T/load" open "$port" 600)
assert_eq "600 connections at once are answered by a hand-written loop" "$out" "opened=600 served=600 closed=0"
out=$("$T/load" pipe "$port" 20)
assert_eq "pipelined requests are answered by a hand-written loop" "$out" "pipelined=20 answered=20"
size=$(curl -s -m 10 "http://127.0.0.1:$port/big" | wc -c)
assert_eq "a reply that waits for the socket arrives whole through http.flush" "$size" "300000"

echo "a hand-written loop over http.accept, http.readable, http.flush and http.open still serves"
