# docs/syntax.md counts the keywords the same way the compiler does.
#
# The page states the number twice -- once in the opening sentence, once as the heading
# above the list -- and then prints the words themselves. Three facts that must agree,
# and nothing was holding them together: the opening line read "forty-three keywords"
# for a while after `program`, `repeat` and `case` were removed, next to a heading that
# already said thirty-nine.
#
# grammar_matches_compiler.sh does not cover this. It compares the editor grammar with
# the compiler and never reads the prose, because a number written out in a sentence is
# not wired to anything. This is that wire.
#
# The list is checked against src/wantzel.wz rather than against a number kept here, so
# removing a keyword means editing the compiler and the page -- never this test.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

doc=docs/syntax.md
[ -f "$doc" ] || { echo "$doc is missing"; exit 1; }

# The keyword table in the compiler is the truth. Every keyword has a KW_ constant, so
# counting those counts the language's vocabulary.
actual=$(grep -oE "KW_[A-Z0-9]+ *=" src/wantzel.wz | sed 's/KW_//; s/ *=//' | sort -u | wc -l)
[ "$actual" -gt 0 ] || { echo "no KW_ constants found in src/wantzel.wz -- have they been renamed?"; exit 1; }

# The words printed on the page, taken from the fenced block under the heading.
listed=$(awk '/^## The .* keywords$/ { found = 1; next }
              found && /^```$/ { inblk = !inblk; if (!inblk) exit; next }
              inblk { print }' "$doc" | tr -s ' \t' '\n\n' | grep -v '^$' | sort -u)
listed_n=$(echo "$listed" | grep -c .)

assert_eq "docs/syntax.md lists as many keywords as the compiler has" "$listed_n" "$actual"

# Every listed word must really be a keyword, so a typo cannot pad the list back to the
# right length.
for w in $listed; do
  grep -qiE "KW_$(echo "$w" | tr 'a-z' 'A-Z') *=" src/wantzel.wz || {
    echo "docs/syntax.md lists '$w', which is not a keyword in src/wantzel.wz"
    exit 1
  }
done

# Both written-out numbers on the page. Spelling a number in words is the whole reason
# this drifts: nothing about "forty-three" looks wrong next to a list of thirty-nine.
word_for() {
  case "$1" in
    36) echo "thirty-six" ;;   37) echo "thirty-seven" ;; 38) echo "thirty-eight" ;;
    39) echo "thirty-nine" ;;  40) echo "forty" ;;        41) echo "forty-one" ;;
    42) echo "forty-two" ;;    43) echo "forty-three" ;;  44) echo "forty-four" ;;
    *)  echo "" ;;
  esac
}
expected=$(word_for "$actual")
[ -n "$expected" ] || { echo "the keyword count is $actual, which this test cannot spell; extend word_for()"; exit 1; }

found=$(grep -ocE "\b$expected keywords\b" "$doc")
if [ "$found" -ne 2 ]; then
  echo "docs/syntax.md should say '$expected keywords' twice -- the opening line and the"
  echo "heading above the list -- but says it $found time(s). The compiler has $actual keywords."
  echo
  grep -niE "\b(twenty|thirty|forty|fifty)(-[a-z]+)? keywords\b" "$doc" | sed 's/^/    /'
  exit 1
fi

echo "docs/syntax.md agrees with the compiler: $expected ($actual) keywords, listed and counted"
