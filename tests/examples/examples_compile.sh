# Every program in examples/ compiles, for both targets.
#
# The examples are the first Wantzel most people read, and a broken one is worse
# than a missing one: it teaches a form that does not work. Nothing guarded them
# until 13-09-2026, because the suite only ever looked inside tests/.
#
# This checks that they COMPILE, not what they do -- most of them want a socket, a
# terminal or an MCP client to do anything, and a test that needs those would be
# testing the network rather than the language. Behaviour is covered by tests/lib.
. "$ROOT/tests/helpers.sh"

# WINDOWS-ONLY EXAMPLES. A program whose subject IS the Win32 API cannot build for Linux --
# winapi() refuses at compile time, which is correct and is itself demonstrated in
# tests/toolchain/win_examples_build.sh. They are named here rather than detected, so adding
# one is a decision someone takes on purpose: an example that only builds for Windows is a
# narrower promise than the rest of examples/ makes, and it should not happen by accident.
windows_only="winmessage.wz"

fails=0
for f in "$ROOT"/examples/*.wz; do
  name=$(basename "$f")
  skip_linux=0
  for w in $windows_only; do
    [ "$name" = "$w" ] && skip_linux=1
  done
  if [ $skip_linux -eq 1 ]; then
    # IT MUST STILL BUILD FOR WINDOWS, and it must REFUSE for Linux -- a Windows-only example
    # that silently compiled for Linux would be a program that cannot run and says nothing.
    if ! "$WANTZEL" "$f" "$T/prog.exe" --target=windows >"$T/err" 2>&1; then
      printf '  %s does not compile for Windows:\n' "$name"; sed 's/^/    /' <"$T/err"; fails=$((fails+1))
    fi
    if "$WANTZEL" "$f" "$T/prog" >"$T/err" 2>&1; then
      printf '  %s is listed as Windows-only but compiled for Linux\n' "$name"; fails=$((fails+1))
    fi
    continue
  fi
  if ! "$WANTZEL" "$f" "$T/prog" >"$T/err" 2>&1; then
    printf '  %s does not compile:\n' "$name"; sed 's/^/    /' <"$T/err"; fails=$((fails+1)); continue
  fi
  # The same source must also produce a Windows binary: an example that only
  # builds on Linux quietly contradicts what the README promises.
  if ! "$WANTZEL" "$f" "$T/prog.exe" --target=windows >"$T/err" 2>&1; then
    printf '  %s does not compile for Windows:\n' "$name"; sed 's/^/    /' <"$T/err"; fails=$((fails+1))
  fi
done

[ $fails -eq 0 ] || { echo "$fails example(s) failed"; exit 1; }
echo "all examples compile for Linux and Windows, except $windows_only (Windows only)"
