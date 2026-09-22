# winproc(name) yields the address of a routine, so Windows can call it back.
#
# This is the one thing the language could not do, and the reason a window with buttons was
# out of reach: RegisterClassEx wants a function address in lpfnWndProc, and a callback
# cannot be a compile-time link -- Windows calls it from its own code.
#
# It is deliberately NOT addr() on any routine. That would put a function pointer in a
# language that does not have one; this opens the door exactly as wide as the need, and its
# name says what the need is.
. "$ROOT/tests/helpers.sh"
[ -x "${WINE:-/usr/lib/wine/wine64}" ] || command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || { echo "wine is missing"; exit 1; }

cat > "$T/wp.wz" <<'WZ'
include "io.wz";
function alpha(a: int; b: int; c: int; d: int): int;
begin return 111; end;
function beta(a: int; b: int; c: int; d: int): int;
begin return 222; end;
var p, q: int;
begin
  p := winproc(alpha);
  q := winproc(beta);
  if p = 0 then begin io.puts(STDOUT, "zero\n"); halt(1); end;
  if p = q then begin io.puts(STDOUT, "same\n"); halt(1); end;
  // it must land inside the image, not somewhere arbitrary
  if p < 4194304 then begin io.puts(STDOUT, "below the image base\n"); halt(1); end;
  io.puts(STDOUT, "distinct\n");
end.
WZ
compile_win "$T/wp.wz" "$T/wp.exe"
got=$(cd "$T" && run_win "$T/wp.exe" 2>/dev/null)
assert_eq "winproc gives each routine its own address" "$got" "distinct"

# and it refuses what it cannot answer
cat > "$T/bad.wz" <<'WZ'
var p: int;
begin p := winproc(nosuchroutine); end.
WZ
if "$ROOT/bin/wantzel" "$T/bad.wz" "$T/bad.exe" --target=windows >"$T/bad.err" 2>&1; then
  echo "winproc accepted a routine that does not exist"; exit 1
fi
grep -q "no such routine" "$T/bad.err" || { echo "wrong message:"; cat "$T/bad.err"; exit 1; }

# on Linux it does not exist at all: a callback is a Windows notion
cat > "$T/lin.wz" <<'WZ'
function f(a: int; b: int; c: int; d: int): int;
begin return 0; end;
var p: int;
begin p := winproc(f); end.
WZ
if "$ROOT/bin/wantzel" "$T/lin.wz" "$T/lin" >"$T/lin.err" 2>&1; then
  echo "winproc compiled for a Linux target"; exit 1
fi
grep -q "only available in a Windows executable" "$T/lin.err" || { echo "wrong message:"; cat "$T/lin.err"; exit 1; }
# The real test: let WINDOWS call it. EnumWindows takes a callback and invokes it once per
# top-level window, which exercises the whole path -- the address, the register move, and
# the registers Windows expects back untouched.
#
# That last part is where this first went wrong: rdi and rsi are nonvolatile on Windows and
# volatile on Linux, so a shim that did not save them corrupted the caller's state and
# faulted later, somewhere else entirely.
cat > "$T/cb.wz" <<'WZ'
include "io.wz";
var count: int;
function onwindow(hwnd: int; lp: int; a: int; b: int): int;
begin
  count := count + 1;
  return 1;
end;
begin
  count := 0;
  winapi("user32.dll", "EnumWindows", winproc(onwindow), 0);
  if count = 0 then begin io.puts(STDOUT, "never called\n"); halt(1); end;
  io.puts(STDOUT, "called\n");
end.
WZ
compile_win "$T/cb.wz" "$T/cb.exe"
got=$(cd "$T" && run_win "$T/cb.exe" 2>/dev/null)
assert_eq "Windows calls a Wantzel routine through winproc" "$got" "called"

echo "  refuses an unknown routine, and refuses a Linux target"
