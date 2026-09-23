# wztest must not report success for a test it could not find.
#
# THE BUG THIS GUARDS. `wztest nosuchtest` printed "wztest: nosuchtest does not exist" to
# stderr, dropped it, and reported "0 passed, 0 failed" with exit 0. A green answer for
# something that never ran.
#
# HOW IT SURFACED, which is the part worth keeping: a ticket in ANOTHER project named a test
# here and closed GREEN while that test had been deliberately broken. Two things were wrong
# at once -- the name arrived in a form this runner could not resolve, and the runner said
# nothing about that in its exit code. Fixing either one alone would have made it visible.
#
# WHY THIS TEST RATHER THAN A CODE COMMENT. A runner that lies about what it ran is the one
# failure that hides every other failure, so it is the last place to rely on someone
# remembering. It is also the cheapest thing in this suite to check.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

cd "$here"

# ---- A NAME THAT DOES NOT EXIST MUST FAIL ------------------------------------------------
out=$(./wztest tests/lib/this_test_does_not_exist.sh 2>&1) && rc=0 || rc=$?
if [ "$rc" != "0" ]; then
  ok "a named test that cannot be found makes wztest fail (exit $rc)"
else
  bad "wztest reported success for a test it never found" \
      "a runner that lies about what it ran hides every other failure" \
      "$(echo "$out" | tail -3)"
fi
case "$out" in
  *"does not exist"*) ok "and it says which name it could not find" ;;
  *) bad "the failure does not name the missing test" "$(echo "$out" | tail -2)" ;;
esac

# ---- AND A TEST THAT DOES EXIST MUST STILL PASS -------------------------------------------
#
# Without this the check above is satisfied by a runner that fails at everything, which
# would be a worse bug than the one being guarded.
if ./wztest tests/lib/json_pretty.wz >/dev/null 2>&1; then
  ok "and a test that does exist still passes"
else
  bad "wztest now fails on a test that is present" \
      "the guard is too strict: it refuses work it should do"
fi

# A DIRECTORY THAT DOES NOT EXIST IS THE SAME MISTAKE, one level up -- and is how a typo in
# a path reaches this runner.
./wztest tests/nosuchdir >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" != "0" ]; then ok "a directory that does not exist fails as well"
else bad "a missing directory was passed over in silence"; fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
