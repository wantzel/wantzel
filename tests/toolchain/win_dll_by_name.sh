# A program can reach a DLL function the compiler has never heard of.
#
# This is the property, and it is the whole point: MessageBoxA is not in the compiler's
# import table -- grep the source and you will not find it. The program below names it, and
# the PE gets an import entry for it. Reaching a new Windows API is data, not a compiler
# change.
#
# Before this, every new function meant a line in impname(), the counters updated, both
# counterparts changed and the fixed point rebuilt. That is the barrier this test guards.
. "$ROOT/tests/helpers.sh"

# Not just any mention -- an actual import entry, which is a `return "..."` in impname().
grep -q 'return "MessageBoxA"' "$ROOT/src/wantzel.wz" && { echo "MessageBoxA is in the compiler's import table after all; this test no longer proves anything"; exit 1; }

cat > "$T/byname.wz" <<'WZ'
var title, text: array[0..63] of char;
  i: int;
begin
  i := 0; while i < slen("t") do begin title[i] := schar("t", i); i := i + 1; end;
  title[i] := chr(0);
  i := 0; while i < slen("x") do begin text[i] := schar("x", i); i := i + 1; end;
  text[i] := chr(0);
  winapi("user32.dll", "MessageBoxA", 0, addr(text[0]), addr(title[0]), 0);
end.
WZ

"$ROOT/bin/wantzel" "$T/byname.wz" "$T/byname.exe" --target=windows || { echo "naming a DLL function did not compile"; exit 1; }

# the name must really be in the import table, not merely accepted by the parser
strings "$T/byname.exe" | grep -q "^MessageBoxA$" || { echo "MessageBoxA is not in the .exe"; exit 1; }

# Every directory entry must NAME a DLL. A second entry for user32 is expected and legal:
# the built-in imports and the source-named ones are two runs in the name table, and
# keeping them separate is what keeps the IAT in step with the names. What must never
# happen is an entry with an empty name -- that was the bug this test was written for.
#
# An empty name shows up as a directory entry whose name pointer lands on the NUL that
# terminates the previous string, so the .exe would carry one fewer DLL name than it has
# entries. Counting the names is enough, and needs no parser: every DLL this binary
# imports must appear as a string in it.
for dll in KERNEL32.dll WS2_32.dll ADVAPI32.dll USER32.dll user32.dll; do
  strings "$T/byname.exe" | grep -qx "$dll" || { echo "$dll is missing from the .exe"; exit 1; }
done

# Both counterparts must know this form. boot.c is what a fresh clone compiles with, so a
# feature only in src/wantzel.wz would leave a clone unable to build a program that uses
# it -- and the fixed point would not notice, because the compiler's own source does not
# use it. That gap existed for a while; this line closes it.
"$ROOT/bin/wantzel0" "$T/byname.wz" "$T/byname0.exe" --target=windows || { echo "the C bootstrap cannot compile a named import"; exit 1; }
cmp -s "$T/byname.exe" "$T/byname0.exe" || { echo "the two compilers disagree on a named import"; exit 1; }

echo "  every imported DLL is named, both compilers agree, and MessageBoxA came from the source"
