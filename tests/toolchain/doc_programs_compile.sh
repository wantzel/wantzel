# The complete programs in docs/writing-wantzel.md, docs/library.md and docs/syntax.md
# must compile, and so must the declaration blocks in docs/syntax.md.
#
# A code block that reads as a whole program is there to be COPIED. Someone takes it,
# pastes it, and expects it to work; that is what "a complete program" promises and what
# a fragment does not. A block that does not compile is worse than no block, because the
# reader assumes the fault is theirs.
#
# Three different ways to spot "a whole program" are used below, matching how the
# documents are written:
#   - in docs/writing-wantzel.md, only the blocks under a "### A whole ..." heading are
#     checked; the other code in that file is deliberately fragmentary -- a routine, a
#     loop, a pattern -- and wrapping those in a program would test the wrapper, not the
#     documentation.
#   - in docs/library.md, every fenced pascal block that contains its own "end." line is
#     checked, regardless of heading; the standard-library reference mixes short complete
#     examples with fragments inline, so the heading text is not a reliable marker there.
#   - in docs/syntax.md, the one block with its own "end." line (the "A program" example)
#     is checked as-is; the `var`/`const`/`type` blocks under "Types" and "Declaring" are
#     checked by wrapping each in a minimal `begin end.` -- declarations are exactly where
#     a doc example once carried a type the compiler does not accept (a nested array), and a
#     declaration-only fragment is still meant to be copied into a real program's `var`
#     section, so it must be legal on its own. The other blocks in syntax.md (statements
#     that name undeclared variables, the schema/tools example that references a result
#     type the page never declares, comment/literal listings) are left alone, same as the
#     fragments in writing-wantzel.md -- wrapping them would test the wrapper, not the page.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

doc="$ROOT/docs/writing-wantzel.md"
[ -f "$doc" ] || { echo "docs/writing-wantzel.md is missing"; exit 1; }

# Pull the first pascal block after each "### A whole ..." heading. awk rather than a
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
for pair in "### A whole command-line tool|cli" "### A whole MCP server|mcp"; do
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

echo "$n complete programs from docs/writing-wantzel.md, all compiled and run"

# docs/library.md -- the standard-library reference.  Every fenced pascal block that is a
# COMPLETE program (it has its own "end." line) must compile on its own; a block without
# "end." is a fragment meant to be read in context, not copied whole, and is left alone --
# the same split writing-wantzel.md makes above.
libdoc="$ROOT/docs/library.md"
[ -f "$libdoc" ] || { echo "docs/library.md is missing"; exit 1; }

m=0
blk=0
inblk=0
file=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$inblk" = "1" ]; then
    if [ "$line" = '```' ]; then
      inblk=0
      if grep -q '^end\.$' "$file"; then
        m=$((m + 1))
        out="$T/libdoc_${blk}"
        if ! "$WANTZEL" "$file" "$out" >"$T/cerr" 2>&1; then
          echo "a complete program in docs/library.md (block $blk) does not compile:"
          sed 's/^/    /' "$T/cerr"
          exit 1
        fi
      fi
    else
      printf '%s\n' "$line" >> "$file"
    fi
  elif [ "$line" = '```pascal' ]; then
    blk=$((blk + 1))
    inblk=1
    file="$T/libdoc_${blk}.wz"
    : > "$file"
  fi
done < "$libdoc"

echo "$m complete programs from docs/library.md, all compiled"

# docs/syntax.md -- the form-only reference. One fenced pascal block is a complete
# program (it has "A program" as its heading and its own "end." line); the type/const/var
# blocks under "Types" and "Declaring" are declaration-only fragments, each wrapped here in
# a minimal `begin end.` so it must still be legal on its own -- this is the class of bug
# a doc example once carried a nested array type the compiler refuses.
syndoc="$ROOT/docs/syntax.md"
[ -f "$syndoc" ] || { echo "docs/syntax.md is missing"; exit 1; }

s=0
sblk=0
sinblk=0
sfile=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$sinblk" = "1" ]; then
    if [ "$line" = '```' ]; then
      sinblk=0
      if grep -q '^end\.' "$sfile"; then
        # the one complete program: compile as-is
        s=$((s + 1))
        out="$T/syntaxdoc_${sblk}"
        if ! "$WANTZEL" "$sfile" "$out" >"$T/cerr" 2>&1; then
          echo "the complete program in docs/syntax.md (block $sblk) does not compile:"
          sed 's/^/    /' "$T/cerr"
          exit 1
        fi
      elif grep -qE '^(const|type|var)$' "$sfile"; then
        # a declaration-only fragment: wrap it in a minimal program
        s=$((s + 1))
        wrapped="$T/syntaxdoc_${sblk}_wrapped.wz"
        cat "$sfile" > "$wrapped"
        printf 'begin\nend.\n' >> "$wrapped"
        out="$T/syntaxdoc_${sblk}_wrapped"
        if ! "$WANTZEL" "$wrapped" "$out" >"$T/cerr" 2>&1; then
          echo "a declaration block in docs/syntax.md (block $sblk) does not compile" \
               "when wrapped in 'begin end.':"
          sed 's/^/    /' "$T/cerr"
          exit 1
        fi
      fi
    else
      printf '%s\n' "$line" >> "$sfile"
    fi
  elif [ "$line" = '```pascal' ]; then
    sblk=$((sblk + 1))
    sinblk=1
    sfile="$T/syntaxdoc_${sblk}.wz"
    : > "$sfile"
  fi
done < "$syndoc"

[ "$s" -ge 3 ] || { echo "expected at least 3 checkable blocks in docs/syntax.md, found $s -- has the page changed shape?"; exit 1; }

echo "$s program/declaration blocks from docs/syntax.md, all compiled"
