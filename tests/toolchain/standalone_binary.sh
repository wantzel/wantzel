# The compiler works outside the repository -- with lib/ beside it, and says so without it.
#
# THE HISTORY MATTERS FOR WHAT THIS TEST CHECKS. In 0.1.0 the published binary could not
# resolve include "io.wz" at all: setlibdir derives the library path from argv[0], and a
# downloaded file had no lib/ next to it. Almost every Wantzel program starts with an
# include, so the download was useless for anything real -- and nothing noticed, because
# the suite always runs inside the repository where lib/ is right there.
#
# That was first fixed by carrying lib/ INSIDE the compiler. On 16-09-2026 that came back
# out: it cost a generated 238KB source, a permanent difference between the
# two counterparts, no way to tell which copy answered an include, and no source on disk
# for an editor or debugger to show. The release ships lib/ beside the binary instead.
#
# So there are now TWO properties to hold, and the second is the one that used to be the
# silent failure:
#
#   1. binary + lib/ in an empty directory compiles a program that includes the library
#   2. binary WITHOUT lib/ refuses, naming the file it could not find
#
# Copying into an empty directory is the whole point: it reproduces what a user has after
# unpacking a release asset.
. "$ROOT/tests/helpers.sh"

prog() {
  cat <<'EOF'
include "io.wz";
include "json.wz";
include "math.wz";
var n: int;
begin
  // json.wz and math.wz prove that more than one library file resolves, and that a
  // library file including ANOTHER one works from the same search path.
  n := math.floor(3.7);
  io.puts(STDOUT, "alone ");
  io.putn(STDOUT, n);
  io.puts(STDOUT, "\n");
end.
EOF
}

# ---- 1. with lib/ beside it, the way a release is unpacked
mkdir -p "$T/alone/lib"
cp "$WANTZEL" "$T/alone/wantzel"
cp "$ROOT"/lib/*.wz "$T/alone/lib/"
prog > "$T/alone/p.wz"

( cd "$T/alone" && ./wantzel p.wz prog ) >"$T/err" 2>&1 || {
  echo "the compiler cannot compile against lib/ beside it:"
  sed 's/^/    /' <"$T/err"
  echo
  echo "setlibdir derives <dir of argv[0]>/lib/; check that a release ships lib/."
  exit 1
}
assert_eq "a compiler with lib/ beside it builds a working program" \
          "$( cd "$T/alone" && ./prog )" "alone 3"

# ---- 2. without lib/, it REFUSES and names the file
#
# This is the case that shipped broken in 0.1.0. An unhelpful failure here is as bad as a
# wrong answer: someone who unpacked only the binary must learn what is missing, not read
# "undeclared identifier: io.puts" and go looking in their own code.
mkdir -p "$T/nolib"
cp "$WANTZEL" "$T/nolib/wantzel"
prog > "$T/nolib/p.wz"
if ( cd "$T/nolib" && ./wantzel p.wz prog ) >"$T/err2" 2>&1; then
  echo "a compiler with no lib/ beside it compiled a program that includes io.wz;"
  echo "it has no library to resolve that against, so this cannot be right"
  exit 1
fi
grep -q "io.wz" "$T/err2" || {
  echo "the failure without lib/ does not name io.wz, so it does not say what is missing:"
  sed 's/^/    /' <"$T/err2"
  exit 1
}
printf '  without lib/ it refuses and names the file\n'

# ---- 3. a path is still read relative to the includer, not from the search path
mkdir -p "$T/alone/sub"
echo 'const HELPER_MARK = 42;' > "$T/alone/sub/helper.wz"
cat > "$T/alone/q.wz" <<'EOF'
include "io.wz";
include "sub/helper.wz";
begin
  io.putn(STDOUT, HELPER_MARK);
  io.puts(STDOUT, "\n");
end.
EOF
( cd "$T/alone" && ./wantzel q.wz q ) >"$T/err3" 2>&1 || {
  echo "an include naming a path no longer reads from disk:"; sed 's/^/    /' <"$T/err3"; exit 1; }
assert_eq "a path still comes from disk" "$( cd "$T/alone" && ./q )" "42"

echo "a compiler with lib/ beside it compiles; without it, it says what is missing"
