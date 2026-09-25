# The library inside bin/wantzel is lib/ as it is now.
#
# The library is part of the compiler file, packed in by build.sh. Edit lib/io.wz and
# forget to rebuild, and every test of io.wz runs against the OLD io.wz -- green, and about
# code that is no longer there. ./wztest rebuilds when lib/ is newer than the compiler;
# this checks the result by content, not by date: the sha256 that build.sh recorded in the
# trailer (and --version prints) against the same sum taken over lib/ now.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

want=$(sha256sum $(ls lib/*.wz | LC_ALL=C sort) | sha256sum | cut -c1-64)
got=$("$WANTZEL" --version | sed -n 's/.*sha256 \([0-9a-f]*\).*/\1/p')
[ -n "$got" ] || { echo "bin/wantzel --version reports no library sha256:"; "$WANTZEL" --version; exit 1; }
if [ "$got" != "$want" ]; then
  echo "the library in bin/wantzel is not lib/ as it is now:"
  echo "  in the compiler: $got"
  echo "  lib/ now:        $want"
  echo "run ./build.sh -- a test of lib/ would otherwise test the library as it was"
  exit 1
fi
echo "the library in the compiler is lib/ as it is now ($got)"
