# The compiler must be usable as a COMPONENT: included by another program, called from it,
# and survivable when the compile fails.
#
# WHY THIS EXISTS. src/wantzel.wz used to be one file ending in `end.`, which makes it a
# PROGRAM -- and the parser allows exactly one of those per compilation. So
# `include "wantzel.wz";` followed by your own `begin` gave "text after the end of the
# program", and the only way to compile from another program was to find, ship and start a
# second binary. Every path problem of 16/17-09-2026 came from that: finding the compiler on
# PATH, finding lib/ beside it, and execve receiving an empty environment.
#
# Since the split, src/compiler.wz has no main program and src/wantzel.wz is the thin
# command-line program around it.
#
# THE SECOND HALF IS THE FORK, and it is the part that is easy to get wrong. An error still
# calls halt() -- from 234 places across 45 mutually recursive routines, which is why they
# were not rewritten. A host that must survive a failed compile runs it in a child. This
# test fails if either half regresses: if compiler.wz grows a main program, or if a failed
# compile takes the host down with it.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# lib/ beside the host, because the host IS the compiler now and resolves includes against
# its own location.
mkdir -p "$T/work"
cp -r lib "$T/work/lib"
SRC=$(cd "$ROOT" && pwd)/src

cat > "$T/work/host.wz" <<WZ
// EVERY NAME IS PREFIXED h. -- the language has ONE global namespace and the compiler owns
// the short ones (i, out, src, pos, line). A host that declares its own \`i\` gets
// "duplicate global declaration", which is measured and not hypothetical.
include "io.wz";
include "proc.wz";
include "$SRC/compiler.wz";

var
  h.src: array[0..255] of char;
  h.out: array[0..255] of char;
  h.pid, h.st: int;

function h.compile: int;
var k: int;
begin
  h.pid := proc.fork;
  if h.pid < 0 then return 0 - 1;
  if h.pid = 0 then
  begin
    k := 0;
    while h.src[k] <> chr(0) do begin pathbuf[k] := h.src[k]; k := k + 1; end;
    pathbuf[k] := chr(0);
    k := 0;
    while h.out[k] <> chr(0) do begin outname[k] := h.out[k]; k := k + 1; end;
    outname[k] := chr(0);
    outnamelen := k;
    winmode := 0;
    setlibdir;
    halt(compile);
  end;
  h.st := proc.wait(h.pid);
  if h.st <= 0 then return 0 - 1;
  return proc.exitcode(proc.status[0]);
end;

procedure h.put(dst: array of char; s: str);
var k: int;
begin
  k := 0;
  while (k < slen(s)) and (k < len(dst) - 1) do
  begin dst[k] := schar(s, k); k := k + 1; end;
  dst[k] := chr(0);
end;

procedure h.try(s: str; o: str);
begin
  h.put(h.src, s);
  h.put(h.out, o);
  io.puts(STDOUT, "exit ");
  io.putn(STDOUT, h.compile);
  io.puts(STDOUT, "\n");
end;

begin
  h.try("good.wz", "good.bin");
  h.try("bad.wz", "bad.bin");
  io.puts(STDOUT, "host alive\n");
end.
WZ

printf 'include "io.wz";\n\nbegin\n  io.puts(STDOUT, "from inside\\n");\nend.\n' > "$T/work/good.wz"
printf 'include "io.wz";\n\nbegin\n  var n: integer;\nend.\n' > "$T/work/bad.wz"

compile "$T/work/host.wz" "$T/work/host"

out=$(cd "$T/work" && ./host 2>/dev/null)
assert_eq "a good source compiles, a bad one fails, and the host outlives both" \
  "$out" "exit 0
exit 1
host alive"

# and the binary the child produced is real
assert_eq "the compiled program runs" "$(cd "$T/work" && ./good.bin)" "from inside"

# THE PROPERTY, NOT THE FILE: compiler.wz must have no main program, or nothing can include
# it. `end.` is what marks one -- a routine ends with `end;` and only the program ends with
# a dot, so this is the exact marker. (Counting bare `begin` lines does not work: every
# routine body starts with one at column 0.)
assert_eq "src/compiler.wz has no main program" \
  "$(grep -cE '^end\.' "$ROOT/src/compiler.wz")" "0"

# and the program half still has exactly one, or there is no command-line compiler
assert_eq "src/wantzel.wz is still a program" \
  "$(grep -cE '^end\.' "$ROOT/src/wantzel.wz")" "1"
