# A name that no library declares must get the plain "undeclared identifier".
#
# The hint helps only when the name really is in a library. On an
# ordinary typo it would be noise, and worse, a wrong hint sends the reader to include a
# file that will not help.
#
# This is a .sh test and not a .err one because .err matches a SUBSTRING: a test asserting
# "undeclared identifier" would pass with a hint appended too. What is checked here is an
# ABSENCE.
#
# It also checks that both compilers say the same thing. They reach the answer by
# different means -- the self-hosted one searches the library it carries, bootstrap/boot.c
# has no embedded copy and tests whether lib/<prefix>.wz exists on disk -- so this is
# exactly the kind of counterpart pair that drifts unnoticed.
. "$ROOT/tests/helpers.sh"

cat > "$T/typo.wz" <<'WZ'
begin
  nosuchthing(1);
end.
WZ

cat > "$T/nolib.wz" <<'WZ'
begin
  notalibrary.something(1);
end.
WZ

for f in typo nolib; do
  "$WANTZEL" "$T/$f.wz" "$T/out.bin" >"$T/cerr" 2>&1 && {
    echo "$f.wz compiled, but it uses a name that does not exist"; exit 1; }
  assert_contains "$f is reported" "$(cat "$T/cerr")" "undeclared identifier"
  if grep -q "is declared in" "$T/cerr"; then
    echo "a library hint appeared for a name no library declares:"
    sed 's/^/  /' "$T/cerr"
    exit 1
  fi
done

# and the hint itself, from BOTH compilers, which must agree word for word
cat > "$T/forgot.wz" <<'WZ'
begin
  io.puts(STDOUT, "hi\n");
end.
WZ
"$WANTZEL"  "$T/forgot.wz" "$T/out.bin" >"$T/a" 2>&1
"$WANTZEL0" "$T/forgot.wz" "$T/out.bin" >"$T/b" 2>&1
assert_contains "the self-hosted compiler names the library" "$(cat "$T/a")" 'io.puts is declared in io.wz'
assert_contains "the C bootstrap names the library"          "$(cat "$T/b")" 'io.puts is declared in io.wz'

# the remedy it proposes has to work
cat > "$T/fixed.wz" <<'WZ'
include "io.wz";
begin
  io.puts(STDOUT, "hi\n");
end.
WZ
compile "$T/fixed.wz" "$T/fixed"
assert_eq "the suggested include makes it compile and run" "$("$T/fixed")" "hi"

echo "the hint names the library, both compilers agree, and a typo gets no hint"
