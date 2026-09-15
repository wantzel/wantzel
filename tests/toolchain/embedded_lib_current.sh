# What the compiler carries is what lib/ says.
#
# src/embedded.wz is generated from lib/ by bootstrap/tools/embedlib.wz. Generated files go stale
# quietly: someone fixes a bug in lib/json.wz, does not rebuild, and the compiler keeps
# handing out the old version to anyone who relies on the embedded copy. Worse, it would
# behave differently depending on whether the user happens to have lib/ on disk.
#
# So this regenerates it into a temporary file and compares. It does not repair anything
# -- that is build.sh's job, and a test that silently fixes what it checks is no test.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

[ -f src/embedded.wz ] || { echo "src/embedded.wz is missing; run ./build.sh"; exit 1; }

compile bootstrap/tools/embedlib.wz "$T/embedlib"

set --
for f in lib/*.wz; do set -- "$@" "$(basename "$f")" "$f"; done
"$T/embedlib" "$T/fresh.wz" "$@" >/dev/null || { echo "the generator failed"; exit 1; }

if cmp -s src/embedded.wz "$T/fresh.wz"; then
  echo "src/embedded.wz matches lib/ ($(ls lib/*.wz | wc -l) files, $(cat lib/*.wz | wc -c) bytes)"
  exit 0
fi

echo "src/embedded.wz is out of date: it no longer matches lib/."
echo
echo "    Run ./build.sh. That regenerates it; there is nothing to commit, because"
echo "    src/embedded.wz is generated and .gitignore keeps it out of the repository."
echo
cmp src/embedded.wz "$T/fresh.wz" | sed 's/^/    /'
echo
# WHY THIS MESSAGE SAYS SO MUCH: a stale copy makes this test fail AND
# tests/compiler/schema.wz fail, and neither failure mentions lib/ or embedded.wz. That
# once cost a full investigation: two tests red, both green in isolation, and a second
# full run green once build.sh had run for another reason. The pattern "fails in
# the suite, passes alone, passes on a re-run" is also the signature of a real flake, so
# the cause has to be in the message or it will be mistaken for one.
echo "    A stale copy also fails tests/compiler/schema.wz, and that failure names"
echo "    neither lib/ nor embedded.wz. If you see both red, run ./build.sh first."
exit 1
