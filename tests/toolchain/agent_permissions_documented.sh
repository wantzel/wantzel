# The agent-permissions convention says exactly what a reader implements.
#
# The risk this covers is the one the convention itself warns about: a convention that tools
# implement before it is written down grows dialects. When this test was added, a reader
# already existed and docs/conventions.md said nothing -- so the only description of the
# vocabulary lived in somebody's source.
#
# WHAT IS CHECKED. The page must name the values and no others, and must say where the marker
# is binding. A fourth value in the table means either a reader grew one and the page followed,
# or the page promised something no reader honours -- both worth stopping for.
#
# WHY NOT CHECK A READER. There is none in this repository: the convention is for whoever
# consumes Wantzel source. Checking the page against a fixed vocabulary is what can be done
# here, and it catches the failure that actually happens -- prose drifting.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

doc=docs/conventions.md
[ -f "$doc" ] || { echo "$doc is missing"; exit 1; }

# The section, from its heading up to the next heading at the same level.
sec=$(awk '/^## 4\. `agent-permissions:`/{f=1;print;next} f&&/^## /{exit} f' "$doc")
[ -n "$sec" ] || { echo "$doc has no agent-permissions section"; exit 1; }

# ---- 1. THE VALUES ARE NAMED -------------------------------------------------------------
for v in read none; do
  assert_contains "the convention does not name the value '$v'" "$sec" "\`$v\`"
done

# ---- 2. AND NO FOURTH VALUE CREPT INTO THE TABLE -----------------------------------------
#
# `write` and `delete` were both proposed and both deliberately left out: writing is the
# default, and whoever may write may in practice empty a file. If either turns up as a value
# row, the vocabulary grew without the reasoning being revisited.
if echo "$sec" | grep -qE '^\| *`(write|delete)`'; then
  echo "a fourth value appears in the value table; the convention fixed it at three"
  exit 1
fi

# ---- 3. WHERE IT IS BINDING IS STATED ----------------------------------------------------
#
# Without this the convention is unimplementable: a reader must know whether to scan the whole
# file, and it decides whether two contradictory markers can coexist.
assert_contains "the convention does not say how far into a file the marker is read" \
  "$sec" "512"

# ---- 4. AND AN UNKNOWN VALUE IS HARMLESS -------------------------------------------------
#
# The failure DIRECTION matters more than the values: a typo must restrict nothing. A
# convention where a misspelling locks a file is one people stop using.
assert_contains "the convention does not say what an unrecognised value does" \
  "$sec" "unknown value"

echo "ok: docs/conventions.md fixes the agent-permissions vocabulary"
