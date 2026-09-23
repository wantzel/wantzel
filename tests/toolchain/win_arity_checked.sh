# winapi() refuses a call with the wrong number of arguments.
#
# WHY THIS MATTERS MORE THAN IT LOOKS. Win32 passes the first four arguments in
# rcx/rdx/r8/r9. A call with too few does not crash: the callee reads a register nobody set
# and carries on with whatever was in it. No message, no fault at a recognisable place, just
# wrong behaviour -- and on a machine that is not this one.
#
# MEASURED 22-09-2026, before the check existed. Both of these compiled with exit 0:
#     winapi("kernel32.dll", "CreateFileA", 1, 2)     CreateFileA takes seven
#     winapi(0)                                       GetStdHandle takes one
#
# WHAT IS CHECKED, and the last one is the point: the compiler must refuse what it KNOWS is
# wrong and stay out of the way otherwise. A check that also refuses correct calls would be
# worse than none, because it would be worked around.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# refuses <name> <source> <text the message must contain>
refuses() {
  printf '%s' "$2" > "$T/a.wz"
  if "$WANTZEL" "$T/a.wz" "$T/a.exe" --target=windows >"$T/err" 2>&1; then
    echo "$1: compiled, but should have been refused"; exit 1
  fi
  assert_contains "$1" "$(cat "$T/err")" "$3"
}

# accepts <name> <source>
accepts() {
  printf '%s' "$2" > "$T/a.wz"
  "$WANTZEL" "$T/a.wz" "$T/a.exe" --target=windows >"$T/err" 2>&1 \
    || { echo "$1: refused a correct call:"; sed 's/^/  /' "$T/err"; exit 1; }
}

refuses "too few arguments" \
  'begin
  if winapi(0) = 0 then halt(1);
end.
' "GetStdHandle takes 1 argument, not 0"

refuses "two of seven" \
  'begin
  if winapi(3, 1, 2) = 0 then halt(1);
end.
' "CreateFileA takes 7 arguments, not 2"

refuses "too many" \
  'begin
  if winapi(4, 1, 2, 3) = 0 then halt(1);
end.
' "CloseHandle takes 1 argument, not 3"

# ---- AND THE CORRECT CALLS STILL COMPILE -------------------------------------------------
accepts "one argument where one is wanted" \
  'begin
  if winapi(4, 0) = 0 then halt(1);
end.
'
accepts "seven where seven are wanted" \
  'begin
  if winapi(3, 0, 0, 0, 0, 0, 0, 0) = 0 then halt(1);
end.
'
accepts "none where none are wanted" \
  'begin
  if winapi(6) = 0 then halt(1);
end.
'

# ---- A NAMED IMPORT IS NOT CHECKED, AND THAT IS DELIBERATE -------------------------------
#
# winapi("user32.dll", "MessageBoxA", ...) names a function the compiler knows nothing about:
# its arity lives in a DLL on another machine. Refusing there would be guessing, and a wrong
# refusal cannot be worked around.
accepts "a named import is left alone" \
  'begin
  if winapi("user32.dll", "MessageBoxA", 0, 0, 0, 0) = 0 then halt(1);
end.
'

# ---- THE WHOLE GENERATED RUNTIME PASSES ITS OWN CHECK ------------------------------------
#
# This is the strongest check here and it costs one compile: every Windows program carries
# the runtime, which calls two dozen of these imports. If any table entry were wrong, this
# would fail -- so it validates the table against real calls rather than against
# documentation someone transcribed.
accepts "the generated runtime" 'begin
  halt(0);
end.
'

echo "ok: winapi() arity is checked for built-in slots and left alone for named imports"
