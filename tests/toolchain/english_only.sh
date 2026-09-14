# The repository is English. A reader who does not know Dutch should never meet it.
#
# This repository was written in Dutch first and translated on 13-09-2026. Translation
# is a one-off; keeping it translated is not, which is what this test is for. It runs
# with --toolchain because it walks the whole tree.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# Common Dutch function words, with word boundaries. A single match is not proof --
# "de" appears in English prose and in identifiers -- so a line counts only when two
# or more hit it. That is the same threshold the wstack scan uses.
#
# "dat" is deliberately not in the list: it is the name of the data segment array in
# both compilers (dat[datlen]), and it would match on every line that touches it.
#
# The list is the weak point, not the threshold: on 14-09-2026 a comment reading
# "past precies: vier tekens in vier" slipped through, because not one of its four
# Dutch words was in it. Words that carry MEANING in a comment -- a count, a unit, a
# verb about fitting or measuring -- are worth more here than function words, because
# that is what a comment is made of. Added below: numbers, sizes, and the verbs that
# turn up in a test comment. Left OUT on purpose: byte, bytes, alle, past, vol, lang,
# acht, weer, zelf -- each is also an ordinary English word (or a substring of one), and
# adding them made this test fail on its own English prose. A word only earns a place
# here if it cannot appear in an English sentence.
NL='\b(de|het|een|van|niet|wordt|worden|moet|moeten|zijn|naar|met|voor|die|deze|geen|alleen|ook|nog|maar|als|dan|bij|uit|over|onder|tussen|draait|bestand|bestanden|regel|regels|fout|fouten|melding|gebruik|zie|wegwerp|hernoeming|precies|teken|tekens|twee|drie|vier|vijf|zes|zeven|negen|tien|elke|dus|omdat|terwijl|zodat|waarde|waarden|lengte|grens|grenzen|leeg|kort|eerste|laatste|nieuwe|oude|klopt|geeft|staat|gaat|komt|hoort|blijft|vangt|telt|leest|schrijft)\b'

hits=$(git ls-files | while read -r f; do
  case "$f" in tests/toolchain/english_only.sh) continue ;; esac
  grep -niE "$NL" "$f" 2>/dev/null | while IFS=: read -r n rest; do
    # Count the distinct Dutch words on the line.
    c=$(printf '%s' "$rest" | grep -oiE "$NL" | wc -l)
    [ "$c" -ge 2 ] && printf '%s:%s: %.100s\n' "$f" "$n" "$rest"
  done
done)

if [ -n "$hits" ]; then
  echo "Dutch found:"
  printf '%s\n' "$hits" | sed 's/^/  /'
  echo
  echo "Every line above has two or more Dutch words. Translate it, or if it is a false"
  echo "positive (an identifier, a code fragment), make the line unambiguous."
  exit 1
fi
echo "no Dutch prose in any tracked file"
