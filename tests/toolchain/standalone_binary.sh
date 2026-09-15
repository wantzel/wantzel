# The compiler works on its own, with nothing beside it.
#
# This is the test that would have caught the gap in 0.1.0: the published binary could
# not resolve include "io.wz", because setlibdir derives the library path from argv[0]
# and a downloaded file has no lib/ next to it. Almost every Wantzel program starts with
# an include, so the download was useless for anything real -- and nothing noticed,
# because the suite always runs inside the repository where lib/ is right there.
#
# Copying the compiler into an empty directory is the whole point: it reproduces what a
# user has after clicking a release asset.
. "$ROOT/tests/helpers.sh"

mkdir -p "$T/alone"
cp "$WANTZEL" "$T/alone/wantzel"

cat > "$T/alone/p.wz" <<'EOF'
program standalone;
include "io.wz";
include "json.wz";
include "math.wz";
var n: int;
begin
  // json.wz and math.wz are included to prove more than one embedded file resolves,
  // and that a library file including another one works from the table too.
  n := math.floor(3.7);
  io.puts(STDOUT, "alone ");
  io.putn(STDOUT, n);
  io.puts(STDOUT, "\n");
end.
EOF

( cd "$T/alone" && ./wantzel p.wz prog ) >"$T/err" 2>&1 || {
  echo "the compiler cannot compile against its own library when alone:"
  sed 's/^/    /' <"$T/err"
  echo
  echo "The library is carried inside the binary by src/embedded.wz; check that"
  echo "build.sh regenerated it and that emb.fill is still called at startup."
  exit 1
}

got=$( cd "$T/alone" && ./prog )
assert_eq "a standalone compiler builds a working program" "$got" "alone 3"

# A path must still be read from disk: only a bare library name falls back to the
# embedded copy, or a user could never override anything.
mkdir -p "$T/alone/sub"
cat > "$T/alone/sub/helper.wz" <<'EOF'
const HELPER_MARK = 42;
EOF
cat > "$T/alone/q.wz" <<'EOF'
program pathinclude;
include "io.wz";
include "sub/helper.wz";
begin
  io.putn(STDOUT, HELPER_MARK);
  io.puts(STDOUT, "\n");
end.
EOF
( cd "$T/alone" && ./wantzel q.wz q ) >"$T/err2" 2>&1 || {
  echo "an include naming a path no longer reads from disk:"; sed 's/^/    /' <"$T/err2"; exit 1; }
assert_eq "a path still comes from disk" "$( cd "$T/alone" && ./q )" "42"

echo "a compiler alone in an empty directory compiles against its own library"
