# The fixed part of a runtime message is stored ONCE, not once per check.
#
# Every bounds check, chr() range, division and missing return carries a message. Storing the
# whole sentence per check made those messages a quarter of a large binary: six distinct texts,
# 345 copies, differing only in the file name and line number.
#
# The heading is now shared and the trap routine writes it before the place. This test pins
# both halves of that: the text appears once, and the message the user sees is unchanged --
# a smaller binary that reports less would not be an improvement.
. "$ROOT/tests/helpers.sh"

cat > "$T/many.wz" <<'WZ'
var a: array[0..3] of int;
  i, k: int;
begin
  i := 0;
  while i < 12 do
  begin
    a[i mod 4] := i;      // each of these is a bounds check with its own line
    k := a[i mod 4];
    i := i + 1;
  end;
  a[i] := 1;              // and this one fires
end.
WZ

"$ROOT/bin/wantzel" "$T/many.wz" "$T/many" || { echo "did not compile"; exit 1; }

# The message must still name the kind, the file and the line.
"$T/many" 2>"$T/err"; code=$?
[ "$code" = "1" ] || { echo "expected exit 1, got $code"; exit 1; }
grep -qE "runtime error: array index out of range at .*many\.wz:[0-9]+$" "$T/err" \
  || { echo "the message lost its kind, file or line:"; cat "$T/err"; exit 1; }

# And the heading is stored once, however many checks there are.
n=$(strings "$T/many" | grep -c "^runtime error: array index out of range at $")
[ "$n" = "1" ] || { echo "the heading is stored $n times, expected 1"; exit 1; }

# No complete sentence should remain: that is the form this replaced.
if strings "$T/many" | grep -q "^runtime error: .* at .*\.wz:[0-9]"; then
  echo "a complete sentence is still stored per check"
  strings "$T/many" | grep "^runtime error: .* at .*\.wz:[0-9]" | head -3
  exit 1
fi

# Both compilers must agree: boot.c is what a fresh clone builds with.
"$ROOT/bin/wantzel0" "$T/many.wz" "$T/many0" || { echo "the C bootstrap cannot compile it"; exit 1; }
cmp -s "$T/many" "$T/many0" || { echo "the two compilers disagree"; exit 1; }

echo "  one heading per kind of check, the message unchanged, and both compilers agree"
