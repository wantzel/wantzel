# No source file outside lib/ carries the name of a standard library module.
#
# A reader who meets `tests/lib/store.wz` next to `lib/store.wz`, or `include "proc.wz"`
# in a directory that holds its own proc.wz, has to know the resolution rule to tell which
# one is meant -- and so does every tool that follows an include. `import store;` and
# `import store;` are different things, but two files with one name still invite
# the wrong one to be opened, edited or copied. So the names are kept apart: a test of a
# module is called <module>_something.wz, an example is named after what it does.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

mods=$(ls lib/*.wz | sed 's|^lib/||')
clash=$(git ls-files '*.wz' | grep -v '^lib/' | while read -r f; do
  b=$(basename "$f")
  if printf '%s\n' "$mods" | grep -qx "$b"; then echo "$f"; fi
done)

if [ -n "$clash" ]; then
  echo "these files have the name of a module in lib/:"
  printf '%s\n' "$clash" | sed 's/^/  /'
  echo
  echo "Rename them (a test of lib/x.wz is named tests/lib/x_something.wz), and update every"
  echo "reference to the old name."
  exit 1
fi
echo "no file outside lib/ is named after a library module ($(printf '%s\n' "$mods" | wc -l) modules)"
