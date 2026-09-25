# Compile speed per SOURCE SHAPE, because one number for "how fast does Wantzel compile"
# cannot be made true.
#
# WHAT THIS MEASURES AND WHY IT IS THREE NUMBERS.  Measured 15-09-2026 on one machine,
# every compile checked to actually SUCCEED:
#
#   shape                          MB/s    lines/s
#   data as code (long literals)     163     41,000
#   schema- and tools-heavy            2     65,000
#   plain procedural code             18    667,000
#   the compiler's own source         17    598,000
#
# Lines per second spans a factor of sixteen and megabytes per second a factor of eighty,
# on the same compiler, purely because of what the source is made of. So neither unit is
# a property of the compiler: both are a property of the compiler AND the shape, and a
# figure quoted without saying which shape it came from cannot be defended.
#
# That is not hypothetical. The README said 236,000 lines/s one morning while the bench
# was already measuring 340,000, and nobody noticed; results.tsv caught it afterwards. A
# bound per shape catches it at once.
#
# THE TRAP WHILE BUILDING THIS, worth leaving written down: the first run of the
# tools-heavy case reported 185 MB/s, which was wonderful and false -- the generated
# program's include could not be resolved, so the compiler was timing an error exit. A
# speed measurement must assert that the work actually happened. Hence the || fail on
# every compile below.
. "$ROOT/tests/helpers.sh"

now_ms() { date +%s%N | cut -b1-13; }

gen="$T/gen"
"$WANTZEL" "$ROOT/tests/limits/progs/gen.wz" "$gen" >/dev/null \
  || { echo "could not build the generator"; exit 1; }

# <kind> <count> <name>
make() { "$gen" "$1" "$2" "$T/$3" "$ROOT" >/dev/null || { echo "generating $3 failed"; exit 1; }; }

# Every source is compiled ONCE up front and the result checked. This is separate from
# the timing on purpose: timeit runs inside $( ), and an `exit 1` there ends only the
# command substitution -- the script sails on with an empty measurement and the suite
# reports ok. Verified 15-09-2026 by breaking the include on purpose: the rate came back
# blank and the test still passed. A guard that only works outside a subshell is not a
# guard, so the check lives here, where a failure really does stop the script.
check() {
  "$WANTZEL" "$1" "$T/out.bin" >"$T/cerr" 2>&1 || {
    echo "compiling $1 failed -- timing a failed compile measures nothing:"
    cat "$T/cerr"
    exit 1
  }
}

# <source> -> milliseconds, fastest of five
timeit() {
  best=999999
  for i in 1 2 3 4 5; do
    t0=$(now_ms)
    "$WANTZEL" "$1" "$T/out.bin" >/dev/null 2>&1
    t1=$(now_ms)
    ms=$((t1 - t0))
    [ "$ms" -lt "$best" ] && best=$ms
  done
  [ "$best" -lt 1 ] && best=1
  echo "$best"
}

# chars per second in thousands, so a shell integer carries it
rate() { echo $(( $(wc -c < "$1") / $2 )); }   # bytes/ms == kB/s

make datseg   2000 data.wz      # long string literals: a generated data file
make tools    1000 tools.wz     # schemas and tools: much generated output per line
make routines 4000 proc.wz      # plain procedural code

check "$T/data.wz"
check "$T/tools.wz"
check "$T/proc.wz"

d=$(timeit "$T/data.wz");  dr=$(rate "$T/data.wz" "$d")
t=$(timeit "$T/tools.wz"); tr=$(rate "$T/tools.wz" "$t")
p=$(timeit "$T/proc.wz");  pr=$(rate "$T/proc.wz" "$p")

bench_report shape_data_kB_s  "$dr" kB/s
bench_report shape_tools_kB_s "$tr" kB/s
bench_report shape_proc_kB_s  "$pr" kB/s

echo "  data as code:      ${dr} kB/s  (${d} ms)"
echo "  schema and tools:  ${tr} kB/s  (${t} ms)"
echo "  procedural code:   ${pr} kB/s  (${p} ms)"
echo "  the spread between them is the point: no single rate describes this compiler"

# THE FLOORS, one per shape, in the .min files beside this script. Data and procedural
# sit at roughly half the lowest figure measured over repeated runs (data 148,000-170,000;
# procedural 15,800-18,500 kB/s on 15-09-2026). Half is deliberate: a bound tight enough to
# flap gets raised until it means nothing, and a halving of throughput is a regression by
# any reading.
#
# tools is tighter -- about 80% of the median (2,552-2,784 kB/s over five runs) -- because
# half the 2,960-3,060 kB/s measured on 15-09-2026 (1,400) already missed a real 30%
# regression: per-tool generated code that grew with the tool count, unnoticed until the
# shape itself was bisected. A floor loose enough to hide the thing it exists to catch is
# not a floor.
#
# They are per shape BECAUSE a single bound cannot exist here. A change that slowed
# schema generation by a third would disappear entirely into an average dominated by the
# data case, which runs fifty times faster per byte.
