# Does compile time still grow IN STEP with the number of names, or faster than it?
#
# This is the regression guard for a defect that was in the compiler for a long time
# without anyone noticing: looking a name up walked the whole name list, so every
# reference cost time proportional to the names already declared and the total grew with
# the SQUARE of the program. It stayed invisible because the compiler's own source is
# small enough that the loss disappears in the noise; it only shows on a program several
# times that size.
#
# So this test does not measure speed -- compile_self.sh does that. It measures the
# SHAPE of the growth: compile the same kind of program at two sizes, one twice the
# other, and divide. Doubling the names should roughly double the time. Four times the
# time means the lookup walks a list again.
#
# The ratio is reported rather than the milliseconds, because the ratio is what carries
# the meaning and what stays comparable between machines.
. "$ROOT/tests/helpers.sh"

now_ms() { date +%s%N | cut -b1-13; }

gen="$T/gen"
"$WANTZEL" "$ROOT/tests/limits/progs/gen.wz" "$gen" >/dev/null \
  || { echo "could not build the generator"; exit 1; }

# The fastest of three runs at each size: we want what the compiler can do, not what a
# busy machine allows. Times are floored at 1 ms so the division is always defined.
timeit() {   # <source> -> milliseconds
  best=999999
  for i in 1 2 3; do
    t0=$(now_ms)
    "$WANTZEL" "$1" "$T/out.bin" >/dev/null || { echo "compiling $1 failed"; exit 1; }
    t1=$(now_ms)
    ms=$((t1 - t0))
    [ "$ms" -lt "$best" ] && best=$ms
  done
  [ "$best" -lt 1 ] && best=1
  echo "$best"
}

"$gen" globals 8192  "$T/g8192.wz"  >/dev/null || { echo "generating 8192 globals failed"; exit 1; }
"$gen" globals 16384 "$T/g16384.wz" >/dev/null || { echo "generating 16384 globals failed"; exit 1; }

small=$(timeit "$T/g8192.wz")
large=$(timeit "$T/g16384.wz")

# In hundredths, so a shell without floating point can still say 2.15.
ratio=$((large * 100 / small))

bench_report manynames_8192_ms  "$small" ms
bench_report manynames_16384_ms "$large" ms
bench_report manynames_ratio_x100 "$ratio" x100
