# The same failure says the same thing, wherever it is raised.
#
# WHAT WENT WRONG, and it is the reason this test exists. A hex escape with no two digits
# had TWO messages, three lines apart in the same routine:
#
#     "a hex escape needs two digits"
#     "a hex escape needs exactly two hex digits, as in x41 or xff after a backslash"
#
# Which one you got depended on whether the source happened to end before the escape did --
# a distinction no reader can act on differently. One carried an example and one did not, so
# the help you received depended on where your file ended.
#
# WHAT IS CHECKED. Two things, and the second is the one that catches a new case:
#
#   1. The two compilers agree. src/compiler.wz and bootstrap/boot.c are counterparts, and a
#      message improved in one and not the other is the usual way they drift.
#   2. No two DIFFERENT messages share an opening. A pair like "a hex escape needs ..." twice
#      is almost always one failure described twice -- and where it is not, the two should
#      still not begin identically, because the reader distinguishes them by their opening.
#
# WHY NOT A LIST OF KNOWN-GOOD MESSAGES. That is a second copy of the texts, and it goes
# stale the first time someone improves one. This compares the compiler with itself.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# Every literal message the compiler can print, from both counterparts.
wz=$(grep -oE 'fail\("[^"]{12,}"' src/compiler.wz | sed 's/^fail("//; s/"$//' | sort -u)
bc=$(grep -oE 'fail\("[^"]{12,}"' bootstrap/boot.c  | sed 's/^fail("//; s/"$//' | sort -u)

[ -n "$wz" ] || { echo "no messages found in src/compiler.wz -- has fail() been renamed?"; exit 1; }
[ -n "$bc" ] || { echo "no messages found in bootstrap/boot.c -- has fail() been renamed?"; exit 1; }

# ---- 1. THE COUNTERPARTS AGREE -----------------------------------------------------------
#
# Only in the direction that matters: a message the Wantzel compiler has and the C bootstrap
# does not means a fresh clone reports something different from an installed compiler. The
# reverse is normal -- boot.c is smaller and refuses things the real compiler never reaches.
# NO PROCESS SUBSTITUTION: the suite runs these with sh, where `<(...)` is a syntax error.
# That is the third time it has bitten -- see docs/testing.md.
printf '%s\n' "$wz" > "$T/wz.txt"
printf '%s\n' "$bc" > "$T/bc.txt"
missing=$(comm -23 "$T/wz.txt" "$T/bc.txt")
if [ -n "$missing" ]; then
  n=$(printf '%s\n' "$missing" | wc -l)
  echo "$n message(s) exist in src/compiler.wz but not in bootstrap/boot.c:"
  printf '%s\n' "$missing" | head -5 | sed 's/^/  /'
  echo "  a fresh clone builds with boot.c, so it would report something else"
  exit 1
fi

# ---- 2. NO FAILURE DESCRIBED TWICE -------------------------------------------------------
#
# ONE MESSAGE BEING A PREFIX OF ANOTHER is the shape that matters, and it is narrower than
# "the same opening". "missing ) after the values" and "missing ) after a field" share four
# words and are genuinely different failures -- a parser has many of those and they are fine.
#
# What the hex escape looked like was different: "a hex escape needs two digits" was a
# PREFIX of "a hex escape needs exactly two hex digits, as in ...". One sentence being the
# start of another is what you get when someone improves a message and misses a copy.
dup=""
printf '%s\n' "$wz" > "$T/all.txt"
while IFS= read -r m; do
  [ -n "$m" ] || continue
  # Any OTHER message this one is a prefix of, ignoring a trailing word boundary.
  # ANCHORED AT THE START. Without the anchor "expression expected" matches inside
  # "constant expression expected", which is a different failure that happens to end the
  # same way. What is being looked for is one message that BEGINS another.
  hit=$(grep -F "$m" "$T/all.txt" | grep -vxF "$m" | while IFS= read -r o; do
          case "$o" in "$m"*) printf '%s' "$o"; break ;; esac
        done)
  if [ -n "$hit" ]; then
    dup="$dup$m
  is the start of: $hit
"
  fi
done < "$T/all.txt"
if [ -n "$dup" ]; then
  echo "one message is contained in another -- the same failure with two wordings:"
  printf '%s' "$dup" | sed 's/^/  /'
  echo "  pick one and share it through a constant (see docs/conventions.md)"
  exit 1
fi

echo "ok: $(printf '%s\n' "$wz" | wc -l) messages, none duplicated, both counterparts agree"
