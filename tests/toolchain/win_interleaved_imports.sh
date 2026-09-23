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
# The terminators come from the IAT in the file, not from a number written here: which
# slot separates two groups moves whenever a DLL group is added in front -- the Windows
# runtime itself imports one ws2_32 function by name, so that group comes first in every
# executable -- and a fixed number then names a slot that is in use. Data directory 12 of
# the optional header gives the IAT's RVA and size; the .rdata section header says where
# that RVA sits in the file. Every zero entry is a terminator, and no call may target it.
le32at() { od -An -t u4 -j "$1" -N 4 "$2" | tr -d ' '; }
u64at()  { od -An -t u8 -j "$1" -N 8 "$2" | tr -d ' '; }
opt=$(( $(le32at 60 "$T/inter.exe") + 24 ))                 # e_lfanew + PE signature + COFF header
iatrva=$(le32at $(( opt + 112 + 12 * 8 )) "$T/inter.exe")
iatsz=$(le32at $(( opt + 112 + 12 * 8 + 4 )) "$T/inter.exe")
rdrva=$(le32at $(( opt + 240 + 40 + 12 )) "$T/inter.exe")   # second section header: .rdata
rdraw=$(le32at $(( opt + 240 + 40 + 20 )) "$T/inter.exe")
iatoff=$(( iatrva - rdrva + rdraw ))
nslots=$(( iatsz / 8 ))
terminators=""
i=0
while [ $i -lt $nslots ]; do
  [ "$(u64at $(( iatoff + 8 * i )) "$T/inter.exe")" = "0" ] && terminators="$terminators $i"
  i=$(( i + 1 ))
done
case "$terminators" in *" "*" "*" "*) ;; *) echo "expected at least three terminators in the IAT, found:$terminators"; exit 1 ;; esac

# A slot is loaded with `mov eax, imm32` and pushed (b8 xx 00 00 00 50). The slots of this
# program's imports all lie in 48..63, so only an immediate of that size is looked at: a
# looser match once picked up an unrelated constant. The bytes are read directly, so this
# needs no disassembler.
slots=$(od -An -v -t x1 "$T/inter.exe" | tr -d ' \n' | grep -oE 'b83[0-9a-f]00000050' | cut -c3-4 | sort -u)
[ -n "$slots" ] || { echo "no slot-loading mov found in the code"; exit 1; }
for s in $slots; do
  dec=$(( 0x$s ))
  for t in $terminators; do
    [ "$dec" = "$t" ] && { echo "a call targets slot $dec, a null terminator between two DLL groups"; exit 1; }
  done
done

# Both counterparts must agree, byte for byte: this bug lived in the slot arithmetic, and
# a fix in only one of them would leave a fresh clone building the broken binary.
"$ROOT/bin/wantzel0" "$T/inter.wz" "$T/inter0.exe" --target=windows || { echo "the C bootstrap cannot compile interleaved imports"; exit 1; }
cmp -s "$T/inter.exe" "$T/inter0.exe" || { echo "the two compilers disagree on interleaved imports"; exit 1; }

echo "  interleaved imports get the slots the import table uses, and both compilers agree"
