# The two compilers must accept the same language and say the same things.
#
# The fixed point does NOT prove this. It proves the compiler reproduces itself, which says
# nothing about a feature the compiler's own source never uses. That gap was real: the named
# form of winapi() lived only in src/wantzel.wz for a while, so a fresh clone -- which builds
# with bootstrap/boot.c -- could not compile a program that used it, and every test stayed
# green.
#
# So: take programs that use what the compiler itself does not, and check that both
# compilers agree, on the output AND on the refusals.
. "$ROOT/tests/helpers.sh"

both() {                       # both <name> <source>
  printf '%s' "$2" > "$T/c.wz"
  a=$("$ROOT/bin/wantzel"  "$T/c.wz" "$T/a.out" --target=windows 2>&1); ra=$?
  b=$("$ROOT/bin/wantzel0" "$T/c.wz" "$T/b.out" --target=windows 2>&1); rb=$?
  # same verdict
  [ "$ra" = "$rb" ] || { echo "$1: exit $ra from the self-hosted compiler, $rb from the C one"; exit 1; }
  if [ "$ra" = "0" ]; then
    cmp -s "$T/a.out" "$T/b.out" || { echo "$1: the two compilers emit different bytes"; exit 1; }
  else
    # same message, ignoring the path each was given
    ma=$(printf '%s' "$a" | sed 's|.*\.wz:|:|'); mb=$(printf '%s' "$b" | sed 's|.*\.wz:|:|')
    [ "$ma" = "$mb" ] || { echo "$1: different messages"; echo "  wantzel : $ma"; echo "  wantzel0: $mb"; exit 1; }
  fi
}

# A named import: the feature the compiler's own source does not use.
both "a named import" 'program t;
begin winapi("user32.dll", "MessageBoxA", 0, 0, 0, 0); end.
'
# And its refusals, which are just as easy to implement in only one of the two.
both "an empty DLL name"      'program t; begin winapi("", "X", 0); end.
'
both "a DLL without .dll"      'program t; begin winapi("user32", "X", 0); end.
'
both "an empty function name"  'program t; begin winapi("user32.dll", "", 0); end.
'
both "a slot out of range"     'program t; begin winapi(9999, 0); end.
'
# winproc: the newest thing the compiler's own source does not use
both "a routine address"       'program t;
function f(a: int; b: int; c: int; d: int): int;
begin return 0; end;
var p: int;
begin p := winproc(f); end.
'
both "winproc on a bad name"   'program t; var p: int; begin p := winproc(nope); end.
'

# A COMPILE-TIME REFUSAL, which is the class that slipped through once and is the reason
# this file matters. A check that lands in only one of the two gives a self-hosted compiler
# that refuses a program and a C bootstrap that accepts it -- and the fixed point still
# reports success, because both compilers still build themselves. Measured 16-09-2026: that
# is exactly what happened, because boot.c has TWO functions that parse an index and the
# check went into the wrong one.
both "a constant index out of range" 'var a: array[0..3] of char;
begin a[9] := chr(65); end.
'
both "a constant index below the lower bound" 'var a: array[5..9] of int;
begin a[4] := 1; end.
'
both "a named constant out of range" 'const K = 12;
var a: array[0..3] of char;
begin a[K] := chr(65); end.
'
# And the other half: an index that is FINE must be accepted by both, byte for byte. A
# check that is too eager in one compiler and absent in the other is the same bug wearing
# the opposite face.
both "a constant index in range" 'var a: array[5..9] of int;
begin a[5] := 1; a[9] := 2; end.
'
echo "  both compilers agree on every case"
