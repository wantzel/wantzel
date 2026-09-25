# Every program in examples/ compiles.
#
# The examples are the first Wantzel most people read, and a broken one is worse
# than a missing one: it teaches a form that does not work. Nothing guarded them
# until 13-09-2026, because the suite only ever looked inside tests/.
#
# This checks that they COMPILE, not what they do -- most of them want a socket, a
# terminal or an MCP client to do anything, and a test that needs those would be
# testing the network rather than the language. Behaviour is covered by tests/lib.
. "$ROOT/tests/helpers.sh"

fails=0
for f in "$ROOT"/examples/*.wz; do
  name=$(basename "$f")
  if ! "$WANTZEL" "$f" "$T/prog" >"$T/err" 2>&1; then
    printf '  %s does not compile:\n' "$name"; sed 's/^/    /' <"$T/err"; fails=$((fails+1)); continue
  fi
done

[ $fails -eq 0 ] || { echo "$fails example(s) failed"; exit 1; }
echo "all examples compile"
