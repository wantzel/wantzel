# The compiler is ONE FILE: copied alone into an empty directory, it compiles.
#
# THE HISTORY MATTERS FOR WHAT THIS TEST CHECKS. In 0.1.0 the published binary could not
# resolve the standard library at all: it looked for lib/ beside itself, and a downloaded
# file had none. Almost every Wantzel program uses the library, so the download was
# useless for anything real -- and nothing noticed, because the suite always runs inside
# the repository where lib/ is right there. For a while after that the release shipped
# lib/ beside the binary, and a binary copied without it failed the same way.
#
# The library is now part of the compiler file (a trailer after the ELF image; see
# docs/design.md), so there are three properties to hold:
#
#   1. the binary alone, in an empty directory with no lib/ anywhere near it, compiles a
#      program that uses several library modules, and the program runs
#   2. what it produces is byte-identical to what the compiler in the repository produces
#      from the same source: where the compiler sits does not reach the output
#   3. an include naming a path is still read from disk, relative to the includer
#
# Copying into an empty directory is the whole point: it is what a user has after
# downloading the release asset.
. "$ROOT/tests/helpers.sh"

prog() {
  cat <<'WZ'
import io;
import json;
import math;
var n: int;
begin
  // json.wz and math.wz prove that more than one module resolves, and that a module
  // which uses ANOTHER one gets it from the same place.
  n := math.floor(3.7);
  io.puts(STDOUT, "alone ");
  io.putn(STDOUT, n);
  io.puts(STDOUT, "\n");
end.
WZ
}

# ---- 1. the binary alone
mkdir -p "$T/alone"
cp "$WANTZEL" "$T/alone/wantzel"
prog > "$T/alone/p.wz"
[ -e "$T/alone/lib" ] && { echo "the test set itself up wrong: there must be no lib/ here"; exit 1; }

( cd "$T/alone" && ./wantzel p.wz prog ) >"$T/err" 2>&1 || {
  echo "the compiler, copied alone, cannot compile a program that uses the library:"
  sed 's/^/    /' <"$T/err"
  echo
  echo "Is the library trailer missing? ./bin/wantzel --version says; ./build.sh appends it."
  exit 1
}
assert_eq "the compiler alone builds a working program" "$( cd "$T/alone" && ./prog )" "alone 3"

# ---- 2. the same bytes as the compiler in the repository
mkdir -p "$T/repo"
prog > "$T/repo/p.wz"
( cd "$T/repo" && "$WANTZEL" p.wz prog ) 2>"$T/err2" || { echo "the repository compiler failed:"; cat "$T/err2"; exit 1; }
cmp -s "$T/alone/prog" "$T/repo/prog" || {
  echo "the same source compiled by the same compiler in two places gave different bytes;"
  echo "something about where the compiler sits reaches the output"
  exit 1
}

# ---- 3. a path is still read from disk, relative to the includer
mkdir -p "$T/alone/sub"
echo 'const HELPER_MARK = 42;' > "$T/alone/sub/helper.wz"
cat > "$T/alone/q.wz" <<'WZ'
import io;
include "sub/helper.wz";
begin
  io.putn(STDOUT, HELPER_MARK);
  io.puts(STDOUT, "\n");
end.
WZ
( cd "$T/alone" && ./wantzel q.wz q ) >"$T/err3" 2>&1 || {
  echo "an include naming a path no longer reads from disk:"; sed 's/^/    /' <"$T/err3"; exit 1; }
assert_eq "a path still comes from disk" "$( cd "$T/alone" && ./q )" "42"

echo "the compiler alone compiles, and gives the same bytes as the one in the repository"
