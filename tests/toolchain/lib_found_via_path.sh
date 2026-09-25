# The compiler finds its own library when it is started through PATH, by its bare name.
#
# WHY THIS TEST EXISTS. The library is read from the compiler's own file, and "its own
# file" used to be taken from argv[0] -- which is not a path but whatever the caller chose
# to say. Started from PATH, argv[0] is the single word "wantzel" with no '/' in it, and
# the compiler looked for its library relative to the working directory instead.
#
# It failed in a perfectly good installation, and only for callers who did the ordinary
# thing: an editor or an agent starts "wantzel", not "/long/path/to/bin/wantzel". Measured
# on 17-09-2026, the same compile succeeded by absolute path and failed through PATH.
#
# The compiler reads /proc/self/exe, which answers where the process really came from.
# Both compiles below run from a directory with nothing of the compiler's near it.
. "$ROOT/tests/helpers.sh"
# helpers.sh has no bad(); without this line every failure below printed "not found" and
# the test passed anyway
bad() { echo "$1"; exit 1; }

mkdir -p "$T/elsewhere"
cat > "$T/elsewhere/hello.wz" <<'WZ'
import io;

begin
  io.puts(STDOUT, "found it\n");
end.
WZ

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
