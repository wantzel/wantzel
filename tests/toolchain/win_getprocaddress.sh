# A named import is not just written into the table -- it is CALLED, and it answers.
#
# win_dll_by_name.sh proves the name reaches the import table. That is not the same as the
# call working: a wrong slot, a wrong argument order or a broken thunk all still produce a
# correct-looking table. This runs the calls and checks the answers.
#
# GetModuleHandleA and GetProcAddress are the pair that matters most. Between them they
# yield the ADDRESS of a function in a DLL, which is what an API wants when it asks for a
# callback (lpfnWndProc, a comparator, a hook). That address is an ordinary int here: the
# language gets no function pointer, and no compiler change was needed to reach it.
. "$ROOT/tests/helpers.sh"
[ -x "${WINE:-/usr/lib/wine/wine64}" ] || command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || { echo "wine is missing"; exit 1; }

cat > "$T/gpa.wz" <<'WZ'
include "io.wz";
var
  hmod, proc, bad: int;
  dll, fn, nosuch: array[0..63] of char;
  i: int;
procedure zput(a: array of char; s: str);
var k: int;
begin
  k := 0;
  while k < slen(s) do begin a[k] := schar(s, k); k := k + 1; end;
  a[k] := chr(0);
end;
begin
  zput(dll, "user32.dll");
  zput(fn, "DefWindowProcA");
  zput(nosuch, "ThisFunctionDoesNotExistAnywhere");

  hmod := winapi("kernel32.dll", "GetModuleHandleA", addr(dll[0]));
  if hmod = 0 then begin io.puts(STDOUT, "no module\n"); halt(1); end;

  proc := winapi("kernel32.dll", "GetProcAddress", hmod, addr(fn[0]));
  if proc = 0 then begin io.puts(STDOUT, "no address\n"); halt(1); end;
  io.puts(STDOUT, "address\n");

  // asking for a function that is not there must answer 0, not crash: that is how the
  // caller finds out, and it is the difference between a check and a guess
  bad := winapi("kernel32.dll", "GetProcAddress", hmod, addr(nosuch[0]));
  if bad <> 0 then begin io.puts(STDOUT, "a missing function got an address\n"); halt(1); end;
  io.puts(STDOUT, "missing is zero\n");

  // the same name twice must give the same address -- one import entry, not two
  if winapi("kernel32.dll", "GetProcAddress", hmod, addr(fn[0])) <> proc then
  begin io.puts(STDOUT, "the same name gave two addresses\n"); halt(1); end;
  io.puts(STDOUT, "stable\n");
end.
WZ

compile_win "$T/gpa.wz" "$T/gpa.exe"
got=$(cd "$T" && run_win "$T/gpa.exe" 2>/dev/null)
assert_eq "a named import is callable and returns a real address" "$got" "address
missing is zero
stable"

# The other half: a name that does NOT exist must fail, and fail READABLY. Wine reports it
# on stderr and exits non-zero -- no dialog, because run_win disables winedbg. Without
# that, this failure opens a window and hangs until the timeout, and the exit status tells
# you nothing.
#
# This is also the sabotage check for the test above: if a wrong name somehow still "worked",
# the assertions up there would be proving nothing.
cat > "$T/bad.wz" <<'WZ'
begin
  winapi("user32.dll", "ThisFunctionDoesNotExistAnywhere", 0);
end.
WZ
compile_win "$T/bad.wz" "$T/bad.exe"
if (cd "$T" && run_win "$T/bad.exe" >/dev/null 2>"$T/bad.err"); then
  echo "calling a function that does not exist SUCCEEDED; the import is not really being called"
  exit 1
fi
grep -q "unimplemented function user32.dll.ThisFunctionDoesNotExistAnywhere" "$T/bad.err" || {
  echo "the failure was not the one expected; wine said:"
  sed -n '1,3p' "$T/bad.err"
  exit 1
}
echo "  a name that does not exist fails at the call, and says so"
