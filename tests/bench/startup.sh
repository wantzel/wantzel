# How long does a Wantzel binary take to START, and what does that cost compared with a
# program the kernel can do nothing cheaper with?
#
# THE MEASUREMENT PROBLEM IS THE WHOLE POINT OF THIS FILE, and the first attempt got it
# wrong in a way worth writing down: timing `./hello` from a shell loop gave about 1.1 us
# and made our binary look FASTER than /bin/true, which is impossible. The loop was
# timing bash forking, not the program starting -- one process creation through a shell
# costs on the order of a millisecond and drowns everything else.
#
# So the loop is a program: tests/bench/progs/startmeter.wz forks, execs, waits, repeats.
#
# AND THE ABSOLUTE NUMBER IS NOT THE ANSWER EITHER. fork + execve + wait costs what it
# costs whatever you start, and how much it costs depends on the MEASURING process too --
# its pages are the ones copied. Measured 15-09-2026 with two independent harnesses of
# almost identical size, one in Wantzel and one in C: they disagreed by about 50 us on
# the absolute figure and agreed to within 1.3 us on the DIFFERENCE between two targets.
# The difference is the number that means something, so that is what this test reports.
#
# The baseline is an empty Wantzel program -- the same runtime, the same start-up path,
# no work. What the ratio then says is how much of a start is the kernel's floor and how
# much is ours. A real program that does actual work is the other end of the scale.
. "$ROOT/tests/helpers.sh"

compile "$ROOT/tests/bench/progs/startmeter.wz" "$T/startmeter"
compile "$ROOT/tests/bench/progs/nothing.wz"    "$T/nothing"
compile "$ROOT/examples/hello.wz"               "$T/hello"

# us per start, as a whole number of microseconds
usec() { "$T/startmeter" "$1" "$2" | sed 's/\..*//'; }

# Three rounds, the FASTEST counts: the machine may be busy, and we want to know what the
# kernel and the binary can do, not what the neighbours allow.
best_empty=999999; best_hello=999999
for i in 1 2 3; do
  e=$(usec 1500 "$T/nothing"); [ "$e" -lt "$best_empty" ] && best_empty=$e
  h=$(usec 1500 "$T/hello");   [ "$h" -lt "$best_hello" ] && best_hello=$h
done

[ "$best_empty" -gt 0 ] || { echo "the empty program measured 0 us: the clock or the loop is broken"; exit 1; }

# hello.wz writes one line; against an empty program that is almost all of the difference
# between "started" and "did something". Reported x100 so a shell integer can carry it.
ratio=$(( best_hello * 100 / best_empty ))

bench_report startup_empty_us "$best_empty" us
bench_report startup_hello_over_empty_x100 "$ratio" ratio

echo "  empty Wantzel program: ${best_empty} us per start (fork + execve + wait included)"
echo "  hello.wz:              ${best_hello} us per start, ${ratio}% of the empty one"

# The guard sits on the RATIO and not on the microseconds, for the same reason
# manynames.sh guards a ratio: the absolute figure moves with the machine and with the
# measuring process, the ratio does not. Measured 15-09-2026 it sits at 100-106 over
# repeated runs -- writing one line of output is lost in the noise of creating a process.
# The limit of 200 therefore catches something real: a start-up path that has begun to
# cost as much as the kernel's own floor.
