# Imports from two DLLs, interleaved, must land on the slots the import table uses.
#
# The IAT is written GROUPED BY DLL, but winapi() calls are parsed in source order. So the
# slot of an import depends on how many imports of the SAME DLL appear before it -- and a
# later winapi() naming that DLL has not been parsed yet when the call is emitted.
#
# Baking the slot in at parse time therefore produced a number one too low as soon as the
# order was user32, gdi32, user32: CreateFontA got the slot of the null terminator that
# separates the two groups, and calling it jumped to address zero. The crash appeared in
# whatever ran next, never at the call that caused it, which is what made it expensive.
#
# The fix is FX_SLOT: emit the import index and substitute the slot once every import is
# recorded. This test pins the order that broke it.
. "$ROOT/tests/helpers.sh"

cat > "$T/inter.wz" <<'WZ'
var buf: array[0..63] of char;
  k: int;
begin
  buf[0] := chr(104); buf[1] := chr(105); buf[2] := chr(0);
  k := winapi("user32.dll", "SetWindowTextA", 0, addr(buf[0]));
  k := winapi("gdi32.dll", "CreateFontA",
              0 - 16, 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, addr(buf[0]));
  k := winapi("user32.dll", "MessageBoxA", 0, addr(buf[0]), addr(buf[0]), 0);
end.
WZ

"$ROOT/bin/wantzel" "$T/inter.wz" "$T/inter.exe" --target=windows || { echo "interleaved imports did not compile"; exit 1; }

# Each name must sit under the DLL that actually exports it. Reading the grouped name
# table with the insertion index filed CreateFontA under user32 and MessageBoxA under
# gdi32 -- names the loader cannot resolve, so the slot stays zero.
if command -v objdump >/dev/null 2>&1; then
  imports=$(objdump -x "$T/inter.exe" 2>/dev/null | sed -n '/The Import Tables/,/Sections:/p')
  gdi=$(printf '%s\n' "$imports" | sed -n '/DLL Name: gdi32.dll/,/^$/p')
  usr=$(printf '%s\n' "$imports" | sed -n '/DLL Name: user32.dll/,/^$/p')
  printf '%s\n' "$gdi" | grep -q CreateFontA    || { echo "CreateFontA is not filed under gdi32"; exit 1; }
  printf '%s\n' "$usr" | grep -q MessageBoxA    || { echo "MessageBoxA is not filed under user32"; exit 1; }
  printf '%s\n' "$usr" | grep -q SetWindowTextA || { echo "SetWindowTextA is not filed under user32"; exit 1; }
  printf '%s\n' "$gdi" | grep -q MessageBoxA    && { echo "MessageBoxA landed in gdi32"; exit 1; }
fi

# No call may target a null terminator. The three extra imports occupy the slots after the
# built-in table; the terminator between the two groups is the one that must not be used.
# Reading the emitted immediates is the direct check, and it needs no Windows to run.
if command -v objdump >/dev/null 2>&1; then
  slots=$(objdump -d "$T/inter.exe" 2>/dev/null | grep -oE 'mov +\$0x3[0-9a-f]+,%eax' | grep -oE '0x3[0-9a-f]+' | sort -u)
  for s in $slots; do
    dec=$((s))
    # slot 54 is the terminator between the user32 and gdi32 groups in this program
    [ "$dec" = "54" ] && { echo "a call targets slot 54, the null terminator between two DLL groups"; exit 1; }
  done
fi

# Both counterparts must agree, byte for byte: this bug lived in the slot arithmetic, and
# a fix in only one of them would leave a fresh clone building the broken binary.
"$ROOT/bin/wantzel0" "$T/inter.wz" "$T/inter0.exe" --target=windows || { echo "the C bootstrap cannot compile interleaved imports"; exit 1; }
cmp -s "$T/inter.exe" "$T/inter0.exe" || { echo "the two compilers disagree on interleaved imports"; exit 1; }

echo "  interleaved imports get the slots the import table uses, and both compilers agree"
