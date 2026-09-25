#!/bin/sh
# Every runtime trap the compiler can emit has a test that actually reaches it.
#
# WHY. A check that never runs is not a check. slen() carried a trap that an earlier guard
# already caught, so the line could never be reached -- it read as protection and was dead
# code. The only way to know a trap works is to have a program that trips it.
#
# HOW. Collect the message of every trap() the compiler emits, then look for a test whose
# expected output contains it. A trap without one is either a gap (nothing proves it fires)
# or dead code (nothing can reach it), and both are worth knowing about.
#
# THIS IS A LIST, NOT A NUMBER. Adding a trap without a test fails here by name, so the
# question "is this reachable?" gets asked when the trap is written rather than years later.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"

# NOT `... | while read`: a pipe runs the loop in a SUBSHELL, so a counter set inside it is
# gone by the time the script exits -- the run would report failures and still succeed. A
# temporary file and a plain loop keep the count where the exit code can see it.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
grep -oE 'trap\("[^"]+"\)' src/wantzel.wz | sed 's/^trap("//; s/")$//' | sort -u > "$tmp"

fail=0
while IFS= read -r msg; do
  [ -n "$msg" ] || continue
  # An .out or .err file that expects this text means some test reaches the trap.
  if grep -rqlF "$msg" tests/lang/ tests/compiler/ 2>/dev/null; then
    printf '  ok    %s\n' "$msg"
  else
    printf '  FAIL  no test reaches: %s\n' "$msg"
    printf '        either nothing proves it fires, or nothing can reach it.\n'
    printf '        Write a program that trips it, or remove the dead check.\n'
    fail=$((fail + 1))
  fi
done < "$tmp"

if [ "$fail" -gt 0 ]; then
  echo "$fail trap(s) without a test"
  exit 1
fi
echo "every trap the compiler emits has a test that reaches it"
