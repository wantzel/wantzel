# The release gate: the toolchain suite and the byte comparison between boot.c and the
# self-hosted compiler pass, and the spec has no open "planned" items left in section 9.
#
# It used to be called freeze.sh, from when the language was described as frozen. The
# checks are the same and they are what matters: the two compilers agree down to the
# byte, and nothing in the spec is promised but not delivered.
#
# THIS SCRIPT DOES NOT RUN test-win.sh, AND THAT IS THE POINT.  It used to,
# unconditionally, which made --windows meaningless: the flag exists so a working run
# does not pay for Wine (19 of 40 seconds), and calling the Windows script from here
# walked straight around it. Measured 15-09-2026: Wine ran about ten times in one evening
# without anyone typing --windows, leaving 29 orphan processes -- wineserver64 and
# winedevice.exe, the oldest nearly an hour old.
#
# The rule that follows is wider than this script: a test switched off by a flag must not
# be started by any other test. Doing that takes the choice away from whoever typed the
# command.
#
# What did survive from that script is the check that actually caught something: the
# byte comparison of the .exe files, which needs no emulator at all. It sits in
# tests/toolchain/win_backend_bytes.sh and runs in every --toolchain run.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"
./build.sh >"$T/build.log" 2>&1 || { tail -5 "$T/build.log"; exit 1; }
./test.sh >"$T/test.log" 2>&1 || { tail -15 "$T/test.log"; exit 1; }
n=$(sed -n '/^## 9\. Planned/,/^## 10\./p' docs/language.md | grep -c '^| `')
assert_eq "no planned language items left in docs/language.md section 9" "$n" "0"
# Never skip silently (docs/testing.md): say what this gate did NOT cover and how to get it.
echo "toolchain: $(tail -1 "$T/test.log")"
echo "  not covered here: running a .exe under Wine -- use ./wztest --toolchain --windows"
