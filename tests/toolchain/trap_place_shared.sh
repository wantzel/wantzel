# A line with several checks stores its place once, and a different line does not share it.
#
# WHAT THIS SAVES. Every runtime check carries a place -- "file.wz:123" -- and each stored
# copy costs its text plus an eight-byte length and alignment padding, so twelve characters
# take 24 bytes. One line often holds more than one check: `a[i] := b[j] + c[k]` is three
# bounds checks and one place.
#
# MEASURED in bin/wantzel on 22-09-2026: 1016 place strings, 662 of them distinct. Removing
# the duplicates took the compiler from 298817 to 287697 bytes -- 11120 bytes, 3.7%.
#
# AND THE HALF THAT MATTERS MORE THAN THE SAVING: the messages must still be right. A cache
# that leaks across lines points a runtime error at the wrong line, which is worse than a
# bigger binary -- the reader goes to look at code that is fine.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# ---- 1. THREE CHECKS ON ONE LINE, ONE PLACE ----------------------------------------------
cat > "$T/one.wz" <<'WZ'
var a: array[0..3] of int;
    b: array[0..3] of int;
    c: array[0..3] of int;
    i, j, k: int;
begin
  i := 0; j := 0; k := 9;
  a[i] := b[j] + c[k];
  halt(0);
end.
WZ
compile "$T/one.wz" "$T/one"
places=$(strings -a "$T/one" | grep -c "one\.wz:" || true)
assert_eq "three checks on one line store one place" "$places" "1"

# AND THE MESSAGE IS STILL RIGHT. The failing index is on line 7.
out=$(cd "$T" && ./one 2>&1); rc=$?
assert_eq "it still stops" "$rc" "1"
assert_contains "and names the line the check is on" "$out" "one.wz:7"

# ---- 2. TWO LINES DO NOT SHARE -----------------------------------------------------------
#
# THE CHECK THAT EARNS ITS PLACE. If the cache did not compare the line, the second failure
# would report the first line -- a message that sends the reader to code that is correct.
cat > "$T/two.wz" <<'WZ'
var a: array[0..3] of int;
    i, k: int;
begin
  i := 0; k := 9;
  a[i] := 1;
  a[k] := 2;
  halt(0);
end.
WZ
compile "$T/two.wz" "$T/two"
places=$(strings -a "$T/two" | grep -c "two\.wz:" || true)
assert_eq "two lines store two places" "$places" "2"

out=$(cd "$T" && ./two 2>&1); rc=$?
assert_eq "it stops on the second line" "$rc" "1"
assert_contains "and names THAT line, not the first" "$out" "two.wz:6"

# ---- 3. THE FIRST CHECK IS NOT A REUSE ---------------------------------------------------
#
# The cache starts empty, and an empty one must not read as "data offset 0" -- that would
# make the very first check point at whatever happens to be stored there.
cat > "$T/first.wz" <<'WZ'
var a: array[0..3] of int;
    k: int;
begin
  k := 9;
  a[k] := 1;
  halt(0);
end.
WZ
compile "$T/first.wz" "$T/first"
out=$(cd "$T" && ./first 2>&1); rc=$?
assert_eq "a program whose first check fails still stops" "$rc" "1"
assert_contains "and names its own line" "$out" "first.wz:5"

echo "ok: one place per line, and every message still names the line it belongs to"
