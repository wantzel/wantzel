# The editor grammar knows every word the compiler knows.
#
# editors/vscode/syntaxes/wantzel.tmLanguage.json was generated from the keyword table
# in $WZSRC, and that is the only way it stays true: a grammar maintained by
# hand drifts the moment a keyword is added, and nothing notices, because highlighting
# is never wrong in a way that fails a build. A new keyword would simply render as an
# ordinary name -- exactly the confusion highlighting exists to prevent.
#
# This checks the direction that matters: every word the lexer recognises must appear
# somewhere in the grammar. The reverse is allowed, since a grammar may name something
# the compiler handles without a table entry.
# THE COMPILER IS TWO FILES SINCE 17-09-2026: compiler.wz holds everything and has no
# main program, so it can be included; wantzel.wz is the command-line program around it
# A scan that reads only one of them finds nothing and reports a rename
# that never happened -- which is exactly what this test said when the split landed.
#
# AND THE GREPS NEED -h: over TWO files grep prefixes every match with the filename,
# so the word list became src/compiler.wz:array instead of array, and every keyword
# looked unknown to the grammar.
WZSRC="src/compiler.wz src/wantzel.wz"

. "$ROOT/tests/helpers.sh"
cd "$ROOT"

grammar=editors/vscode/syntaxes/wantzel.tmLanguage.json
[ -f "$grammar" ] || { echo "$grammar is missing"; exit 1; }

# The lexer compares against literals through eqt("..."); that list is the language's
# vocabulary as the compiler sees it.
words=$(grep -hoE 'eqt\("[a-z0-9]+"\)' $WZSRC | sed 's/eqt("//;s/")//' | sort -u)
[ -n "$words" ] || { echo "no keywords found in $WZSRC -- has eqt() been renamed?"; exit 1; }

# A word the compiler names only to refuse it is not vocabulary. Those are the ones whose
# message says the construct is no longer part of the language; the grammar must not
# colour them either, or an editor would keep suggesting a form the compiler rejects.
refused=$(grep -hoE "'[a-z]+[^']*' (header )?is no longer part of the language" $WZSRC | grep -hoE "^'[a-z]+" | tr -d "'" | sort -u)
for r in $refused; do
  words=$(echo "$words" | grep -vx "$r")
  if grep -qE "[|(]$r[|)]" "$grammar"; then
    echo "the grammar still highlights '$r', which the compiler refuses; remove it from $grammar"
    exit 1
  fi
done

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
