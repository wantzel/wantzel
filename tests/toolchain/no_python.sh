# Nothing that builds, tests or documents this compiler needs Python.
#
# "No external dependencies" is a rule of this project, and a suite that shells out to
# another language to produce its own inputs contradicts it in the first place a reader
# looks. The limits tests used to make 26 python3 calls to generate the sources they
# compile; the compiler now generates them itself (tests/limits/progs/gen.wz).
#
# One exception, deliberate and listed here so it cannot drift into two:
#
#   bootstrap/tools/install-claude-desktop.sh edits a JSON config file belonging to
#   another program, for a user who chooses to run it. It is not needed to build, test
#   or use the compiler, and rewriting it would buy nothing.
#
# tools/probe_http.py is not exempted here: it is a hand-run smoke test whose value is
# precisely that it is an INDEPENDENT client, and where it should live is decided
# elsewhere. If it is still in the repository it will show up below, and that is right.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

allowed='^bootstrap/tools/install-claude-desktop\.sh$'

hits=$(git ls-files | grep -vE "$allowed" | while read -r f; do
  case "$f" in tests/toolchain/no_python.sh) continue ;; esac
  grep -nE '\bpython3?\b' "$f" 2>/dev/null | sed "s|^|$f:|"
done | grep -v ':[0-9]*: *#' | grep -v ':[0-9]*: *//')

if [ -n "$hits" ]; then
  echo "Python is referenced outside the one place that is allowed:"
  printf '%s\n' "$hits" | sed 's/^/  /'
  echo
  echo "Replace it, or -- if it genuinely belongs -- add it to the exception at the top"
  echo "of this test WITH the reason, so the next person does not have to guess."
  exit 1
fi
echo "nothing but the Claude Desktop installer mentions Python"
