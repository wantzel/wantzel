# The editor grammar knows every word the compiler knows.
#
# editors/vscode/syntaxes/wantzel.tmLanguage.json was generated from the keyword table
# in src/wantzel.wz, and that is the only way it stays true: a grammar maintained by
# hand drifts the moment a keyword is added, and nothing notices, because highlighting
# is never wrong in a way that fails a build. A new keyword would simply render as an
# ordinary name -- exactly the confusion highlighting exists to prevent.
#
# This checks the direction that matters: every word the lexer recognises must appear
# somewhere in the grammar. The reverse is allowed, since a grammar may name something
# the compiler handles without a table entry.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

grammar=editors/vscode/syntaxes/wantzel.tmLanguage.json
[ -f "$grammar" ] || { echo "$grammar is missing"; exit 1; }

# The lexer compares against literals through eqt("..."); that list is the language's
# vocabulary as the compiler sees it.
words=$(grep -oE 'eqt\("[a-z0-9]+"\)' src/wantzel.wz | sed 's/eqt("//;s/")//' | sort -u)
[ -n "$words" ] || { echo "no keywords found in src/wantzel.wz -- has eqt() been renamed?"; exit 1; }

missing=""
for w in $words; do
  grep -q "\b$w\b" "$grammar" || missing="$missing $w"
done

if [ -n "$missing" ]; then
  echo "the compiler knows words the grammar does not:"
  for w in $missing; do echo "    $w"; done
  echo
  echo "Add them to editors/vscode/syntaxes/wantzel.tmLanguage.json, under the rule they"
  echo "belong to: keyword.control for flow, keyword.declaration for structure,"
  echo "storage.type for a type, support.function.builtin for something you call."
  exit 1
fi

echo "the grammar covers all $(echo "$words" | wc -w) words the compiler knows"
