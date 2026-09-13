# What the compiler carries is what lib/ says.
#
# src/embedded.wz is generated from lib/ by tools/embedlib.wz. Generated files go stale
# quietly: someone fixes a bug in lib/json.wz, does not rebuild, and the compiler keeps
# handing out the old version to anyone who relies on the embedded copy. Worse, it would
# behave differently depending on whether the user happens to have lib/ on disk.
#
# So this regenerates it into a temporary file and compares. It does not repair anything
# -- that is build.sh's job, and a test that silently fixes what it checks is no test.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

[ -f src/embedded.wz ] || { echo "src/embedded.wz is missing; run ./build.sh"; exit 1; }

compile tools/embedlib.wz "$T/embedlib"

set --
for f in lib/*.wz; do set -- "$@" "$(basename "$f")" "$f"; done
"$T/embedlib" "$T/fresh.wz" "$@" >/dev/null || { echo "the generator failed"; exit 1; }

if cmp -s src/embedded.wz "$T/fresh.wz"; then
  echo "src/embedded.wz matches lib/ ($(ls lib/*.wz | wc -l) files, $(cat lib/*.wz | wc -c) bytes)"
  exit 0
fi

echo "src/embedded.wz no longer matches lib/:"
cmp src/embedded.wz "$T/fresh.wz" | sed 's/^/    /'
echo
echo "Run ./build.sh and commit the regenerated src/embedded.wz in the same commit as"
echo "the change to lib/ -- otherwise a downloaded compiler ships a different library"
echo "than the repository shows."
exit 1
