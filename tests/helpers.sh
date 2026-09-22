# helpers.sh -- what a .sh test needs on the LANGUAGE side.
#
# Deliberately small: this suite tests the language and the compiler, not an application.
# There is no server to start and no port to lease; an application written in Wantzel
# brings helpers like that itself. The compiler runs its tests without anything external.
#
# wztest exports WANTZEL, WANTZEL0 and ROOT, and points $T at a clean temporary
# directory for each test.

# compile <source> <output> -- compiles, or stops the test with the compile error
compile() { "$WANTZEL" "$1" "$2" 2>"$T/cerr" || { echo "compile error in $1:"; cat "$T/cerr"; exit 1; }; }

# compile_win <source> <output.exe> -- the same, for the Windows target.
# The target is ALWAYS passed: an output name ending in .exe no longer selects Windows on
# its own, and is refused without --target.
compile_win() { "$WANTZEL" "$1" "$2" --target=windows 2>"$T/cerr" || { echo "Windows compile error in $1:"; cat "$T/cerr"; exit 1; }; }

# run_win <program.exe> [args...] -- run a Windows binary under Wine.
#
# IT LIVES HERE AND NOT IN A SCRIPT OF ITS OWN. This was tools/runexe.sh until
# 16-09-2026; the tests already source this file, so a separate script was one more thing
# to find and one more path to keep in step across three repositories.
#
# FOUR SETTINGS, AND THREE OF THEM WERE LEARNED THE HARD WAY. Anyone writing the next
# Windows test gets them by calling this instead of calling wine directly:
#
#   WINEDLLOVERRIDES=winedbg.exe=d   NO CRASH DIALOG. When a program faults, Wine starts
#       winedbg, which opens a WINDOW and waits. An automated run then hangs until its
#       timeout and the exit status says nothing about the program. Measured on
#       15-09-2026: win_getprocaddress.sh "failed" with exit 124 on a
#       timeout, and the real fault was invisible without someone watching the screen.
#       With winedbg disabled the same fault exits non-zero at once, reason on stderr.
#   WINEPREFIX=~/.wantzel-wine       A prefix is a whole fake Windows installation.
#       Sharing the user's means this suite can change settings under a program they care
#       about; a throwaway one costs disk and nothing else.
#   WINEDEBUG=-all                   Otherwise the first run in a fresh prefix writes
#       configuration noise to stderr, which lands in the middle of what a test asserts.
#   the loader search                On Debian/Ubuntu there is no `wine64` on PATH when
#       only the wrapper is installed, so /usr/lib/wine/wine64 is tried too.
#
# Every variable can still be overridden from the environment, for a session where you
# DO want the debugger.
run_win() {
    _wine=${WINE:-$(command -v wine64 || command -v wine || echo /usr/lib/wine/wine64)}
    if [ ! -x "$_wine" ]; then
        echo "run_win: no wine loader found; install it with 'sudo apt install wine64'" >&2
        return 127
    fi
    [ -f "$1" ] || { echo "run_win: no such file: $1" >&2; return 1; }
    WINEPREFIX=${WINEPREFIX:-$HOME/.wantzel-wine}     WINEDEBUG=${WINEDEBUG:--all}     WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-winedbg.exe=d}     "$_wine" "$@"
}

# assert_eq <name> <got> <expected>
assert_eq() { if [ "$2" != "$3" ]; then echo "$1"; echo "  expected: $3"; echo "  got:      $2"; exit 1; fi; }

# assert_contains <name> <text> <substring>
assert_contains() { case "$2" in *"$3"*) ;; *) echo "$1"; echo "  does not contain: $3"; echo "  text: $2"; exit 1 ;; esac; }

# bench_report <name> <value> <unit> -- a measurement line; a <name>.min or <name>.max
# beside the test turns it into a hard limit.
bench_report() { printf 'bench %s %s %s\n' "$1" "$2" "$3"; }
