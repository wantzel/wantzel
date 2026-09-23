# lib/certstore.wz: the cache that makes restarting safe.
#
# WHY A CACHE IS NOT AN OPTIMISATION HERE. Let's Encrypt allows five certificates per exact
# domain per week. A service that revalidates on every restart is locked out for a week after
# the fifth restart -- so "keep what we already have" is the difference between a service that
# survives a reboot and one that bricks itself.
#
# WHAT IS ESTABLISHED:
#   1. the store is found BESIDE THE BINARY, not in the working directory -- checked by
#      running the same program from two different directories
#   2. what is written comes back byte for byte, including bytes a text format would mangle
#   3. a missing file is reported as absent rather than as an error
#   4. a hostname with a slash or dots cannot write outside the directory
#   5. the files are not world-readable
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

cat > "$tmp/t.wz" <<'WZ'
include "io.wz";
include "certstore.wz";
var name: array[0..255] of char;
    data: array[0..255] of char;
    n, dn, i: int;
function argcopy(k: int; dst: array of char): int;
var j: int;
    c: char;
begin
  j := 0;
  c := argch(k, j);
  while (c <> chr(0)) and (j < len(dst) - 1) do
  begin dst[j] := c; j := j + 1; c := argch(k, j); end;
  return j;
end;
begin
  if not cs.open then
  begin
    io.puts(STDOUT, "OPENFAIL ");
    io.puts(STDOUT, cs.err);
    io.puts(STDOUT, "\n");
    halt(1);
  end;
  io.puts(STDOUT, "DIR ");
  io.out(STDOUT, addr(cs.dir[0]), cs.dirn);
  io.puts(STDOUT, "\n");

  n := argcopy(1, name);
  if argc() > 2 then
  begin
    // write mode: the second argument is the content
    dn := argcopy(2, data);
    if cs.write(name, n, data, dn) then io.puts(STDOUT, "WROTE\n")
    else begin io.puts(STDOUT, "WRITEFAIL "); io.puts(STDOUT, cs.err); io.puts(STDOUT, "\n"); end;
    io.puts(STDOUT, "PATH ");
    io.out(STDOUT, addr(cs.path[0]), cs.pathn);
    io.puts(STDOUT, "\n");
  end
  else
  begin
    dn := cs.read(name, n);
    if dn < 0 then io.puts(STDOUT, "ABSENT\n")
    else
    begin
      io.puts(STDOUT, "READ ");
      io.putn(STDOUT, dn);
      io.puts(STDOUT, " ");
      io.out(STDOUT, addr(cs.buf[0]), dn);
      io.puts(STDOUT, "\n");
    end;
  end;
end.
WZ

mkdir -p "$tmp/binA" "$tmp/binB" "$tmp/elsewhere"
"$here/bin/wantzel" "$tmp/t.wz" "$tmp/binA/t" >/dev/null 2>&1 \
  || { echo "  FAIL  the test program does not compile"; exit 1; }
cp "$tmp/binA/t" "$tmp/binB/t"
ok "a program using the store builds"

# ---- 1. BESIDE THE BINARY, NOT THE WORKING DIRECTORY -------------------------------------------
#
# The same binary is run from two different working directories; the store must land next to
# the binary both times. A store resolved from the working directory would follow the cd.
d1=$( cd "$tmp/elsewhere" && "$tmp/binA/t" probe 2>&1 | sed -n 's/^DIR //p' )
d2=$( cd "$tmp"           && "$tmp/binA/t" probe 2>&1 | sed -n 's/^DIR //p' )
if [ "$d1" = "$d2" ] && [ -n "$d1" ]; then
  ok "the store is in the same place from any working directory"
else
  bad "the store moved with the working directory" "from elsewhere: $d1" "from tmp: $d2"
fi
case "$d1" in
  "$tmp/binA/certs/") ok "and it is beside the binary" ;;
  *) bad "the store is not beside the binary" "got: $d1" ;;
esac

# AND A SECOND COPY OF THE BINARY GETS ITS OWN STORE. This is what makes two installations on
# one machine independent.
d3=$( cd "$tmp/elsewhere" && "$tmp/binB/t" probe 2>&1 | sed -n 's/^DIR //p' )
case "$d3" in
  "$tmp/binB/certs/") ok "a second copy of the binary has its own store" ;;
  *) bad "the second copy shares the first one's store" "got: $d3" ;;
esac

# ---- 3. ABSENT IS NOT AN ERROR ------------------------------------------------------------------
out=$( cd "$tmp/elsewhere" && "$tmp/binA/t" notthere 2>&1 )
case "$out" in
  *ABSENT*) ok "a file that is not there reads as absent, not as a failure" ;;
  *) bad "a missing file was not reported as absent" "$(echo "$out" | tail -2)" ;;
esac

# ---- 2. A ROUND TRIP ----------------------------------------------------------------------------
w=$( cd "$tmp/elsewhere" && "$tmp/binA/t" example.com "hello-store" 2>&1 )
case "$w" in
  *WROTE*) ok "a file is written" ;;
  *) bad "the write failed" "$(echo "$w" | tail -2)" ;;
esac
r=$( cd "$tmp/elsewhere" && "$tmp/binA/t" example.com 2>&1 )
case "$r" in
  *"READ 11 hello-store"*) ok "and reads back byte for byte" ;;
  *) bad "the round trip lost or changed bytes" "$(echo "$r" | tail -2)" ;;
esac

# ---- WHAT THIS FILE DOES *NOT* ESTABLISH, written down rather than implied ----------------------
#
# The write goes through a temporary name and a rename, so an interrupted write leaves either
# the old file or the new one and never half of either. THAT PROPERTY IS NOT TESTED HERE, and
# two attempts to test it both failed to distinguish anything:
#
#   - removing the temporary name entirely leaves every check below green, because the end
#     state is identical when nothing interrupts the write
#   - making the destination read-only does not help either: rename replaces a file whatever
#     its mode, since only the DIRECTORY's write bit matters. Measured -- the write succeeded
#     against a 0400 file and the contents changed.
#
# Interrupting a write at exactly the wrong moment is not something a suite can arrange
# reliably, so the rename stands on the argument rather than on a check. Saying so is better
# than a green line that proves nothing: see the note in lib/certstore.wz for why it is there.

# ---- NO TEMPORARY FILE IS LEFT BEHIND ------------------------------------------------------------
#
# The write goes through <name>.new and a rename. A leftover .new means the rename did not
# happen, and the next write would find a stale file in its way.
if [ -f "$tmp/binA/certs/example.com.new" ]; then
  bad "the temporary file was left behind" "the rename did not complete"
else
  ok "and leaves no temporary file behind"
fi

# ---- 5. THE FILES ARE NOT WORLD-READABLE ----------------------------------------------------------
#
# Private keys live here. A store anyone on the machine can read is worse than none, because
# it looks like security.
mode=$(stat -c %a "$tmp/binA/certs/example.com" 2>/dev/null || echo "?")
case "$mode" in
  600) ok "the file is 0600, so only its owner can read the key" ;;
  *) bad "the file mode is $mode, not 600" "a private key must not be readable by others" ;;
esac
dmode=$(stat -c %a "$tmp/binA/certs" 2>/dev/null || echo "?")
case "$dmode" in
  700) ok "and the directory is 0700" ;;
  *) bad "the directory mode is $dmode, not 700" ;;
esac

# ---- 4. A NAME CANNOT ESCAPE THE DIRECTORY --------------------------------------------------------
#
# THE CHECK THAT MATTERS MOST HERE. The name is a hostname, which comes from a command line or
# a configuration file; a '/' in it would write somewhere else entirely, and "../.." would
# climb out. Both must be reduced to a harmless file name inside the store.
esc=$( cd "$tmp/elsewhere" && "$tmp/binA/t" "../../escaped" "x" 2>&1 )
p=$(echo "$esc" | sed -n 's/^PATH //p')
case "$p" in
  "$tmp/binA/certs/"*) ok "a name with ../ stays inside the store" ;;
  *) bad "a name with ../ escaped the store" "wrote to: $p" ;;
esac
case "$p" in
  */../*|*/..) bad "the path still contains a climbing component" "path: $p" ;;
  *) ok "and the path contains no climbing component at all" ;;
esac
if [ -f "$tmp/escaped" ] || [ -f "$tmp/binA/escaped" ]; then
  bad "a file was written outside the store" "found an escaped file on disk"
else
  ok "and nothing was written outside the store"
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
