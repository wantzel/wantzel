# lib/http.wz: http.maxbody(cap) lets a connection read a body bigger than INBUF (256 kB)
# into a region mapped for that body alone, released once it is answered -- nothing is
# reserved up front, and nothing is multiplied by MAXCONN.
#
# TOETSGROEP: lib
# DEKT: lib/http.wz
#
# WHAT THIS PROVES, AND WHY IT IS SEPARATE FROM httpd_toolarge.sh: that test shows the
# request is answered instead of reset when NO overflow region exists.  This one shows the
# request actually SUCCEEDS once a program asks for the room, and that asking for it does
# not multiply MAXCONN (256) static buffers by the new capacity -- it is checked here by
# comparing the built binary's declared memory size (the ELF LOAD segment's MemSiz, since
# this compiler emits no section headers for `size` to read) with and without the call, not
# just by reading the source and assuming.
. "$ROOT/tests/helpers.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

port=$(( 22000 + ($$ % 900) ))

cat > "$T/bigsrv.wz" <<EOF
include "http.wz";
procedure app.request;
begin
  if http.bodyinbig then http.addn(http.bodylen)
  else http.add("small");
  http.finish(200, "text/plain");
end;
begin
  http.maxbody(4194304);         // 4 MB: room to spare over the ~2.1 MB body used below
  http.serve($port, 1);
end.
EOF
compile "$T/bigsrv.wz" "$T/bigsrv"

# ---- part of the acceptance criteria: the BSS-equivalent size does not scale with MAXCONN.
cat > "$T/nobig.wz" <<EOF
include "http.wz";
procedure app.request;
begin
  http.add("small");
  http.finish(200, "text/plain");
end;
begin
  http.serve($port, 1);
end.
EOF
compile "$T/nobig.wz" "$T/nobig"

memsz() { readelf -l "$1" 2>/dev/null | awk '/LOAD/{getline; print $2}'; }
before=$(printf '%d' "$(memsz "$T/nobig")")
after=$(printf '%d' "$(memsz "$T/bigsrv")")
delta=$((after - before))
echo "declared memory: without http.maxbody = $before bytes, with a 4 MB cap = $after bytes (delta $delta)"
# The 4 MB asked for must NOT show up multiplied by MAXCONN (256) in the static image --
# that would be >1 GB of delta.  A few hundred bytes for the new global fields is fine;
# the 4 MB itself comes from mmap at run time, per body, invisible to this measurement,
# which is the point.
if [ "$delta" -gt 1048576 ]; then
  echo "http.maxbody(4 MB) grew the declared memory size by $delta bytes -- looks like it is being multiplied per connection, not shared"
  exit 1
fi

# ---- the actual behaviour: a body bigger than INBUF succeeds when the room was asked for.
"$T/bigsrv" >"$T/server.log" 2>&1 &
pid=$!
cleanup() { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "the server did not come up on port $port"; cat "$T/server.log"; exit 1; }

# ~2.1 MB: bigger than INBUF (256 kB) by nearly an order of magnitude, comfortably within
# the 4 MB cap configured above. The size is what this test is about, not the content.
dd if=/dev/zero of="$T/big.bin" bs=1024 count=2148 status=none
wantsize=$(wc -c < "$T/big.bin")

code=$(curl -s -o "$T/big_out" -w '%{http_code}' -X POST --data-binary "@$T/big.bin" "http://127.0.0.1:$port/big")
assert_eq "a body within the configured cap is accepted" "$code" "200"
assert_eq "the handler saw the whole body, not a truncated prefix" "$(cat "$T/big_out")" "$wantsize"

# A normal small request right after must still work: the body's region is released after
# use, not left with the connection that used it.
small=$(curl -s "http://127.0.0.1:$port/small")
assert_eq "a small request after the big one is still served" "$small" "small"

# A SECOND big body on another connection must also succeed.
code2=$(curl -s -o "$T/big_out2" -w '%{http_code}' -X POST --data-binary "@$T/big.bin" "http://127.0.0.1:$port/big2")
assert_eq "a second big body after the first is accepted" "$code2" "200"
assert_eq "the second big body is also read in full" "$(cat "$T/big_out2")" "$wantsize"

echo "http.maxbody lets a connection read a body bigger than INBUF, without multiplying static memory by MAXCONN"
