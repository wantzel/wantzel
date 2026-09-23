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
# floris@wantzel.com is the project's OWN contact address and belongs in the open: it is
# what the README and the site tell a reader to write to.  Every other address is still
# refused -- the one this check exists for is a personal address from another project,
# which is a leak that cannot be taken back once it is in the history.
#
# The reserved documentation domains are allowed too: example.com, example.net and
# example.org (RFC 2606, RFC 6761) can never belong to anyone, so an address there is a
# placeholder by definition -- `--email you@example.com` in a usage line is exactly what
# a reader should see. The check looks at each ADDRESS, not at the line: allowing a line
# because it also carries a placeholder would let a real address beside it through.
#
# That precision is not decoration. Before 23-09-2026 the whole line was matched, so the
# usage line of examples/serve.wz failed this test for its placeholder, and a test passing
# `f@w.com` -- a short, made-up looking address at a domain somebody does own -- failed it
# for the same reason and looked like the same false alarm. It was not: that one is now
# test@example.com.
hits=$(git ls-files | xargs grep -noiE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}' 2>/dev/null \
       | grep -v '^tests/toolchain/no_foreign_code.sh:' \
       | grep -viE ':floris@wantzel\.com$' \
       | grep -viE '@([a-z0-9-]+\.)*example\.(com|net|org)$')
if [ -n "$hits" ]; then printf '  an e-mail address:\n'; printf '%s\n' "$hits" | sed 's/^/    /'; fails=$((fails+1)); fi

[ $fails -eq 0 ] || { echo "$fails kind(s) of foreign reference found; see above"; exit 1; }
echo "no foreign names, personal paths or e-mail addresses"
