# lz.pack then lz.unpack gives back every file in lib/, byte for byte.
#
# The library is the real text this format carries -- the compiler stores it this way -- so
# it is the test set: 48 files of source, from a few hundred bytes to a hundred kilobytes.
# The program reads one file, packs it, unpacks it and compares; it also checks that the
# packed size stays within lz.bound, which is what a caller sizes its buffer by.
. "$ROOT/tests/helpers.sh"

cat > "$T/rt.wz" <<'WZ'
import io;
import lz;
var
  a, b: array[0..1999999] of char;
  p: array[0..2100000] of char;
  path: array[0..1023] of char;
  i, fd, n, k, m: int;
begin
  i := 0;
  while argch(1, i) <> chr(0) do begin path[i] := argch(1, i); i := i + 1; end;
  path[i] := chr(0);
  fd := sys3(2, addr(path[0]), 0, 0);
  if fd < 0 then begin io.puts(STDOUT, "cannot open\n"); halt(1); end;
  n := 0;
  while true do
  begin
    k := sys3(0, fd, addr(a[n]), len(a) - n);
    if k <= 0 then break;
    n := n + k;
  end;
  k := lz.pack(a, n, p);
  m := lz.unpack(p, k, b);
  if m <> n then begin io.puts(STDOUT, "length differs\n"); halt(1); end;
  for i := 0 to n - 1 do
    if a[i] <> b[i] then begin io.puts(STDOUT, "byte differs\n"); halt(1); end;
  if k > lz.bound(n) then begin io.puts(STDOUT, "above lz.bound\n"); halt(1); end;
  io.putn(STDOUT, n); io.puts(STDOUT, " "); io.putn(STDOUT, k); io.puts(STDOUT, "\n");
end.
WZ
compile "$T/rt.wz" "$T/rt"

files=0; total=0; packed=0
for f in "$ROOT"/lib/*.wz; do
  out=$("$T/rt" "$f") || { echo "$(basename "$f"): $out"; exit 1; }
  files=$((files + 1))
  total=$((total + ${out% *}))
  packed=$((packed + ${out#* }))
done
[ "$files" -gt 0 ] || { echo "no files in lib/"; exit 1; }
echo "$files files of lib/ packed and unpacked byte for byte: $total -> $packed bytes"
