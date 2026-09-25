# wantzel --lib: the library this compiler carries, as a list and as source.
#
#   wantzel --lib            the modules, one name per line, sorted, exit 0
#   wantzel --lib <module>   that module's source on stdout, byte for byte lib/<module>.wz
#   wantzel --lib <unknown>  a message on stderr, nothing on stdout, exit code not 0
#
# The list must be exactly the modules in lib/ -- the compiler was built from them, so one
# missing or one extra means the trailer is not what build.sh packed. And every module must
# come back byte for byte: this is the whole road a module travels, packed by lib/lz.wz at
# build time and unpacked by the compiler's own copy of lz.unpack, checked end to end.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

"$WANTZEL" --lib > "$T/list" 2>"$T/err" || { echo "wantzel --lib failed:"; cat "$T/err"; exit 1; }
ls lib/*.wz | sed 's|^lib/||; s|\.wz$||' | LC_ALL=C sort > "$T/want"
if ! cmp -s "$T/list" "$T/want"; then
  echo "wantzel --lib does not list exactly the modules in lib/:"
  diff "$T/want" "$T/list" | sed 's/^/  /'
  exit 1
fi

n=0
for m in $(cat "$T/want"); do
  "$WANTZEL" --lib "$m" > "$T/m" 2>"$T/err" || { echo "wantzel --lib $m failed:"; cat "$T/err"; exit 1; }
  cmp -s "$T/m" "lib/$m.wz" || { echo "wantzel --lib $m is not lib/$m.wz byte for byte"; exit 1; }
  n=$((n + 1))
done

if "$WANTZEL" --lib nosuchmodule > "$T/refused.out" 2>"$T/err"; then
  echo "wantzel --lib nosuchmodule succeeded"; exit 1
fi
[ -s "$T/refused.out" ] && { echo "wantzel --lib nosuchmodule wrote to stdout"; exit 1; }
assert_contains "the refusal names the module and says how to list them" "$(cat "$T/err")" \
  "no library module 'nosuchmodule' in this compiler; wantzel --lib lists them"

echo "wantzel --lib lists the $n modules of lib/, and gives each back byte for byte"
