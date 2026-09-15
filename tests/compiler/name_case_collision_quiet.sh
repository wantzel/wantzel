# A collision between two names spelled the SAME way must NOT get the case explanation.
#
# The compiler adds "; names are case-insensitive, so X is the same name as x" to every
# already-taken message. That helps only where the spellings differ; on a plain duplicate
# it explains something that is not happening, which is worse than saying less.
#
# This is a .sh test and not a .err one because .err matches a SUBSTRING: a test asserting
# "duplicate declaration" would pass even with the extra sentence appended. What has to be
# checked here is an ABSENCE, and only a script can do that.
. "$ROOT/tests/helpers.sh"

cat > "$T/same.wz" <<'WZ'
include "store.wz";
const
  store.set = 1;
begin
end.
WZ

"$WANTZEL" "$T/same.wz" "$T/out.bin" >"$T/cerr" 2>&1 && {
  echo "the program compiled, but store.set is already a routine in lib/store.wz"; exit 1; }

assert_contains "a plain duplicate is still reported" "$(cat "$T/cerr")" "duplicate declaration"

if grep -q "case-insensitive" "$T/cerr"; then
  echo "the case explanation appeared on a collision with no capitals in it:"
  sed 's/^/  /' "$T/cerr"
  exit 1
fi
echo "a same-case duplicate is reported without the case explanation"
