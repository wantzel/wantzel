# Nothing that builds, tests or documents this compiler needs Python.
#
# "No external dependencies" is a rule of this project, and a suite that shells out to
# another language to produce its own inputs contradicts it in the first place a reader
# looks. The limits tests used to make 26 python3 calls to generate the sources they
# compile; the compiler now generates them itself (tests/limits/progs/gen.wz).
#
# THERE ARE NO EXCEPTIONS LEFT, and the two that existed went the same way.
#
# tools/probe_http.py was a hand-run smoke test that spoke to an MCP server through the
# official Python SDK. Removed on 15-09-2026: nothing called it, it needed a package from
# outside, and it was the only Python file in a repository whose promise is that it has
# none.
#
# tools/install-claude-desktop.sh registered an MCP server with Claude Desktop and used
# python3 to edit that program's JSON config. Removed on 16-09-2026, for the same reason
# one step further on: the document that told anyone to run it
# (docs/mcp-in-claude-desktop.md) was gone, so nothing called it and nothing described it
# -- and it assumed WSL and systemd besides. It was also the last thing keeping a
# tools/ directory alive in this repository.
#
# An exception nobody needs is an exception that can go.
#
# AND IT SHOWED A HOLE IN THIS TEST, which is now closed. The check below looks for the
# WORD python inside files; probe_http.py never contained it, so this test never saw the
# one Python file in the repository. Nothing else looked at file NAMES either. So there
# are two checks here now: no file may be named *.py, and no file may mention python.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# 1. no file may BE Python, whatever it says inside
named=$(git ls-files '*.py')
if [ -n "$named" ]; then
  echo "a Python file is tracked in this repository:"
  printf '%s\n' "$named" | sed 's/^/  /'
  echo
  echo "Tooling that lives in this repository is written in Wantzel. Remove it, or -- if"
  echo "it genuinely belongs -- say so at the top of this test WITH the reason, so the"
  echo "next person does not have to guess."
  exit 1
fi

# 2. and nothing may reach for python to build, test or document the compiler
hits=$(git ls-files | while read -r f; do
  case "$f" in tests/toolchain/no_python.sh) continue ;; esac
  grep -nE '\bpython3?\b' "$f" 2>/dev/null | sed "s|^|$f:|"
done | grep -v ':[0-9]*: *#' | grep -v ':[0-9]*: *//')

if [ -n "$hits" ]; then
  echo "Python is referenced in this repository:"
  printf '%s\n' "$hits" | sed 's/^/  /'
  echo
  echo "Replace it, or -- if it genuinely belongs -- say so at the top of this test"
  echo "WITH the reason, so the next person does not have to guess."
  exit 1
fi
echo "no Python file is tracked and nothing reaches for python"
