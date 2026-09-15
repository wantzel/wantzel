# The Windows backend, in the checks that need NO emulator: a .exe target produces a
# PE32+ image, and the C bootstrap and the self-hosted compiler emit the same bytes for
# it.
#
# WHY THIS IS A TEST OF ITS OWN.  Both checks used to live in test-win.sh, behind Wine and
# therefore behind --windows, and the second one is the check that matters most: on
# 14-09-2026 it caught src/wantzel.wz and bootstrap/boot.c drifting apart on the Windows
# side (107 generator lines still emitting { } comments) while everything on Linux was
# identical. Without it that would have shipped in 0.2.0.
#
# It reads bytes and runs cmp. No prefix, no wineserver, no orphan processes, and it costs
# milliseconds -- so it belongs in every --toolchain run rather than behind a flag that is
# off by default.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

compile_win examples/hello.wz "$T/hello.exe"
assert_eq "a .exe target starts with MZ" "$(od -An -tx1 -N2 "$T/hello.exe" | tr -d ' ')" "4d5a"

# the two compilers must agree down to the byte on the Windows target as well
for f in examples/hello.wz examples/cat.wz examples/primes.wz tests/compiler/feat.wz src/wantzel.wz; do
    "$WANTZEL0" "$f" "$T/a.exe" --target=windows 2>"$T/e0" || { echo "wantzel0 could not compile $f to .exe:"; cat "$T/e0"; exit 1; }
    "$WANTZEL"  "$f" "$T/b.exe" --target=windows 2>"$T/e1" || { echo "wantzel could not compile $f to .exe:"; cat "$T/e1"; exit 1; }
    if ! cmp -s "$T/a.exe" "$T/b.exe"; then
        echo "bootstrap/boot.c and src/wantzel.wz emit a DIFFERENT .exe for $f"
        echo "  they are counterparts: the same logic, the same output, on both targets"
        exit 1
    fi
done
echo "PE32+ image and 5 byte-identical .exe pairs (no emulator needed)"
