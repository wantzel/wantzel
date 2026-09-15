# Every snippet the VS Code extension offers must actually compile.
#
# A snippet is an instruction: someone types its prefix and gets code they did not write
# and will not read closely. One that does not compile is worse than none, because the
# reader assumes the fault is theirs. Two of the first nine here did not: the tools
# snippet was missing its json.wz include, and the buffer snippet put a var block and a
# statement in one place, which cannot occur together.
#
# The extractor is tests/toolchain/progs/snipex.wz, in Wantzel -- tooling in this
# repository is written in the language, and sed was the wrong tool anyway: an attempt
# with it returned the whole JSON file as one line and the test failed on an error that
# came from the extractor rather than from any snippet.
#
# It resolves the placeholders the way an editor fills them when you tab straight
# through: ${1:name} becomes name and a bare $0 vanishes. So what is compiled below is
# what a user gets by accepting a snippet unchanged.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

snip="$ROOT/editors/vscode/snippets/wantzel.json"
[ -f "$snip" ] || { echo "the snippet file is missing: $snip"; exit 1; }

compile "$ROOT/tests/toolchain/progs/snipex.wz" "$T/snipex"
get() { "$T/snipex" "$snip" "$1" || { echo "could not read the '$1' snippet"; exit 1; }; }

try() {   # <name> <file>
  if ! "$WANTZEL" "$2" "$T/snip.bin" >"$T/cerr" 2>&1; then
    echo "the '$1' snippet does not compile:"
    sed 's/^/    /' "$T/cerr"
    echo "  what was compiled:"
    sed 's/^/    /' "$2"
    exit 1
  fi
}

# Which wrapper turns a fragment into a program is part of knowing whether the snippet is
# right, so the wrappers are written out rather than generated. A generic one would be
# testing the wrapper.

get main > "$T/main.wz"
try main "$T/main.wz"

for r in procedure function; do
  { echo 'include "io.wz";'; get "$r"; echo 'begin end.'; } > "$T/$r.wz"
  try "$r" "$T/$r.wz"
done

# these two bring their own includes
for r in schema tools; do
  { get "$r"; echo 'begin end.'; } > "$T/$r.wz"
  try "$r" "$T/$r.wz"
done

# the declaration and statement fragments, each in the place it belongs
{ echo 'include "io.wz";'; echo 'var'
  get buffer
  echo '  i, n, fd: int;'
  echo '  path: array[0..63] of char;'
  echo 'begin'
  get for      | sed 's/^/  /'
  get while    | sed 's/condition/n > 0/;s/^/  /'
  get readfile | sed 's/^/  /'
  echo 'end.'; } > "$T/body.wz"
try "buffer/for/while/readfile" "$T/body.wz"

# The fragments that came out of the error log: each one exists because it
# prevents a mistake that has actually been made and written down, which is the rule for
# what earns a place here.
{ echo 'include "kv.wz";'; echo 'var'
  echo '  buf, dst, keybuf: array[0..255] of char;'
  echo '  n, keyn, textn: int;'
  echo 'begin'
  get jsontext | sed 's/^/  /'
  echo 'end.'; } > "$T/jsontext.wz"
try jsontext "$T/jsontext.wz"

{ echo 'include "io.wz";'
  get growing | sed -n '/^var$/,$p' | sed -n '1,4p'
  echo '  value: int;'
  echo 'begin'
  get growing | sed -n '/^if /,$p' | sed 's/^/  /'
  echo 'end.'; } > "$T/growing.wz"
try growing "$T/growing.wz"

{ echo 'include "fs.wz";'; echo 'var'
  echo '  path: array[0..255] of char;'
  echo '  size, fd, base: int;'
  echo 'begin'
  get mapfile | sed 's/^/  /'
  echo 'end.'; } > "$T/mapfile.wz"
try mapfile "$T/mapfile.wz"

{ echo 'include "json.wz";'
  echo 'schema Reply = record a: int; end;'
  echo 'var'
  echo '  dst, src: array[0..255] of char;'
  echo '  rec: Reply;'
  echo '  n: int;'
  echo 'begin'
  get checkwrite | sed 's/^/  /'
  echo 'end.'; } > "$T/checkwrite.wz"
try checkwrite "$T/checkwrite.wz"

# Every snippet in the file must be covered above: a new one that nobody compiles is
# exactly what this test exists to prevent.
have=$(grep -c '"prefix"' "$snip")
[ "$have" -eq 13 ] || {
  echo "the snippet file holds $have snippets, but this test compiles 13."
  echo "  Add the new one to a wrapper above -- an untested snippet is how a broken one ships."
  exit 1; }

echo "$have snippets, all of them compile"

# THE PROBLEM MATCHER, against output the compiler really produced.
#
# The regexp in package.json is what puts an error on a line in the Problems panel. It is
# checked here against a real failing compile rather than against a remembered format,
# because the two can drift apart silently: the panel would simply stay empty, and an
# empty Problems panel looks exactly like a program with no problems.
printf 'begin\n  nosuchname := 1;\nend.\n' > "$T/broken.wz"
"$WANTZEL" "$T/broken.wz" "$T/broken.bin" >"$T/berr" 2>&1 && {
  echo "the broken program compiled; this test needs a real compile error"; exit 1; }

# the shape the matcher expects: wantzel: <file>:<line>: <message>
if ! grep -qE '^wantzel: .*:[0-9]+: .+$' "$T/berr"; then
  echo "the compiler's error format no longer matches the problem matcher in package.json:"
  sed 's/^/    /' "$T/berr"
  echo "  the matcher expects: ^wantzel: (.*):([0-9]+): (.*)$"
  exit 1
fi

# and the regexp in package.json is still that one
if ! grep -q 'wantzel: (\.\*):(\\\\d+): (\.\*)' "$ROOT/editors/vscode/package.json"; then
  echo "the problem matcher in package.json has changed shape; recheck it against:"
  sed 's/^/    /' "$T/berr"
  exit 1
fi
echo "the problem matcher still matches what the compiler prints"
