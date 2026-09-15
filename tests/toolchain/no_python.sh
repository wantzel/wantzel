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
# There used to be a second candidate, tools/probe_http.py -- a hand-run smoke test that
# spoke to an MCP server through the official Python SDK. It was removed on 15-09-2026
#: nothing called it, it needed a package from outside, and it was the only
# Python file in a repository whose promise is that it has none. An exception nobody
# needs is an exception that can go.
#
# AND IT SHOWED A HOLE IN THIS TEST, which is now closed. The check below looks for the
# WORD python inside files; probe_http.py never contained it, so this test never saw the
# one Python file in the repository. Nothing else looked at file NAMES either. So there
# are two checks here now: no file may be named *.py, and no file may mention python.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

allowed='^bootstrap/tools/install-claude-desktop\.sh$'

# 1. no file may BE Python, whatever it says inside
named=$(git ls-files '*.py' | grep -vE "$allowed")
if [ -n "$named" ]; then
  echo "a Python file is tracked in this repository:"
  printf '%s\n' "$named" | sed 's/^/  /'
  echo
  echo "Tooling that lives in this repository is written in Wantzel. Remove it, or -- if"
  echo "it genuinely belongs -- add it to the exception at the top of this test WITH the"
  echo "reason, so the next person does not have to guess."
  exit 1
fi

# 2. and nothing may reach for python to build, test or document the compiler
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
echo "no Python file is tracked, and nothing but the Claude Desktop installer mentions it"
