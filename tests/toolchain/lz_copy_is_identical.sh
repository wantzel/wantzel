# The compiler's unpacker is lz.unpack from lib/lz.wz, letter for letter.
#
# The compiler stores its standard library packed with lib/lz.wz and unpacks it with a
# routine of its own, lzunpack in src/wantzel.wz -- a copy, because the compiler's source
# includes nothing. Two implementations of one format drift: one gets a fix, a check, a
# wider window, and the other does not. So the two routine texts are compared, with the
# name as the only difference allowed. Behaviour is checked as well, elsewhere: build.sh
# and lib_export.sh read every module back through the compiler.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# routine <file> <first line>: from that line to the first `end;` at the left margin
routine() { awk -v first="$2" '$0 == first { f = 1 } f { print } f && /^end;$/ { exit }' "$1"; }

routine lib/lz.wz 'function lz.unpack(src: array of char; n: int; dst: array of char): int;' > "$T/lib"
routine src/wantzel.wz 'function lzunpack(src: array of char; n: int; dst: array of char): int;' \
  | sed 's/^function lzunpack(/function lz.unpack(/' > "$T/compiler"

[ -s "$T/lib" ] || { echo "lz.unpack is not in lib/lz.wz"; exit 1; }
[ -s "$T/compiler" ] || { echo "lzunpack is not in src/wantzel.wz"; exit 1; }
if ! cmp -s "$T/lib" "$T/compiler"; then
  echo "lzunpack in src/wantzel.wz is no longer a copy of lz.unpack in lib/lz.wz:"
  diff "$T/lib" "$T/compiler" | sed 's/^/  /'
  echo
  echo "Change lib/lz.wz, copy the routine into src/wantzel.wz under the name lzunpack,"
  echo "and rebuild."
  exit 1
fi
echo "lzunpack is lz.unpack: $(wc -l < "$T/lib") lines, identical"
