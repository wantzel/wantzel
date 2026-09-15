# The complete programs in docs/writing-wantzel.md must compile and run.
#
# Those two -- a command-line tool and an MCP server -- are there to be COPIED. Someone
# takes the whole block, pastes it, and expects it to work; that is what "a complete
# program" promises and what a fragment does not. A block that does not compile is worse
# than no block, because the reader assumes the fault is theirs.
#
# Only the blocks under a "## A whole ..." heading are checked. The other code in that
# file is deliberately fragmentary -- a routine, a loop, a pattern -- and wrapping those
# in a program would test the wrapper.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

doc="$ROOT/docs/writing-wantzel.md"
[ -f "$doc" ] || { echo "docs/writing-wantzel.md is missing"; exit 1; }

# Pull the first pascal block after each "## A whole ..." heading. awk rather than a
# parser: the format is two markers and the text between them.
extract() {   # <heading>
  awk -v want="$1" '
    $0 == want { found = 1; next }
    found && /^```pascal$/ { inblk = 1; next }
    inblk && /^```$/ { exit }
    inblk { print }
  ' "$doc"
}

# heading|name, so the file name is chosen here rather than derived from the heading --
# deriving it made the name depend on punctuation, which is not the thing under test.
n=0
for pair in "## A whole command-line tool|cli" "## A whole MCP server|mcp"; do
  h=${pair%|*}
  name=${pair#*|}
  extract "$h" > "$T/$name.wz"
  [ -s "$T/$name.wz" ] || { echo "no pascal block found under: $h"; exit 1; }
  if ! "$WANTZEL" "$T/$name.wz" "$T/$name" >"$T/cerr" 2>&1; then
    echo "the program under '$h' does not compile:"
    sed 's/^/    /' "$T/cerr"
    exit 1
  fi
  n=$((n + 1))
done

# and they must DO what the text says they do, not merely compile
printf 'a\nb\nc\n' > "$T/three.txt"
assert_eq "the command-line tool counts lines and bytes" \
  "$("$T/cli" "$T/three.txt")" "3 lines, 6 bytes"
"$T/cli" >"$T/u" 2>&1 && { echo "it should refuse with no argument"; exit 1; }
assert_contains "and says how to use it" "$(cat "$T/u")" "usage:"

out=$(printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23}}}' | "$T/mcp" 2>&1)
assert_contains "the MCP server adds two numbers" "$out" '"sum":42'

echo "$n complete programs from the documentation, all compiled and run"
