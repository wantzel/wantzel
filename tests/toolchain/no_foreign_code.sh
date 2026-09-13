# Nothing in this repository may name the projects it was split out of, carry a
# personal path, or leak an e-mail address.  The repository is public; a name that
# means something only to its author is noise to everyone else, and a home
# directory in an example is a small privacy leak that is hard to take back.
#
# Kept in tests/toolchain/ because it walks the whole tree: it runs with
# ./wztest --toolchain, not on every everyday run.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

fails=0
report() {   # what pattern
  hits=$(git ls-files | xargs grep -niE "$2" 2>/dev/null | grep -v '^tests/toolchain/no_foreign_code.sh:')
  if [ -n "$hits" ]; then
    printf '  %s:\n' "$1"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fails=$((fails+1))
  fi
}

report "a name from a project this compiler was split out of" '\bddop|duurzame|newddop|table2agent|\bpax'
# /home/you/ and /path/to/ are placeholders in documentation; a real account name is not.
hits=$(git ls-files | xargs grep -niE '/home/[a-z]+/' 2>/dev/null | grep -vE '/home/(you|user)/' | grep -v '^tests/toolchain/no_foreign_code.sh:')
if [ -n "$hits" ]; then printf '  a personal home directory:\n'; printf '%s\n' "$hits" | sed 's/^/    /'; fails=$((fails+1)); fi
report "an e-mail address" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}'

[ $fails -eq 0 ] || { echo "$fails kind(s) of foreign reference found; see above"; exit 1; }
echo "no foreign names, personal paths or e-mail addresses"
