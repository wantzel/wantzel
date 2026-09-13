# The compiler over its own source: lines per second, as a measure of raw throughput.
#
# Compile speed is one of the reasons this language exists -- the short loop between
# writing a line and knowing whether it is right is the most valuable thing a language can
# give you, and that loop is exactly as short as this measurement says. A regression here
# is not a detail but touches the reason the project exists; that is why a hard floor
# sits next to it (.min).
#
# Why src/wantzel.wz as the yardstick: it is real code, thousands of lines, without the
# large constant data tables that muddy a measurement. And it is the source we compile
# anyway, so the measurement keeps growing with the compiler itself.
. "$ROOT/tests/helpers.sh"

now_ms() { date +%s%N | cut -b1-13; }

lines=$(wc -l < "$ROOT/src/wantzel.wz")

# Three runs; the fastest counts. The machine may be busy, and we want to know what the
# compiler can do, not what the neighbours allow.
best=999999
for i in 1 2 3; do
  t0=$(now_ms)
  "$WANTZEL" "$ROOT/src/wantzel.wz" "$T/self.bin" >/dev/null || { echo "compiling src/wantzel.wz failed"; exit 1; }
  t1=$(now_ms)
  ms=$((t1 - t0))
  [ "$ms" -lt "$best" ] && best=$ms
done
[ -x "$T/self.bin" ] || { echo "no executable produced"; exit 1; }
[ "$best" -lt 1 ] && best=1

bench_report compile_self_ms "$best" ms
bench_report compile_lines_per_s $((lines * 1000 / best)) lines/s
