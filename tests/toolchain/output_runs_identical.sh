# The compiler's OUTPUT is no longer byte-identical to 0.4.0 -- elimination of unused
# routines (see eliminate in src/wantzel.wz) removes bytes the old compiler kept, by
# design, so a byte-for-byte comparison of a plain build (what this script's predecessor,
# output_identical.sh, did) cannot pass any more. What still has to hold, for the SAME
# fixed set of programs read from output_sha256.txt beside this script:
#
#   exe      RUNS with the same stdout+stderr and exit code as 0.4.0 gave, for every
#            program that has a tests/<...>.out beside it (deterministic, no network); a
#            program with no .out (most of examples/, which want a socket or a terminal --
#            see tests/examples/examples_compile.sh) only has to still COMPILE
#   debug    stays byte-identical, hash and all -- --debug skips elimination (see the
#            comment above eliminate), so a debug build is exactly the pre-elimination
#            build, and output_sha256.txt already has the right hash for it
#   refused  stays byte-identical -- a program that never reaches code generation cannot
#            be touched by a change to code generation, and the hash already covers that
#
# WHEN IT IS RED. For an "exe" entry: either eliminate marked something live as dead
# (wrong runtime behaviour or a program that no longer compiles/runs), or the language or
# library itself changed on purpose, in which case update the .out beside the source with
# wztest --update. For a "debug" or "refused" entry: unrelated compiler behaviour changed
# -- if that is intended, regenerate ITS hash with the compiler that is meant to be right:
#
#     sh tests/toolchain/output_runs_identical.sh --update bin/wantzel
#
# (this only touches debug/refused lines and "exe" lines with no .out; an "exe" line with
# a .out is not a hash and --update leaves it as it is -- fix its .out with wztest instead)
# Never regenerate to make an unexplained difference go away: that is the one thing this
# test is here to catch.
cd "${ROOT:?}" || exit 2
REF=tests/toolchain/output_sha256.txt
CC=$WANTZEL
update=0
if [ "$1" = "--update" ]; then update=1; CC=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); fi
[ -x "$CC" ] || { echo "no compiler at $CC"; exit 2; }
have_timeout=0; command -v timeout >/dev/null 2>&1 && have_timeout=1
run() { secs="$1"; shift; if [ "$have_timeout" -eq 1 ]; then timeout "$secs" "$@"; else "$@"; fi; }

n=0; same=0; bad=0

# runcheck <path> -- for a program with a .out beside it: compile, run in a private work
# directory (never the source directory -- see wztest's own comment on this), and compare
# stdout+stderr and the exit code against .out/.exit, honouring .args the same way wztest
# does. Returns "ok" or a description of the difference.
runcheck() {
  path=$1
  base=${path%.wz}
  rm -f "$T/o"
  if ! "$CC" "$path" "$T/o" >"$T/cerr" 2>&1; then
    echo "does not compile: $(head -1 "$T/cerr")"; return
  fi
  args=""; [ -f "$base.args" ] && args=$(cat "$base.args")
  wantrc=0; [ -f "$base.exit" ] && wantrc=$(cat "$base.exit")
  rm -rf "$T/work"; mkdir -p "$T/work"
  if [ -f "$base.stdin" ]; then
    ( cd "$T/work" && run 10 "$T/o" $args <"$base.stdin" >"$T/out" 2>&1 ); rc=$?
  else
    ( cd "$T/work" && run 10 "$T/o" $args >"$T/out" 2>&1 ); rc=$?
  fi
  if [ "$rc" != "$wantrc" ]; then
    echo "exit code $rc, expected $wantrc: $(head -3 "$T/out")"; return
  fi
  if ! cmp -s "$T/out" "$base.out"; then
    echo "output differs: $(diff -u "$base.out" "$T/out" | head -6)"; return
  fi
  echo "ok"
}

T=${T:-$(mktemp -d)}
: > "$T/new"
while read -r want kind path; do
  case "$want" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  case "$kind" in
    exe)
      base=${path%.wz}
      if [ -f "$base.out" ]; then
        got=$(runcheck "$path")
        if [ "$got" = "ok" ]; then same=$((same + 1))
        else bad=$((bad + 1)); printf '  DIFFERS  %-8s %s\n           %s\n' "$kind" "$path" "$got"; fi
      else
        rm -f "$T/o"
        if "$CC" "$path" "$T/o" >"$T/cerr" 2>&1; then same=$((same + 1))
        else
          bad=$((bad + 1))
          printf '  DIFFERS  %-8s %s\n           no longer compiles: %s\n' "$kind" "$path" "$(head -1 "$T/cerr")"
        fi
      fi
      # an "exe" line is not a hash -- --update never rewrites it, whether or not it has
      # a .out (fix that with wztest --update instead).
      printf '%s %s %s\n' "$want" "$kind" "$path" >> "$T/new"
      ;;
    debug|refused)
      # unaffected by elimination (debug skips it; a refusal never reaches codegen) --
      # still hashed exactly as output_identical.sh used to, so a regression there is
      # caught here too rather than needing a second script run alongside this one.
      rm -f "$T/o" "$T/o.wzdbg"
      case "$kind" in
        debug)
          "$CC" "$path" "$T/o" --debug >/dev/null 2>"$T/e"; rc=$?
          if [ $rc -ne 0 ]; then got="failed: $(head -1 "$T/e")"; else got=$(sha256sum <"$T/o" | cut -c1-64); fi
          ;;
        refused)
          "$CC" "$path" "$T/o" >/dev/null 2>"$T/e"; rc=$?
          if [ $rc -eq 0 ]; then got="compiled"; else got=$({ echo "exit $rc"; cat "$T/e"; } | sha256sum | cut -c1-64); fi
          ;;
      esac
      if [ $update -eq 1 ]; then
        printf '%s %s %s\n' "$got" "$kind" "$path" >> "$T/new"
        continue
      fi
      if [ "$got" = "$want" ]; then same=$((same + 1))
      else
        bad=$((bad + 1))
        printf '  DIFFERS  %-8s %s\n           0.4.0: %s\n           now:   %s\n' "$kind" "$path" "$want" "$got"
      fi
      printf '%s %s %s\n' "$want" "$kind" "$path" >> "$T/new"
      ;;
  esac
done < "$REF"

if [ $update -eq 1 ]; then
  { grep '^#' "$REF"; cat "$T/new"; } > "$T/ref" && cp "$T/ref" "$REF"
  echo "$n lines written to $REF with $CC (exe lines and .out files are untouched -- see the top of this script)"
  exit 0
fi

[ $n -gt 0 ] || { echo "$REF holds no programs"; exit 1; }
if [ $bad -gt 0 ]; then
  echo
  echo "$bad of $n programs differ from what 0.4.0 gave."
  exit 1
fi
echo "$n programs behave exactly as the 0.4.0 reference (run identically where a .out exists, still compile otherwise; debug and refused stay byte-identical)"
