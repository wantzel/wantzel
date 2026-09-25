# The compiler targets Linux x86-64 and nothing else. This keeps it that way in writing too.
#
# A second target was carried for a while and then removed, and what makes a removal stick
# is not the code going -- it is the next sentence that assumes it is still there: "the .exe
# build", "on Windows this is different", a helper that opens its own window. Each one is
# small, and each one invites the next. So this walks every tracked file, the way
# english_only.sh does.
#
# TWO TIERS, because "Windows" is not always about our target.
#
#   Tier 1, TARGET, always refused: building for, shipping for or running natively on
#   another platform, and drawing a window ourselves. The compiler emits Linux ELF; a user
#   interface is a web page or an API (MCP, REST) that another program talks to, never a
#   native GUI of our own.
#
#   Tier 2, COMPATIBILITY, allowed when the line says so: a file saved on Windows has CRLF
#   line ends, a browser or client may run on Windows, a path or payload may come from it.
#   A line that says "Windows" passes when it also names what it is compatible WITH. One
#   that does not is asked which of the two it is.
#
# On Windows the answer is WSL2, in one sentence of the README -- that sentence passes.
# docs/changelog.md is history: a released version shipped what it shipped.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# Tier 1. "X11" only as a word (not the \x11 byte escape in a certificate), "wine" only as a
# word (a table may well hold wine_cooler), ".exe" only as a file extension.
T1='--target|winapi|winproc|kernel32|ws2_32|advapi32|PE32|WinMain|cmd\.exe|\b[Ww]ine\b|mingw|MSVC|[Ww]in32|\.dll\b|\.exe\b|XOpenDisplay|XCreateWindow|xcb_|Xlib|WM_PAINT|CreateWindow|(^|[^\\])\b[Xx]11\b|native GUI|GUI (binary|binaries|program|executable)|Windows[- ](build|binary|binaries|target|backend|runtime|release|port|executable|installer)|(build|compile|emit|ship|release|target)[a-z]* (for|on) Windows'

# Tier 2: the words that make a mention of Windows a statement about compatibility.
COMPAT='CRLF|\\r\\n|line end|line-end|browser|client|user.?agent|\bkey\b|keys|path|payload|format|encoding|WSL2|interop|compatib'

hits=$(git ls-files | while read -r f; do
  case "$f" in
    tests/toolchain/linux_only.sh|docs/changelog.md) continue ;;
  esac
  grep -nE -e "$T1" "$f" 2>/dev/null | sed "s|^|$f:|; s|\$|  [target]|"
  grep -nE "Windows" "$f" 2>/dev/null | grep -vE -e "$T1" | grep -viE -e "$COMPAT" | sed "s|^|$f:|; s|\$|  [which one?]|"
done)

if [ -n "$hits" ]; then
  echo "This repository is Linux-only:"
  printf '%s\n' "$hits" | cut -c1-180 | sed 's/^/  /'
  echo
  echo "[target]      building, shipping or running on another platform, or drawing a window"
  echo "              ourselves. The compiler emits Linux ELF; a UI is a web page or an API."
  echo "              On Windows the answer is WSL2, in one sentence of the README."
  echo "[which one?]  is this about OUR target (not allowed), or about compatibility with"
  echo "              something from Windows? Then say so on the line: CRLF, browser, client,"
  echo "              path, payload, file format, encoding."
  exit 1
fi
echo "  ok    nothing assumes a second target or a native window"
