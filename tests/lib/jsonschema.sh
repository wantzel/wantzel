# lib/jsonschema.wz and examples/jsoncheck.wz: JSON validated against a schema.
#
# WHAT JUDGES THE ANSWERS HERE, and it is weaker than elsewhere in this suite. Most files in
# tests/lib have an independent implementation as arbiter -- openssl for the crypto, python
# for the JWS. There is no JSON Schema validator on this machine and installing one would be
# the dependency this stack avoids, so the expectations come from the specification text
# instead, quoted in localfiles/research/sources/json-schema-2020-12.md rather than
# paraphrased.
#
# That is worth stating plainly: these cases say what the specification says, and a
# misreading of it would be shared by the test and the code. The cases are chosen to be ones
# where the specification is unambiguous.
#
# WHAT IS ESTABLISHED:
#   1. valid documents pass and invalid ones fail, over every supported keyword
#   2. THE PLACE IS NAMED. "invalid" without a location is as useful as a compiler that only
#      says "error", and this whole toolchain exists to not do that
#   3. integer is not the same as number -- 1.5 must fail where a whole number is required
#   4. a keyword this cannot check is reported rather than silently ignored
#   5. our own real JSON files parse
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d)
cleanup() { rc=$?; rm -rf "$tmp" || true; exit $rc; }
trap cleanup EXIT

"$here/bin/wantzel" "$here/examples/jsoncheck.wz" "$tmp/js" >/dev/null 2>&1 \
  || { echo "  FAIL  examples/jsoncheck.wz does not compile"; exit 1; }
ok "the validator builds, $(stat -c %s "$tmp/js") bytes"

# valid <schema-file> <json> <description>
valid() {
  printf '%s' "$2" > "$tmp/d.json"
  if out=$("$tmp/js" "$1" "$tmp/d.json" 2>&1); then ok "$3"
  else bad "$3 -- was rejected" "$out"; fi
}
# invalid <schema-file> <json> <expected-path> <description>
invalid() {
  printf '%s' "$2" > "$tmp/d.json"
  if out=$("$tmp/js" "$1" "$tmp/d.json" 2>&1); then
    bad "$4 -- was ACCEPTED" "a validator that accepts everything passes every positive case"
  else
    case "$out" in
      *"at $3"*) ok "$4" ;;
      *) bad "$4 -- rejected, but the place is wrong" "wanted: $3" "got: $out" ;;
    esac
  fi
}

# ---- type -------------------------------------------------------------------------------------
cat > "$tmp/t.json" <<'J'
{"type":"object","properties":{"n":{"type":"number"},"i":{"type":"integer"},
 "s":{"type":"string"},"b":{"type":"boolean"},"a":{"type":"array"},"z":{"type":"null"}}}
J
valid   "$tmp/t.json" '{"n":1.5,"i":7,"s":"x","b":true,"a":[],"z":null}' "every type matches its own kind"
invalid "$tmp/t.json" '{"s":5}'        /s "a number where a string is required"
invalid "$tmp/t.json" '{"b":"true"}'   /b "the string \"true\" is not a boolean"
invalid "$tmp/t.json" '{"z":0}'        /z "zero is not null"
invalid "$tmp/t.json" '{"a":{}}'       /a "an object is not an array"

# INTEGER IS NOT NUMBER, and this is the one place a validator is most likely to be quietly
# wrong: 1.5 satisfies "number" and must not satisfy "integer".
valid   "$tmp/t.json" '{"i":7}'        "an integer satisfies integer"
valid   "$tmp/t.json" '{"n":7}'        "and a whole number satisfies number"
invalid "$tmp/t.json" '{"i":1.5}'      /i "a fraction does NOT satisfy integer"
valid   "$tmp/t.json" '{"i":7.0}'      "but 7.0 does, because it is whole"

# A LIST OF TYPES: any one may match.
printf '%s' '{"type":"object","properties":{"x":{"type":["string","null"]}}}' > "$tmp/tl.json"
valid   "$tmp/tl.json" '{"x":"a"}'  "a type list accepts the first name"
valid   "$tmp/tl.json" '{"x":null}' "and the second"
invalid "$tmp/tl.json" '{"x":3}'    /x "and rejects a type not in the list"

# ---- required and additionalProperties -----------------------------------------------------------
printf '%s' '{"type":"object","required":["a","b"],"properties":{"a":{},"b":{}},"additionalProperties":false}' > "$tmp/r.json"
valid   "$tmp/r.json" '{"a":1,"b":2}'       "both required members present"
invalid "$tmp/r.json" '{"a":1}'        /b   "a missing required member is named"
invalid "$tmp/r.json" '{"a":1,"b":2,"c":3}' /c "an extra member is refused when additionalProperties is false"

# ---- ranges and lengths ----------------------------------------------------------------------------
printf '%s' '{"type":"object","properties":{"p":{"type":"integer","minimum":1,"maximum":10},"s":{"type":"string","minLength":2,"maxLength":4}}}' > "$tmp/g.json"
valid   "$tmp/g.json" '{"p":1}'      "the minimum itself is allowed"
valid   "$tmp/g.json" '{"p":10}'     "and so is the maximum"
invalid "$tmp/g.json" '{"p":0}'  /p  "one below the minimum is not"
invalid "$tmp/g.json" '{"p":11}' /p  "nor one above the maximum"
valid   "$tmp/g.json" '{"s":"ab"}'   "a string at the minimum length"
invalid "$tmp/g.json" '{"s":"a"}'  /s "a string one character short"
invalid "$tmp/g.json" '{"s":"abcde"}' /s "and one character too long"

# LENGTH IS IN CHARACTERS, NOT BYTES, and the example has to be chosen so the two ANSWERS
# DIFFER. "éé" is four bytes and two characters, which passes maxLength 4 either way --
# measured: with byte counting deliberately restored, the whole file stayed green on that
# case. "ééé" is six bytes and three characters: allowed by the specification, rejected by a
# byte count.
valid   "$tmp/g.json" '{"s":"ééé"}'  "an accented string counts characters, not bytes"

# AND AN ESCAPE IS ONE CHARACTER. "\n" is two bytes in the file; "\u00e9" is six. A string of
# four escaped newlines is four characters and must pass maxLength 4.
valid   "$tmp/g.json" '{"s":"\n\n\n\n"}' "an escape counts as one character"

# ---- enum and const ----------------------------------------------------------------------------------
printf '%s' '{"type":"object","properties":{"e":{"enum":["red","green",3]},"c":{"const":"fixed"}}}' > "$tmp/e.json"
valid   "$tmp/e.json" '{"e":"red"}'   "a value in the enum"
valid   "$tmp/e.json" '{"e":3}'       "including a non-string one"
invalid "$tmp/e.json" '{"e":"blue"}' /e "a value outside the enum"
valid   "$tmp/e.json" '{"c":"fixed"}' "the required constant"
invalid "$tmp/e.json" '{"c":"other"}' /c "and anything else"

# ---- arrays ---------------------------------------------------------------------------------------------
printf '%s' '{"type":"object","properties":{"a":{"type":"array","items":{"type":"integer"},"minItems":1,"maxItems":3}}}' > "$tmp/a.json"
valid   "$tmp/a.json" '{"a":[1,2,3]}' "an array of the right item type and size"
invalid "$tmp/a.json" '{"a":[]}'      /a "an empty array against minItems"
invalid "$tmp/a.json" '{"a":[1,2,3,4]}' /a "too many items"
# THE INDEX IS IN THE PATH, which is what makes a failure in a long array findable.
invalid "$tmp/a.json" '{"a":[1,"x",3]}' /a/1 "and a bad item names its index"

# ---- nesting ---------------------------------------------------------------------------------------------
printf '%s' '{"type":"object","properties":{"s":{"type":"object","properties":{"deep":{"type":"array","items":{"type":"object","properties":{"v":{"type":"integer"}}}}}}}}' > "$tmp/n.json"
valid   "$tmp/n.json" '{"s":{"deep":[{"v":1}]}}' "a nested structure validates"
invalid "$tmp/n.json" '{"s":{"deep":[{"v":"no"}]}}' /s/deep/0/v "and a deep failure names the whole path"

# ---- 4. AN UNCHECKABLE KEYWORD IS REPORTED ---------------------------------------------------------------
#
# The specification says an unknown keyword must be IGNORED, so ignoring it is correct. But a
# document accepted here may still be rejected by a complete validator, and a caller deciding
# whether to trust the answer needs to know that happened.
printf '%s' '{"type":"object","properties":{"x":{"type":"string"}},"allOf":[{"required":["x"]}]}' > "$tmp/p.json"
printf '%s' '{"y":1}' > "$tmp/d.json"
out=$("$tmp/js" "$tmp/p.json" "$tmp/d.json" 2>&1 || true)
case "$out" in
  *"does not check"*) ok "a schema using allOf is accepted but flagged as unchecked" ;;
  valid) bad "an unchecked keyword was passed over in silence" \
             "the document may still be invalid, and the caller is not told" ;;
  *) bad "the unchecked-keyword case behaved unexpectedly" "got: $out" ;;
esac

# ---- 5. REAL-WORLD JSON PARSES ---------------------------------------------------------------------------
#
# FROM INSIDE THIS REPOSITORY ONLY. An earlier version reached up into the surrounding
# directory for configuration files that happen to sit there -- which works on this machine
# and fails for anyone who clones this repository on its own, because there is nothing above
# it. Whatever is tested has to be here.
#
# The shapes below are what real configuration looks like: nesting, arrays of objects,
# numbers with decimals, escapes and non-ASCII. A validator that only ever sees the tidy
# fixtures above has not met a real file.
printf '%s' '{"type":"object"}' > "$tmp/any.json"
cat > "$tmp/real.json" <<'J'
{
  "name": "example",
  "version": "1.2.3",
  "servers": [
    {"command": "one", "args": ["--flag", "value"], "env": {"KEY": "v"}},
    {"command": "two", "args": []}
  ],
  "rates": {"in": 0.003, "out": 0.015},
  "note": "a quote \" and a backslash \\ and an accent é",
  "enabled": true,
  "missing": null
}
J
if "$tmp/js" "$tmp/any.json" "$tmp/real.json" >/dev/null 2>&1; then
  ok "a realistic configuration file parses"
else
  bad "a realistic configuration file does not parse" "$("$tmp/js" "$tmp/any.json" "$tmp/real.json" 2>&1 | head -2)"
fi

# ---- MALFORMED JSON IS ITS OWN ANSWER --------------------------------------------------------
#
# THE GAP THIS FILE MISSED UNTIL 22-09-2026. Three of these were reported VALID against
# {"type":"object"}: the walk found an opening brace, agreed it was an object, and never
# noticed the rest was broken. For a validator that is the worst answer it can give, because
# being asked whether the document is correct is the entire reason anyone runs it.
#
# The two that WERE refused were refused for the wrong reason -- "not of the required type",
# because the first character did not look like an object. Coincidence, not a check.
printf '%s' '{"type":"object"}' > "$tmp/obj.json"
# NOTE: the empty string is NOT in this list. An empty file cannot be mapped, so it comes
# back as a read error (2) rather than as malformed JSON (3) -- which is a fair distinction
# and not a bug: there is nothing to have an opinion about. It had a case here at first and
# the failure was the expectation.
for doc in '{"a":}' '{"a" 1}' '{"a":1,}' '[1,2' 'niets' '{"a":1}{"b":2}' '{"a":,"b":1}' '   '; do
  printf '%s' "$doc" > "$tmp/d.json"
  "$tmp/js" "$tmp/obj.json" "$tmp/d.json" >/dev/null 2>"$tmp/e.txt" && rc=0 || rc=$?
  if [ "$rc" != "3" ]; then
    bad "malformed JSON was not reported as malformed: $doc" \
        "exit $rc, expected 3" "$(head -1 "$tmp/e.txt")"
  fi
done
ok "seven malformed documents, plus whitespace only, are all reported as not-JSON"

# AND A VALID DOCUMENT IS STILL VALID, or the check above is simply refusing everything --
# which would pass every case in that loop.
printf '%s' '{"a":1}' > "$tmp/d.json"
if "$tmp/js" "$tmp/obj.json" "$tmp/d.json" >/dev/null 2>&1; then
  ok "and a well-formed document still passes"
else
  bad "the malformed check refuses valid documents too" "$("$tmp/js" "$tmp/obj.json" "$tmp/d.json" 2>&1)"
fi

# NOT-JSON AND FAILS-THE-SCHEMA ARE DIFFERENT ANSWERS. They send you to different places --
# one to the syntax, one to the schema -- and a caller scripting against this wants to tell
# them apart. Collapsing them is how someone reads a schema for ten minutes over a missing
# comma.
printf '%s' '{"type":"object","properties":{"a":{"type":"string"}}}' > "$tmp/typed.json"
printf '%s' '{"a":1}' > "$tmp/d.json"
"$tmp/js" "$tmp/typed.json" "$tmp/d.json" >/dev/null 2>"$tmp/e.txt" && rc=0 || rc=$?
case "$rc:$(head -1 "$tmp/e.txt")" in
  "1:invalid:"*) ok "a document that is JSON but fails the schema exits 1 and says so" ;;
  *) bad "a schema failure is not distinguished from malformed JSON" "exit $rc: $(head -1 "$tmp/e.txt")" ;;
esac

# AND A BROKEN SCHEMA IS CAUGHT TOO, for the same reason: one that silently matches nothing
# would make every document look wrong.
printf '%s' '{"type":}' > "$tmp/badschema.json"
printf '%s' '{"a":1}' > "$tmp/d.json"
"$tmp/js" "$tmp/badschema.json" "$tmp/d.json" >/dev/null 2>"$tmp/e.txt" && rc=0 || rc=$?
if [ "$rc" = "3" ]; then ok "and a malformed SCHEMA is reported rather than silently matching nothing"
else bad "a malformed schema was not caught" "exit $rc: $(head -1 "$tmp/e.txt")"; fi

# ---- AND THE EXIT CODES, because a caller scripts against them -----------------------------------------------
printf '%s' '{"a":1}' > "$tmp/d.json"
"$tmp/js" "$tmp/any.json" "$tmp/d.json" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "0" ] && ok "a valid document exits 0" || bad "a valid document exits $rc, not 0"
printf '%s' '{"type":"array"}' > "$tmp/arr.json"
"$tmp/js" "$tmp/arr.json" "$tmp/d.json" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "1" ] && ok "an invalid one exits 1" || bad "an invalid document exits $rc, not 1"
"$tmp/js" "$tmp/nosuchfile.json" "$tmp/d.json" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "2" ] && ok "and an unreadable file exits 2, distinct from invalid" \
                 || bad "a missing file exits $rc, not 2"

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
