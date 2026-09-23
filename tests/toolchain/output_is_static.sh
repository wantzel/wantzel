# The ELF this compiler writes depends on nothing, and that is construction not omission.
#
# WHY THIS IS WORTH A TEST. "No runtime, no libc, depends on nothing" is the promise on the
# front page, and it is the reason a download works without a toolchain. A dynamic section
# could appear without anyone deciding to add one -- and nothing else here would notice,
# because the program would still run on the machine that built it.
#
# MEASURED 22-09-2026 on a compiled hello: one program header, one PT_LOAD, no PT_INTERP and
# no PT_DYNAMIC. readelf says "there is no dynamic section in this file"; ldd says "not a
# dynamic executable".
#
# THE CONSEQUENCE IS ALSO WRITTEN DOWN, in docs/design.md: a program
# that needs an outside library calls it as a PROCESS, at ~308 us a spawn, because there is no
# way to link one in. That is a design choice, so this test guards the choice rather than
# reporting a fact.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

compile examples/hello.wz "$T/hello"

# ---- 1. NO DYNAMIC SECTION ---------------------------------------------------------------
if command -v readelf >/dev/null 2>&1; then
  d=$(readelf -d "$T/hello" 2>&1)
  case "$d" in
    *"no dynamic section"*) ;;
    *) echo "the output has a dynamic section:"; printf '%s\n' "$d" | head -5 | sed 's/^/  /'
       echo "  the promise is that a binary depends on nothing; see"
       echo "  docs/design.md"
       exit 1 ;;
  esac

  # ---- 2. AND NO INTERPRETER ---------------------------------------------------------
  #
  # PT_INTERP is what names the dynamic loader. Its absence is what makes the kernel run the
  # program directly rather than handing it to ld.so first -- worth ~280 us of startup, which
  # is the measurement behind keeping it this way.
  l=$(readelf -l "$T/hello" 2>&1)
  case "$l" in
    *INTERP*) echo "the output names a program interpreter (PT_INTERP)"; exit 1 ;;
  esac
  case "$l" in
    *DYNAMIC*) echo "the output carries a PT_DYNAMIC segment"; exit 1 ;;
  esac
  echo "  readelf: no dynamic section, no PT_INTERP, no PT_DYNAMIC"
else
  echo "  skipped the readelf checks: readelf is not installed"
fi

# ---- 3. ldd AGREES ------------------------------------------------------------------------
#
# A SECOND OPINION FROM A DIFFERENT TOOL. readelf reads the file; ldd asks the loader what it
# would do with it. Both saying the same thing is what makes this a fact rather than a parse.
if command -v ldd >/dev/null 2>&1; then
  out=$(ldd "$T/hello" 2>&1 || true)
  case "$out" in
    *"not a dynamic executable"*) echo "  ldd: not a dynamic executable" ;;
    *) echo "ldd reports dependencies:"; printf '%s\n' "$out" | head -5 | sed 's/^/  /'; exit 1 ;;
  esac
else
  echo "  skipped the ldd check: ldd is not installed"
fi

# ---- 4. AND IT RUNS ----------------------------------------------------------------------
#
# The point of all of the above is a binary that executes with nothing installed. Checking
# the headers without running it would be checking a shape rather than a promise.
# timeout DIRECTLY, not the suite's run helper: that one is defined in wztest and is not in
# scope inside a test script -- which showed up as "the binary does not run" for a binary
# that runs perfectly.
out=$(timeout 5 "$T/hello" 2>&1) || { echo "the binary does not run"; exit 1; }
[ -n "$out" ] || { echo "the binary ran but printed nothing"; exit 1; }

echo "ok: static by construction -- no dynamic section, no interpreter, and it runs"
