# The release gate: the toolchain suite, the Windows suite and the byte comparison
# between boot.c and the self-hosted compiler all pass, and the spec has no open
# "planned" items left in section 9.
#
# It used to be called freeze.sh, from when the language was described as frozen. The
# checks are the same and they are what matters: the two compilers agree down to the
# byte, on both targets, and nothing in the spec is promised but not delivered.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"
./build.sh >"$T/build.log" 2>&1 || { tail -5 "$T/build.log"; exit 1; }
./test.sh >"$T/test.log" 2>&1 || { tail -15 "$T/test.log"; exit 1; }
./test-win.sh >"$T/win.log" 2>&1 || { tail -15 "$T/win.log"; exit 1; }
n=$(sed -n '/^## 9\. Planned/,/^## 10\./p' docs/language.md | grep -c '^| `')
assert_eq "no planned language items left in docs/language.md section 9" "$n" "0"
echo "toolchain: $(tail -1 "$T/test.log"); windows: $(tail -1 "$T/win.log")"
