# A name that no library module declares must get the plain "undeclared identifier".
#
# The hint helps only when the name really is in a module. On an ordinary typo it would be
# noise, and worse, a wrong hint sends the reader to import a module that will not help.
#
# This is a .sh test and not a .err one because .err matches a SUBSTRING: a test asserting
# "undeclared identifier" would pass with a hint appended too. What is checked here is an
# ABSENCE.
#
# Only the self-hosted compiler is asked. The library is part of it; bootstrap/boot.c has
# none, and needs none to build the compiler.
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

# ---- A NAME WHOSE PREFIX IS A REAL LIBRARY, BUT WHICH DOES NOT EXIST --------------------
#
# THE HARD CASE, because the cheap check says yes: io.wz EXISTS, so "is there a lib/io.wz?"
# answers correctly and the old compiler stopped there. But io.putc is not in it, and the
# message sent the reader to a file that does not have what they need.
#
# BOTH SPELLINGS, and they used to fail the same way for different reasons:
#   already/  io is imported three lines up   -> "add: import io;" is absurd advice
#   notyet/   io is not imported              -> naming the module is still wrong
#
# MEASURED 18-09-2026: an agent reads "add: ..." for the line it already has, adds it
# again, recompiles, gets the identical error, and has nowhere left to go. The message took
# away the one fact it needed -- that the name does not exist.
cat > "$T/already.wz" <<'WZ'
import io;
begin
  io.putc(1, chr(65));
end.
WZ
cat > "$T/notyet.wz" <<'WZ'
begin
  io.putc(1, chr(65));
end.
WZ

for f in already notyet; do
  "$WANTZEL" "$T/$f.wz" "$T/out.bin" >"$T/cerr" 2>&1 && {
    echo "$f.wz compiled, but io.putc does not exist"; exit 1; }
  assert_contains "$f is reported" "$(cat "$T/cerr")" "undeclared identifier: io.putc"
  # THE ABSENCE IS THE POINT, and it is why this lives in a .sh: an .err file matches a
  # SUBSTRING, so "undeclared identifier: io.putc" passes just as happily with the wrong
  # sentence appended to it.
  if grep -q "is declared in" "$T/cerr"; then
    echo "$f: a library hint appeared for a name that module does not declare:"
    sed 's/^/  /' "$T/cerr"
    exit 1
  fi
done

# ---- ONE TYPO AWAY: NAME THE NEIGHBOUR. FURTHER AWAY: SAY NOTHING ----------------------
#
# io.putc is one edit from io.puts, and being told only "undeclared" leaves the writer to
# find that by reading the library.
#
# THE THRESHOLD IS A MEASUREMENT, NOT A KNOB. Against the 144 entries of the error log,
# every name a writer actually invented -- print, writeln, say, js.obj -- has its nearest
# real neighbour 3 to 5 edits away. At distance 3 the "help" would be `Init` for `print`
# and `a` for `say`, which is worse than silence: a wrong suggestion is the very failure
# this message was fixed for. So: distance one, within the module the prefix names.
cat > "$T/near.wz" <<'WZ'
import io;
begin
  io.putc(1, chr(65));
end.
WZ
# io.putint IS THE FAR CASE ON PURPOSE, and it took a round to pick it: `print` has no dot,
# so the prefix filter rejects it before the distance is ever computed -- it proves nothing
# about the threshold. io.putint is two edits from io.putn, inside the module the prefix
# names, so it reaches exactly the comparison this guards.
cat > "$T/far.wz" <<'WZ'
import io;
begin
  io.putint(1, 3);
end.
WZ

"$WANTZEL" "$T/near.wz" "$T/out.bin" >"$T/cerr" 2>&1
assert_contains "one typo away gets the neighbour" "$(cat "$T/cerr")" \
  "undeclared identifier: io.putc -- did you mean io.puts?"
"$WANTZEL" "$T/far.wz" "$T/out.bin" >"$T/cerr" 2>&1
# AN ABSENCE AGAIN: an invented name must get no suggestion at all.
if grep -q "did you mean" "$T/cerr"; then
  echo "a suggestion appeared for an invented name, which is worse than none:"
  sed 's/^/  /' "$T/cerr"
  exit 1
fi

# and the hint itself, with the line to add
cat > "$T/forgot.wz" <<'WZ'
begin
  io.puts(STDOUT, "hi\n");
end.
WZ
"$WANTZEL" "$T/forgot.wz" "$T/out.bin" >"$T/a" 2>&1
assert_contains "the compiler names the module and the import" "$(cat "$T/a")" \
  'io.puts is declared in the library module io; add: import io;'

# the remedy it proposes has to work
cat > "$T/fixed.wz" <<'WZ'
import io;
begin
  io.puts(STDOUT, "hi\n");
end.
WZ
compile "$T/fixed.wz" "$T/fixed"
assert_eq "the suggested import makes it compile and run" "$("$T/fixed")" "hi"

echo "the hint names the library, both compilers agree, and a name that is not there gets no hint"
