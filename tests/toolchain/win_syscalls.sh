# The storage system calls behave the same in a Windows executable (under Wine) as in the ELF.
. "$ROOT/tests/helpers.sh"
[ -x "${WINE:-/usr/lib/wine/wine64}" ] || command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || { echo "wine is missing"; exit 1; }
compile_win "$ROOT/tests/compiler/syscalls_storage.wz" "$T/sc.exe"
got=$(cd "$T" && "$ROOT/bootstrap/tools/runexe.sh" "$T/sc.exe" 2>/dev/null)
want=$(cat "$ROOT/tests/compiler/syscalls_storage.out")
assert_eq "windows storage syscalls" "$got" "$want"
