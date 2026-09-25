# The compiler must find its own lib/ when it is started through PATH, by its bare name.
#
# WHY THIS TEST EXISTS. The search path for a bare include name is anchored on the
# compiler's own location, and that location used to be taken from argv[0] -- which is not
# a path but whatever the caller chose to say. Started from PATH, argv[0] is the single
# word "wantzel" with no '/' in it, so the anchor collapsed to a RELATIVE "lib/" and
# `include "io.wz"` then depended on the working directory.
#
# It failed in a perfectly good installation, and only for callers who did the ordinary
# thing: an editor or an agent starts "wantzel", not "/long/path/to/bin/wantzel". Measured
# on 17-09-2026, the same compile succeeded by absolute path and failed through PATH.
#
# The anchor is /proc/self/exe now, which answers where the process really came from.
# argv[0] is still the fallback for a system without /proc.
#
# THE WORKING DIRECTORY IS THE TRAP THIS GUARDS. Both compiles below run from a directory
# with no lib/ in it and no lib/ above it, because that is the only way to tell the two
# anchors apart: with a lib/ next to the source, a relative "lib/" would find it and the
# bug would hide.
. "$ROOT/tests/helpers.sh"

mkdir -p "$T/elsewhere"
cat > "$T/elsewhere/hello.wz" <<'WZ'
include "io.wz";

begin
  io.puts(STDOUT, "found it\n");
end.
WZ

# No lib/ here, and none in any parent of it.
[ -d "$T/elsewhere/lib" ] && bad "the test set itself up wrong: lib/ must not be beside the source"

# 1. through PATH, by the bare name -- the case that used to fail
( cd "$T/elsewhere" && PATH="$(dirname "$WANTZEL"):$PATH" wantzel hello.wz "$T/via_path" ) \
  2>"$T/path.err" || bad "bare 'wantzel' from PATH could not compile: $(cat "$T/path.err")"
assert_eq "the program built through PATH runs" "$("$T/via_path")" "found it"

# 2. by absolute path, which has always worked and must keep working
( cd "$T/elsewhere" && "$WANTZEL" hello.wz "$T/via_abs" ) \
  2>"$T/abs.err" || bad "absolute path could not compile: $(cat "$T/abs.err")"
assert_eq "the program built by absolute path runs" "$("$T/via_abs")" "found it"

# 3. and both roads give the SAME bytes: the anchor may not change the output
cmp -s "$T/via_path" "$T/via_abs" \
  || bad "the same source gave different binaries through PATH and by absolute path"
