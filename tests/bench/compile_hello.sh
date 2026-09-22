# A hello-world must compile in single-digit milliseconds, on both targets.
#
# WHY THIS HAS A CEILING OF ITS OWN, next to the throughput measurement in
# compile_self.sh. That one asks how fast the compiler is over thousands of lines; this one
# asks what the SMALLEST possible compile costs, which is a different question and the one a
# person actually feels. It is the number in the editor's status bar after every keystroke
# that ends in F9, and the whole argument for the short loop rests on it being invisible.
#
# THE BUDGET IS 10 ms AND THAT IS A HARD CEILING, asked for on 16-09-2026 after a reported
# 150 ms turned out to be something else entirely (see below). Today it measures 2 ms on
# this machine, so there is five times the headroom -- which is the point: a ceiling only
# earns its place if crossing it means something really changed.
#
# WHAT THIS DOES NOT MEASURE, and it matters because the 150 ms report was real:
#
#   the compiler, native on Linux      2 ms     <- what this test guards
#   an EMPTY .exe started under Wine   48 ms    <- Wine's process startup, before any work
#   the compiler under Wine, direct    54 ms
#   the same through `cmd.exe /c`     141 ms    <- what the editor's own timer reports
#
# So the editor showing 150 ms is not a compiler regression: about 50 ms is Wine starting a
# process at all, and another 90 ms is cmd.exe starting before that. On real Windows there
# is no Wine and no wrapper, and the editor's own measurement of 2 ms for a compile has been
# seen there. Measuring the compiler through two layers of process creation and calling the
# result "compile time" is the mistake this comment exists to prevent.
#
# Which is also why this test runs the compiler DIRECTLY. Anything else measures the harness.
. "$ROOT/tests/helpers.sh"

now_ms() { date +%s%N | cut -b1-13; }

cat > "$T/hello.wz" <<'WZ'
include "io.wz";

begin
  io.puts(STDOUT, "hello\n");
end.
WZ

# Three runs, the fastest counts: the machine may be busy, and the question is what the
# compiler can do rather than what the neighbours allow.
best=999999
for i in 1 2 3; do
  t0=$(now_ms)
  "$WANTZEL" "$T/hello.wz" "$T/hello.bin" >/dev/null || { echo "compiling hello.wz failed"; exit 1; }
  t1=$(now_ms)
  ms=$((t1 - t0))
  [ "$ms" -lt "$best" ] && best=$ms
done
[ -x "$T/hello.bin" ] || { echo "no executable produced"; exit 1; }

# AND THE WINDOWS TARGET TOO, because that is what the editor compiles and it walks a
# different path through the code generator -- the import table, the PE headers. A ceiling
# that only covers ELF would miss a regression the editor would be the first to feel.
bestwin=999999
for i in 1 2 3; do
  t0=$(now_ms)
  "$WANTZEL" "$T/hello.wz" "$T/hello.exe" --target=windows >/dev/null || { echo "compiling for windows failed"; exit 1; }
  t1=$(now_ms)
  ms=$((t1 - t0))
  [ "$ms" -lt "$bestwin" ] && bestwin=$ms
done

[ "$best" -lt 1 ] && best=1
[ "$bestwin" -lt 1 ] && bestwin=1

bench_report compile_hello_ms "$best" ms
bench_report compile_hello_windows_ms "$bestwin" ms
