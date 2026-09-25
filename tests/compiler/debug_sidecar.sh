# --debug writes <output>.wzdbg beside the binary and leaves the binary itself untouched.
#
# The sidecar is checked against the BYTES of the executable, not against what the compiler
# says about itself: the code at the address the line table gives for `x := 1234567` must be
# `mov eax, 1234567; mov [x], rax` with x at the address the global table gives, and the
# same for a local through its rbp offset. The format is docs/design.md.
. "$ROOT/tests/helpers.sh"

cat > "$T/p.wz" <<'EOF'
type Item = record
  key: int;
  flag: bool;
  weight: real;
  tag: array[0..3] of char;
end;

var
  x: int;
  items: array[0..9] of Item;
  s: str;

function twice(n: int; v: array of Item): int;
var y: int;
    buf: array[0..7] of char;
begin
  y := 1234567;
  buf[0] := 'a';
  return n * 2 + len(v);
end;

begin
  x := 1234567;
  x := twice(x, items[0..1]);
end.
EOF

# field <n> of the first record whose first words match the pattern
field() { grep -m1 "^$1 " "$D" | cut -d' ' -f"$2"; }
# <n> bytes of the executable at virtual address <va>, as one hex string
bytes_at() { od -An -t x1 -j "$(( $1 - textva + hdr ))" -N "$2" "$BIN" | tr -d ' \n'; }
# a 32-bit little-endian value as hex
le32() { v=$(( $1 & 4294967295 )); printf '%02x%02x%02x%02x' $(( v & 255 )) $(( (v >> 8) & 255 )) $(( (v >> 16) & 255 )) $(( (v >> 24) & 255 )); }

check() {  # check <target> <header bytes before the code> [compile options]
  tgt=$1; hdr=$2; shift 2
  "$WANTZEL" "$T/p.wz" "$T/plain-$tgt" "$@" 2>"$T/cerr" || { cat "$T/cerr"; exit 1; }
  "$WANTZEL" "$T/p.wz" "$T/dbg-$tgt" --debug "$@" 2>"$T/cerr" || { cat "$T/cerr"; exit 1; }
  cmp -s "$T/plain-$tgt" "$T/dbg-$tgt" || { echo "$tgt: the binary differs with --debug"; exit 1; }
  [ -f "$T/plain-$tgt.wzdbg" ] && { echo "$tgt: a sidecar appeared without --debug"; exit 1; }
  D="$T/dbg-$tgt.wzdbg"; BIN="$T/dbg-$tgt"
  [ -f "$D" ] || { echo "$tgt: no sidecar was written"; exit 1; }

  assert_eq "$tgt: version line" "$(head -1 "$D")" "wzdbg 1"
  assert_eq "$tgt: target line" "$(field target 2)" "$tgt"
  textva=$(field text 2); textlen=$(field text 3)
  bssva=$(field bss 2)

  # the globals: items (10 records of 32 bytes) follows x, s follows items. x is the first
  # global after the reserved slot at bss offset 0.
  xva=$(field 'global x' 3)
  assert_eq "linux: x sits at bss + 8" "$xva" "$(( bssva + 8 ))"
  assert_eq "$tgt: global x"      "$(grep -m1 '^global x ' "$D")"     "global x $xva int 0 0 0"
  assert_eq "$tgt: global items"  "$(grep -m1 '^global items ' "$D")" "global items $(( xva + 8 )) item 1 0 9"
  assert_eq "$tgt: global s"      "$(grep -m1 '^global s ' "$D")"     "global s $(( xva + 328 )) str 0 0 0"
  # the record and its fields: bool after int, real 8-aligned after the bool
  assert_eq "$tgt: record" "$(grep -m1 '^record ' "$D")" "record item 32 4"
  assert_eq "$tgt: fields" "$(grep '^field ' "$D" | tr '\n' ';')" \
    "field key 0 int 0 0 0;field flag 8 bool 0 0 0;field weight 16 real 0 0 0;field tag 24 char 1 0 3;"
  # the routine: parameters first, the array parameter as a slice, the local array in place
  fstart=$(field 'func twice' 3); fend=$(field 'func twice' 4)
  assert_eq "$tgt: func twice" "$(grep -m1 '^func twice ' "$D")" "func twice $fstart $fend 0 13 48 int"
  assert_eq "$tgt: params and locals" "$(sed -n '/^func twice /,/^line/p' "$D" | grep '^param\|^local' | tr '\n' ';')" \
    "param n -8 int 0 0 0;param v -16 item 2 0 0;local y -32 int 0 0 0;local buf -40 char 1 0 7;"
  assert_eq "$tgt: main" "$(grep -m1 '^main ' "$D" | cut -d' ' -f4-)" "0 22 0 void"
  # the line table: the header line is a prologue, the end line an epilogue, and the
  # routine's code starts exactly where its p entry is
  assert_eq "$tgt: prologue entry" "$(grep -m1 '^line .* 0 13 ' "$D")" "line $fstart 0 13 p"
  assert_eq "$tgt: epilogue entry" "$(grep -m1 '^line .* 0 20 ' "$D" | cut -d' ' -f3-)" "0 20 e"
  assert_eq "$tgt: main prologue"  "$(grep -m1 '^line .* 0 22 ' "$D" | cut -d' ' -f3-)" "0 22 p"
  # every line address ascends and lies inside the code
  awk -v lo="$textva" -v n="$textlen" '/^line /{ if ($2 < last || $2 < lo || $2 >= lo + n) { bad = 1 }; last = $2 } END { exit bad }' "$D" \
    || { echo "$tgt: line addresses are not ascending, or lie outside the code"; exit 1; }

  # THE BYTES. mov eax,1234567 = b8 87 d6 12 00; then the store.
  a=$(grep -m1 '^line .* 0 23 s' "$D" | cut -d' ' -f2)
  assert_eq "$tgt: code at line 23 (x := 1234567)" "$(bytes_at "$a" 13)" "b887d6120048890425$(le32 "$xva")"
  a=$(grep -m1 '^line .* 0 17 s' "$D" | cut -d' ' -f2)
  assert_eq "$tgt: code at line 17 (y := 1234567)" "$(bytes_at "$a" 12)" "b887d61200488985$(le32 -32)"
  # and the routine starts with push rbp; mov rbp,rsp; sub rsp,48
  assert_eq "$tgt: prologue bytes" "$(bytes_at "$fstart" 11)" "554889e54881ec30000000"
}

check linux 120

# an unknown option is refused
if "$WANTZEL" "$T/p.wz" "$T/o" --debugg 2>"$T/cerr"; then echo "--debugg was accepted"; exit 1; fi
assert_contains "the message names the options" "$(cat "$T/cerr")" "--debug"
echo "  the sidecar matches the bytes of the executable"
