# Naming a function the compiler already imports must REUSE its slot, not add a second one.
#
# The compiler carries 48 imports of its own because the runtime needs them before user code
# runs. A program is free to name one of those itself -- winapi("kernel32.dll", "WriteFile")
# is ordinary source -- and when it does, extslot must hand back the existing slot.
#
# A second entry for the same function would not be a cosmetic wart: the two would be
# separate IAT slots for one address, and the name table and the address table are already
# the pair that has to stay in step (see win_interleaved_imports.sh). One name, one slot.
. "$ROOT/tests/helpers.sh"

cat > "$T/reuse.wz" <<'WZ'
var buf: array[0..63] of char;
  k: int;
begin
  buf[0] := chr(104); buf[1] := chr(105); buf[2] := chr(0);
  // WriteFile IS one of the compiler's own imports: this must reuse it.
  k := winapi("kernel32.dll", "WriteFile", 0, addr(buf[0]), 2, addr(buf[0]), 0);
  // MessageBoxA is NOT: this one must be added, so the test proves the difference
  // rather than merely proving that nothing was imported.
  k := winapi("user32.dll", "MessageBoxA", 0, addr(buf[0]), addr(buf[0]), 0);
end.
WZ

"$ROOT/bin/wantzel" "$T/reuse.wz" "$T/reuse.exe" --target=windows || { echo "naming a built-in did not compile"; exit 1; }

if command -v objdump >/dev/null 2>&1; then
  imports=$(objdump -x "$T/reuse.exe" 2>/dev/null | sed -n '/The Import Tables/,/Sections:/p')

  # exactly one WriteFile: the built-in slot was reused
  n=$(printf '%s\n' "$imports" | grep -c '  WriteFile$')
  [ "$n" = "1" ] || { echo "WriteFile appears $n times in the import table, expected 1 (reuse failed)"; exit 1; }

  # and the new name really was added, so the comparison means something
  printf '%s\n' "$imports" | grep -q '  MessageBoxA$' || { echo "MessageBoxA was not imported at all"; exit 1; }
fi

# Both compilers must agree: a fresh clone builds with bin/wantzel0.
"$ROOT/bin/wantzel0" "$T/reuse.wz" "$T/reuse0.exe" --target=windows || { echo "the C bootstrap cannot compile a reused built-in"; exit 1; }
cmp -s "$T/reuse.exe" "$T/reuse0.exe" || { echo "the two compilers disagree on reusing a built-in import"; exit 1; }

echo "  naming a built-in reuses its slot, a new name is added, and both compilers agree"
