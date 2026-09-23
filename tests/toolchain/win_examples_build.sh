# The Windows example compiles, and its winapi name is exercised.
#
# WHY THE SECOND HALF MATTERS MORE THAN THE FIRST. A misspelled function name in a real DLL
# is not caught at compile time and not at load time: the loader supplies a stub, and the
# program aborts at that CALL when something reaches it. So "it compiles" says nothing about
# whether MessageBoxA is spelled right -- only running it does, and only on the path that
# reaches the call.
#
# WHAT WAS MEASURED BY HAND under Wine (22-09-2026), because a suite cannot answer a dialog:
#     winmessage  with a display:    "MessageBox returned 1 (OK)", then "you answered yes"
#                 without a display:  both calls run, MessageBoxA answers -1
#
# Callbacks (winproc) have their own test: tests/toolchain/win_winproc.sh.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

for ex in winmessage; do
  compile_win "examples/$ex.wz" "$T/$ex.exe"
  [ -s "$T/$ex.exe" ] || { echo "$ex.exe is empty"; exit 1; }
  case "$(head -c 2 "$T/$ex.exe")" in
    MZ) ;;
    *) echo "$ex.exe is not a PE binary"; exit 1 ;;
  esac
done

# ---- THEY MUST REFUSE TO BUILD FOR LINUX -------------------------------------------------
#
# A GUI example that quietly compiled for Linux would be a program that cannot run and says
# nothing about why. The compiler catches this one at compile time, which is the earliest of
# the three moments a wrong winapi shows up.
if "$WANTZEL" examples/winmessage.wz "$T/nope" >"$T/err" 2>&1; then
  echo "winmessage.wz compiled for Linux, but winapi() should have refused"
  exit 1
fi
assert_contains "and says why" "$(cat "$T/err")" "only available in a Windows executable"

# ---- THE winapi NAME IS SPELLED THE WAY WINDOWS SPELLS IT -------------------------------
#
# The A-suffix is the usual slip: MessageBox does not exist, MessageBoxA does.
if ! grep -qF '"MessageBoxA"' examples/winmessage.wz; then
  echo "winmessage.wz no longer calls MessageBoxA -- renamed or dropped?"
  exit 1
fi

echo "ok: the Windows example builds as PE, refuses Linux, and names its import correctly"
