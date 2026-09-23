# The two compilers write the same debug sidecar, byte for byte, on both targets.
#
# The fixed point does not cover this: the compiler's own source is built without --debug,
# so a sidecar that only one of the two counterparts writes correctly keeps every stage
# byte-identical. So: compile the same programs with both, with --debug, and compare the
# sidecar as strictly as the binary. The compiler's own source is the largest program at
# hand and exercises every record kind; the small one has a record type, an array
# parameter and a local array, which the compiler's source does not combine in one routine.
. "$ROOT/tests/helpers.sh"

cat > "$T/p.wz" <<'EOF'
type Item = record
  key: int;
  tag: array[0..3] of char;
end;
var items: array[0..9] of Item;
function first(v: array of Item): int;
var buf: array[0..7] of char;
begin
  buf[0] := 'a';
  return v[0].key;
end;
begin
  items[1].key := first(items[0..1]);
end.
EOF

both() {   # both <name> <source> [options]
  name=$1; src=$2; shift 2
  "$ROOT/bin/wantzel"  "$src" "$T/a" --debug "$@" 2>"$T/ea" || { echo "$name: the self-hosted compiler failed:"; cat "$T/ea"; exit 1; }
  "$ROOT/bin/wantzel0" "$src" "$T/b" --debug "$@" 2>"$T/eb" || { echo "$name: the C compiler failed:"; cat "$T/eb"; exit 1; }
  cmp -s "$T/a" "$T/b" || { echo "$name: the two compilers emit different bytes"; exit 1; }
  cmp -s "$T/a.wzdbg" "$T/b.wzdbg" || { echo "$name: the two compilers write different sidecars"; diff "$T/a.wzdbg" "$T/b.wzdbg" | head -5; exit 1; }
  [ -s "$T/a.wzdbg" ] || { echo "$name: the sidecar is empty"; exit 1; }
  rm -f "$T/a" "$T/b" "$T/a.wzdbg" "$T/b.wzdbg"
}

both "a small program, Linux"   "$T/p.wz"
both "a small program, Windows" "$T/p.wz" --target=windows
both "the compiler, Linux"      "$ROOT/src/wantzel.wz"
both "the compiler, Windows"    "$ROOT/src/wantzel.wz" --target=windows
echo "  both compilers write the same sidecar on both targets"
