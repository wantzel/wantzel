# A lib/ directory changes nothing: the library is the compiler's own.
#
# For a while the compiler read its library from a lib/ directory beside itself, and a
# bare include could be answered by the library or by a file next to the source,
# whichever existed. Both made the output depend on what happened to be on disk. Now
# `import` reads the module from the compiler file and nothing else, and `include` reads a
# file and nothing else. Three things are checked:
#
#   1. a lib/ beside the compiler, and one beside its bin/, with a changed io.wz in both,
#      do not change a single byte of the output
#   2. an io.wz next to the source does not change `import io;` either
#   3. `include "io.wz";` with no such file is not quietly answered by the library: it
#      is refused, with the import to write instead
. "$ROOT/tests/helpers.sh"

cat > "$T/p.wz" <<'WZ'
import io;
begin
  io.puts(STDOUT, "the real io\n");
end.
WZ
"$WANTZEL" "$T/p.wz" "$T/want" 2>"$T/err" || { echo "the reference compile failed:"; cat "$T/err"; exit 1; }

# a changed io.wz: puts writes something else
changed() { sed 's|^procedure io.puts(fd: int; s: str);|procedure io.puts(fd: int; s: str); begin sys3(1, fd, sadr("CHANGED\\n"), 8); end;\nprocedure io.putsreal(fd: int; s: str);|' "$ROOT/lib/io.wz"; }
changed | grep -q CHANGED || { echo "the test set itself up wrong: the change to io.wz did not apply"; exit 1; }

# ---- 1. lib/ beside the compiler, and beside its bin/
mkdir -p "$T/inst/bin/lib" "$T/inst/lib"
cp "$WANTZEL" "$T/inst/bin/wantzel"
changed > "$T/inst/bin/lib/io.wz"
changed > "$T/inst/lib/io.wz"
( cd "$T/inst" && ./bin/wantzel "$T/p.wz" "$T/got1" ) 2>"$T/err" || { echo "compile failed:"; cat "$T/err"; exit 1; }
cmp -s "$T/want" "$T/got1" || { echo "a lib/ directory beside the compiler changed the output"; exit 1; }

# ---- 2. an io.wz next to the source
mkdir -p "$T/src"
cp "$T/p.wz" "$T/src/p.wz"
changed > "$T/src/io.wz"
( cd "$T/src" && "$WANTZEL" p.wz "$T/got2" ) 2>"$T/err" || { echo "compile failed:"; cat "$T/err"; exit 1; }
assert_eq "an io.wz next to the source does not change import io" "$("$T/got2")" "the real io"

# ---- 3. include of a library name, with no file of that name
printf 'include "io.wz";\nbegin end.\n' > "$T/inc.wz"
if ( cd "$T" && "$WANTZEL" inc.wz "$T/got3" ) >"$T/err" 2>&1; then
  echo 'include "io.wz"; with no io.wz beside it compiled -- the library answered an include'
  exit 1
fi
assert_contains "the refusal gives the import" "$(cat "$T/err")" \
  "io.wz is not a file next to this one; the library module is imported: import io;"

echo "a lib/ directory and a local io.wz change nothing; an include is always a file"
