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

# assert_eq <name> <got> <expected>
assert_eq() { if [ "$2" != "$3" ]; then echo "$1"; echo "  expected: $3"; echo "  got:      $2"; exit 1; fi; }

# assert_contains <name> <text> <substring>
assert_contains() { case "$2" in *"$3"*) ;; *) echo "$1"; echo "  does not contain: $3"; echo "  text: $2"; exit 1 ;; esac; }

# bench_report <name> <value> <unit> -- a measurement line; a <name>.min or <name>.max
# beside the test turns it into a hard limit.
bench_report() { printf 'bench %s %s %s\n' "$1" "$2" "$3"; }
