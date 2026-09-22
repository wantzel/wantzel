# --update must regenerate .err files, not only .out files.
#
# WHY THIS IS WORTH A TEST OF ITS OWN. An .err file holds an expected compiler error, and
# an error message contains a line number by definition -- that is what the test is
# checking. So an .err file is the kind that shifts on EVERY language change that adds or
# removes a line, and it is exactly the kind you least want to update by hand: copying new
# output without reading it turns the test into a record of what the compiler does rather
# than a statement of what it should do.
#
# --update covered .out and silently skipped .err, which was an arbitrary difference. It
# was found the hard way: removing one keyword shifted 126 files, --update fixed 60 .out
# files in one go, and then three .err tests still failed and had to be done by hand.
#
# THE CHECK IS A ROUND TRIP, because that is the only thing that proves the feature rather
# than its presence: break an .err on purpose, confirm the suite fails, run --update,
# confirm the suite passes AND the file is byte-identical to what it was. The last part is
# what catches an --update that "works" by writing something subtly different -- the
# "wantzel: " prefix, say, which would still pass the substring comparison while quietly
# making every one of these a test of the prefix too.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

t=tests/compiler/forward_unresolved_named
[ -f "$t.err" ] || { echo "$t.err is missing; this test needs an .err test to work on"; exit 1; }

saved=$(mktemp); cp "$t.err" "$saved"
# PUT IT BACK WHATEVER HAPPENS. A failure here must not leave the repository with a
# damaged expected-output file, which would fail every later run for the wrong reason.
trap 'cp "$saved" "$t.err"; rm -f "$saved"' EXIT

printf 'nonsense that cannot match:9999\n' > "$t.err"
if ./wztest "$t.wz" >/dev/null 2>&1; then
  echo "a deliberately wrong .err still passed -- the comparison is not doing anything"
  exit 1
fi

./wztest --update "$t.wz" >/dev/null 2>&1

if ! ./wztest "$t.wz" >/dev/null 2>&1; then
  echo "--update did not repair the .err file: the test still fails after updating"
  exit 1
fi

if ! cmp -s "$saved" "$t.err"; then
  echo "--update wrote something different from the original .err:"
  diff -u "$saved" "$t.err" | sed 's/^/  /'
  exit 1
fi

echo "--update regenerates an .err file byte for byte"
