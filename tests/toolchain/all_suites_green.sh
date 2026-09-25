# The release gate: the toolchain suite passes -- including the bootstrap fixed point --
# and the spec has no open "planned" items left in section 9.
#
# It used to be called freeze.sh, from when the language was described as frozen. The
# checks are the same and they are what matters: the compiler reproduces itself down to
# the byte, and nothing in the spec is promised but not delivered.
#
# A test switched off by a flag (--bench) must not be started by any other test, this one
# included. Doing that takes the choice away from whoever typed the command.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"
./build.sh >"$T/build.log" 2>&1 || { tail -5 "$T/build.log"; exit 1; }
./test.sh >"$T/test.log" 2>&1 || { tail -15 "$T/test.log"; exit 1; }
n=$(sed -n '/^## 9\. Planned/,/^## 10\./p' docs/language.md | grep -c '^| `')
assert_eq "no planned language items left in docs/language.md section 9" "$n" "0"
# Never skip silently (docs/testing.md): say what this gate did NOT cover and how to get it.
echo "toolchain: $(tail -1 "$T/test.log")"
echo "  not covered here: tests/bench/ -- use ./wztest --bench"
