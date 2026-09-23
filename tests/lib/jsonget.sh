# examples/jsonget.wz reads a field, and refuses what is not JSON.
#
# WHY A TOOL FOR THIS AT ALL. A test suite that reads one field out of a reply reaches for a
# scripting one-liner, because it is three lines. The three lines are not the cost: STARTING
# the interpreter is, and it stays invisible until the helper runs in a loop -- by which time
# it reads as "the suite is slow" rather than "the helper is slow".
#
# MEASURED 22-09-2026 on this machine: 1.04 ms per call against 37.8 ms for the one-liner.
#
# THE EXPECTED VALUES ARE WRITTEN OUT, not produced by another language. Nothing that builds,
# tests or documents this compiler may need Python (tests/toolchain/no_python.sh), and a suite
# that shells out to one to make its own answers contradicts "no external dependencies" in the
# first place a reader looks. The first version of this test did exactly that, and that check
# caught it.
#
# It is also the stronger test: an oracle can only say what another implementation does, while
# a written-out value says what is RIGHT. The answers below come from the grammar at json.org.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; shift; for r in "$@"; do echo "        $r"; done; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$here/bin/wantzel" "$here/examples/jsonget.wz" "$tmp/jsonget" >/dev/null 2>&1 \
  || { echo "  FAIL  jsonget.wz does not compile"; exit 1; }

printf '%s' '{"name":"wantzel","n":42,"items":[{"id":"a"},{"id":"b"}],"deep":{"x":{"y":"found"}},"t":true,"z":null}' > "$tmp/d.json"

# ---- 1. THE VALUE AT A PATH --------------------------------------------------------------
#
# A string comes back without its quotes; true, false and null come back as the words the
# document holds, because that is what a shell script compares against.
while IFS='	' read -r p want; do
  [ -n "$p" ] || continue
  mine=$("$tmp/jsonget" "$p" < "$tmp/d.json" 2>/dev/null || true)
  if [ "$mine" = "$want" ]; then ok "$p -> $mine"
  else bad "$p gave the wrong value" "wanted: '$want'" "got:    '$mine'"; fi
done <<'PATHS'
name	wantzel
n	42
deep.x.y	found
items.1.id	b
items.0.id	a
t	true
z	null
PATHS

# ---- 2. A MISSING FIELD IS EXIT 1 AND SILENCE --------------------------------------------
#
# So `v=$(jsonget x) || echo absent` works. Printing something for a field that is not there
# is how a shell script ends up comparing against the word "None".
#
# THE EXIT CODE IS THE POINT, so it is captured before anything can overwrite it -- `|| true`
# would replace it with 0, which is the mistake made here first.
if out=$("$tmp/jsonget" nosuchfield < "$tmp/d.json" 2>/dev/null); then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then ok "a missing field is exit 1 and no output"
else bad "a missing field gave rc=$rc out='$out'"; fi

if out=$("$tmp/jsonget" items.9.id < "$tmp/d.json" 2>/dev/null); then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then ok "an index past the end is exit 1 and no output"
else bad "an index past the end gave rc=$rc out='$out'"; fi

# ---- 3. --valid ACCEPTS AND REFUSES THE RIGHT DOCUMENTS ----------------------------------
#
# THE ROW THAT FOUND A REAL BUG. The first version used json.skip, which walks a value by
# BALANCING brackets -- so it accepted {oops}, because the braces match. Measured: json.skip
# returned 6 for that document. A validator has to look inside.
#
# Every "1" below is a document a parser must REFUSE, checked against the grammar by hand.
while IFS='	' read -r d want; do
  [ -n "$d" ] || continue
  if printf '%s' "$d" | "$tmp/jsonget" --valid >/dev/null 2>&1; then mine=0; else mine=1; fi
  if [ "$mine" = "$want" ]; then ok "--valid: $d"
  else bad "--valid is wrong about $d" "wanted exit $want, got $mine"; fi
done <<'DOCS'
{"a":1}	0
{oops}	1
[1,2,3]	0
[1,2,	1
"hi"	0
true	0
42	0
{}	0
[]	0
{"a":}	1
{,}	1
nonsense	1
{} {}	1
{"a":[{"b":null}]}	0
[1 2]	1
{"a" 1}	1
DOCS

# ---- 4. AND IT IS ACTUALLY CHEAP ---------------------------------------------------------
#
# THE WHOLE REASON THE TOOL EXISTS, so it is measured rather than asserted -- but against a
# CEILING rather than another language, since nothing here may call one.
#
# Thirty calls in under 300 ms is about 10 ms each. An interpreter spends 13 to 38 ms on
# STARTUP alone, before parsing anything, so a tool that stays under this is doing what it was
# built for. Measured here: 30 calls in 11 ms.
t0=$(date +%s%N)
i=0; while [ $i -lt 30 ]; do "$tmp/jsonget" deep.x.y < "$tmp/d.json" >/dev/null; i=$((i+1)); done
t1=$(date +%s%N)
took=$(( (t1 - t0) / 1000000 ))
if [ "$took" -lt 300 ]; then
  ok "30 calls in ${took}ms (ceiling 300; an interpreter spends that on startup alone)"
else
  bad "30 calls took ${took}ms, and the ceiling is 300" \
      "the tool exists to avoid interpreter startup; this is no longer cheaper than one"
fi

echo "$pass ok, $fail fail"
[ "$fail" -eq 0 ]
