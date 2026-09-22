# An include that cannot be opened must name the path it TRIED, not only the name written
# on the line.
#
# THE CASE THIS EXISTS FOR is a compiler unpacked without lib/ beside it -- the thing that
# shipped broken in 0.1.0. There, `include "io.wz";` fails, and "cannot open the included
# file: io.wz" repeats what the source already says: the reader goes looking in their own
# directory for a file the compiler was expecting somewhere else entirely.
#
# It was broken in a way that reads as correct. For a bare library name the compiler builds
# <compiler dir>/lib/io.wz into pathbuf, and when that file is absent the fallback to a
# relative path OVERWRITES that buffer with the bare name. The message then prints what is
# left, which is never the library path. The comment above the routine had promised the
# path since the day it was written.
#
# A NAME WITH A '/' IN IT IS NOT A LIBRARY NAME and gets no extra line: there was only one
# path to try, and naming it twice is noise.
. "$ROOT/tests/helpers.sh"

# A compiler with no lib/ beside it: copy the binary alone, which is exactly the mistake.
mkdir -p "$T/bare"
cp "$WANTZEL" "$T/bare/wantzel"
[ -d "$T/bare/lib" ] && bad "the test set itself up wrong: there must be no lib/ here"

mkdir -p "$T/src"
printf 'include "io.wz";\n\nbegin\n  io.puts(STDOUT, "x\\n");\nend.\n' > "$T/src/uses_lib.wz"
printf 'include "nowhere/gone.wz";\nbegin end.\n' > "$T/src/uses_path.wz"

# 1. a bare library name: the message names the library path that was tried
out=$(cd "$T/src" && "$T/bare/wantzel" uses_lib.wz "$T/out1" 2>&1)
case "$out" in
  *"cannot open the included file: io.wz"*) ;;
  *) bad "the first line no longer names the include as written: $out" ;;
esac
case "$out" in
  *"looked in the library first: $T/bare/lib/io.wz"*) ok "a bare name names the library path it tried" ;;
  *) bad "the library path is missing from the message: $out" ;;
esac

# 2. a name with a '/': one path, one line, no library line
out=$(cd "$T/src" && "$T/bare/wantzel" uses_path.wz "$T/out2" 2>&1)
case "$out" in
  *"cannot open the included file: nowhere/gone.wz"*) ;;
  *) bad "a relative include no longer names itself: $out" ;;
esac
case "$out" in
  *"looked in the library"*) bad "a path include should not mention the library: $out" ;;
  *) ok "a path include says only what it tried" ;;
esac

# 3. with lib/ in place the same source compiles, so the message above is about a missing
#    library and not about a compiler that cannot find its library at all
cp -r "$(dirname "$WANTZEL")/../lib" "$T/bare/lib" 2>/dev/null || cp -r "$(dirname "$WANTZEL")/lib" "$T/bare/lib"
# a NEW output name: the two failed compiles above left $T/out1 half-written, and
# overwriting a file that was just executed gives "Text file busy" rather than a result
(cd "$T/src" && "$T/bare/wantzel" uses_lib.wz "$T/good") 2>"$T/err" \
  || bad "with lib/ beside it the same source must compile: $(cat "$T/err")"
assert_eq "and it runs" "$("$T/good")" "x"
