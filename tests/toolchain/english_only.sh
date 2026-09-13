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
NL='\b(de|het|een|van|niet|wordt|worden|moet|moeten|zijn|naar|met|voor|die|deze|geen|alleen|ook|nog|maar|als|dan|bij|uit|over|onder|tussen|draait|bestand|bestanden|regel|regels|fout|fouten|melding|gebruik|zie|wegwerp|hernoeming)\b'

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
