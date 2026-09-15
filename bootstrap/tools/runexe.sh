#!/bin/sh
# runexe.sh -- run a Windows .exe under Wine from the command line.
#
# A convenience for testing Wantzel's Windows output on a Linux box: it finds a
# wine64 loader, keeps a throwaway Wine prefix out of your home directory, and
# passes every argument straight through to the program.
#
#   ./runexe.sh bin/hello.exe
#   ./runexe.sh bin/cat.exe examples/hello.wz
#   echo hi | ./runexe.sh bin/cat.exe
#
# Set WINEDEBUG or WINEPREFIX in the environment to override the defaults.
set -e

WINE=${WINE:-$(command -v wine64 || command -v wine || echo /usr/lib/wine/wine64)}
if [ ! -x "$WINE" ]; then
    echo "runexe.sh: no wine loader found; install it with 'sudo apt install wine64'" >&2
    exit 127
fi

if [ $# -lt 1 ]; then
    echo "usage: ./runexe.sh <program.exe> [args...]" >&2
    exit 2
fi

exe=$1
shift
if [ ! -f "$exe" ]; then
    echo "runexe.sh: no such file: $exe" >&2
    exit 1
fi

# A quiet, self-contained prefix so the first run does not spew configuration
# noise and does not touch a real ~/.wine.
export WINEPREFIX=${WINEPREFIX:-$HOME/.wantzel-wine}
export WINEDEBUG=${WINEDEBUG:--all}

# No crash dialog. When a program faults, Wine starts winedbg, which opens a window and
# WAITS -- so an automated run hangs until its timeout and the exit status says nothing
# about the program. Disabling winedbg makes the same failure exit non-zero immediately,
# with the reason on stderr, which is what a test can actually read.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-winedbg.exe=d}

exec "$WINE" "$exe" "$@"
