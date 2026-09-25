# A damaged library trailer gives a message that says so -- never a crash, never a quietly
# smaller library, never a program compiled from damaged source.
#
# The trailer is read from the compiler's own file, and a file can be damaged: cut short
# by a download, patched by a tool that does not know it is there. Everything in it is
# checked before it is used -- the footer's digits, every index line, and every packed
# module on the way through the unpacker, which refuses rather than read or write past a
# buffer. Four kinds of damage, each on a copy of the compiler:
. "$ROOT/tests/helpers.sh"

printf 'import io;\nbegin\n  io.puts(STDOUT, "hi\\n");\nend.\n' > "$T/p.wz"
size=$(wc -c < "$WANTZEL")
ftr=$(tail -c 101 "$WANTZEL")
case "$ftr" in WZPARTS1*) ;; *) echo "the compiler under test carries no trailer"; exit 1 ;; esac
ioff=$(printf '%s' "$ftr" | cut -c10-21 | sed 's/^0*//')
ilen=$(printf '%s' "$ftr" | cut -c23-30 | sed 's/^0*//')
tstart=$((size - 101 - ilen - ioff))

# damaged <name> <expected text> <command...> -- the command fails with exit code 1 (not a
# signal, not a runtime error) and says <expected text>
damaged() {
  name=$1; want=$2; shift 2
  "$@" >"$T/lib.out" 2>"$T/err"; rc=$?
  [ $rc -eq 1 ] || { echo "$name: exit code $rc, expected 1"; cat "$T/err"; exit 1; }
  grep -q "runtime error" "$T/err" && { echo "$name: a runtime error instead of a message"; cat "$T/err"; exit 1; }
  assert_contains "$name" "$(cat "$T/err")" "$want"
  printf '  %s: refused with a message\n' "$name"
}
fresh() { cp "$WANTZEL" "$T/w"; chmod +x "$T/w"; }
poke() { printf "$2" | dd of="$T/w" bs=1 seek="$1" conv=notrunc 2>/dev/null; }

DAMAGED="the library trailer of this compiler is damaged"

# 1. a digit in the footer is not a digit
fresh; poke $((size - 101 + 12)) 'x'
damaged "footer digit" "$DAMAGED" "$T/w" "$T/p.wz" "$T/a"

# 2. the index is said to be longer than it is: its lines no longer add up
fresh; poke $((size - 101 + 22)) "$(printf '%08d' $((ilen + 1)))"
damaged "index length" "$DAMAGED" "$T/w" "$T/p.wz" "$T/a"

# 3. the packed text of io is overwritten: the unpacker must refuse it
line=$(dd if="$WANTZEL" bs=1 skip=$((tstart + ioff)) count="$ilen" 2>/dev/null | grep '^lib/io.wz ')
off=$(echo "$line" | cut -d' ' -f2); len=$(echo "$line" | cut -d' ' -f3)
[ -n "$off" ] || { echo "lib/io.wz is not in the index"; exit 1; }
fresh
dd if=/dev/zero bs=1 count=64 2>/dev/null | tr '\0' '\377' \
  | dd of="$T/w" bs=1 seek=$((tstart + off + len / 2)) conv=notrunc 2>/dev/null
damaged "packed module" "$DAMAGED" "$T/w" "$T/p.wz" "$T/a"
damaged "packed module through --lib" "$DAMAGED" "$T/w" --lib io
[ -s "$T/lib.out" ] && { echo "--lib wrote damaged text to stdout"; exit 1; }

# 4. cut short: the footer is gone, so there is no library -- and it says that
head -c $((size - 50)) "$WANTZEL" > "$T/w"; chmod +x "$T/w"
damaged "cut short" "this compiler carries no standard library" "$T/w" "$T/p.wz" "$T/a"
assert_contains "--version says the library is missing" "$("$T/w" --version)" "library MISSING"

echo "every damaged trailer is refused with a message"
