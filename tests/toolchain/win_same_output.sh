# One source, both targets: the ELF and the .exe must print exactly the same thing.
#
# examples/winfacts.wz creates a file, writes it, reads it back, checks it is there,
# deletes it, checks it is gone, and opens a directory -- all through the ordinary library
# calls. On Linux those are syscalls; on Windows they land on kernel32 through the runtime.
# The program does not know which, and that is the property under test.
#
# This is the cheap half of the Windows testing: it needs Wine only to RUN the exe, and it
# catches the case where a platform starts answering differently. The byte comparison in
# win_backend_bytes.sh needs no emulator at all and catches the counterparts drifting apart.
. "$ROOT/tests/helpers.sh"
[ -x "${WINE:-/usr/lib/wine/wine64}" ] || command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || { echo "wine is missing"; exit 1; }

"$ROOT/bin/wantzel" "$ROOT/examples/winfacts.wz" "$T/wf" || { echo "the ELF did not build"; exit 1; }
elf=$(cd "$T" && ./wf)

compile_win "$ROOT/examples/winfacts.wz" "$T/wf.exe"
exe=$(cd "$T" && run_win "$T/wf.exe" 2>/dev/null)

assert_eq "the exe prints what the ELF prints" "$exe" "$elf"
