# Wine is used where it is needed, and nowhere else.
#
# THE QUESTION THIS ANSWERS is not "can we get rid of wine" -- we cannot, and should not want
# to. A binary nobody has run is not evidence: win_winproc.sh checks that Windows calls a
# callback we registered, through EnumWindows, and no amount of byte inspection sees that.
#
# THE ANSWER IS THE BOUNDARY. Half of the Windows tests need no emulator at all: they compare
# the PE header, the import table or the bytes two compilers produce, which is a cmp and costs
# milliseconds. The other half runs a program. Both are worth having and NEITHER is a cheaper
# version of the other -- they check different things.
#
# WHAT THIS TEST DOES is keep the count from drifting the wrong way. A new Windows test that
# reaches for wine when the bytes would have answered makes the suite slower for nothing, and
# that is how a fast suite becomes one people stop running.
#
# MEASURED 22-09-2026: 5 tests use wine, 5 do not, and --toolchain runs in 8 seconds.
# The sixth, win_recv_reset.sh, has to run the program: whether a peer's reset reaches
# recv as an error or as a byte count is invisible in the bytes of the executable.
# The seventh, win_dns.sh, runs the resolver of lib/dns.wz: whether a UDP socket is UDP, a
# non-blocking connect says EINPROGRESS, and GetNetworkParams answers are all questions about
# what the program DOES.
# The eighth, win_mcp_big.sh, runs an MCP server on a 10 MB message: whether an anonymous
# mapping of that size is usable and really given back is invisible in the bytes too.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# COMMENTS STRIPPED BEFORE COUNTING. win_backend_bytes.sh says "no wineserver, no orphan
# processes" in its header and would otherwise be counted as a wine test -- the mention is
# documentation, not use. That mistake was made while writing this check.
wine=0; bytes=0; winelist=""
for f in tests/toolchain/win_*.sh; do
  if sed 's/#.*//' "$f" | grep -q "wine"; then
    wine=$((wine + 1)); winelist="$winelist $(basename "$f")"
  else
    bytes=$((bytes + 1))
  fi
done

[ "$wine" -gt 0 ] || { echo "no test uses wine at all -- has the runner been renamed?"; exit 1; }
[ "$bytes" -gt 0 ] || { echo "every Windows test uses wine; the byte-level ones are gone"; exit 1; }

# THE CEILING IS A NUMBER HERE, not derived from the tests it guards. A limit read from the
# thing it is watching grows with it and stops meaning anything -- which is exactly what a
# gate elsewhere in this project did before it was caught by sabotage.
CEILING=8
if [ "$wine" -gt "$CEILING" ]; then
  echo "$wine Windows tests use wine, and the ceiling is $CEILING:"
  printf '%s\n' "$winelist" | tr ' ' '\n' | grep . | sed 's/^/  /'
  echo "  before reaching for wine, ask whether the BYTES answer the question:"
  echo "    the PE header, the import table, or a cmp between two compilers' output"
  echo "  if the test really has to RUN the program, raise this ceiling and say why"
  exit 1
fi

# ---- AND THE FAST HALF MUST NOT SHRINK --------------------------------------------------
#
# The other direction matters too: converting a byte test into a wine test would keep the
# ceiling happy while making the suite slower.
FLOOR=5
if [ "$bytes" -lt "$FLOOR" ]; then
  echo "only $bytes Windows tests avoid wine, and the floor is $FLOOR"
  echo "  a byte-level check that became a wine check is a step backwards"
  exit 1
fi

echo "ok: $wine Windows tests use wine, $bytes answer from the bytes"
