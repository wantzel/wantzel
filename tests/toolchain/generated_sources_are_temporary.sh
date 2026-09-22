# A script that writes a .wz file writes it to a temporary directory, never into the tree.
#
# WHY THIS IS GUARDED RATHER THAN TRUSTED. Fourteen scripts in this suite generate Wantzel
# source -- in a heredoc, mostly -- because the source IS the input to the test: a file that
# must fail to compile, a program of a size nobody would check in. That is fine and it is
# not what this test is about.
#
# What it is about is WHERE that file lands. A generated source written next to the test
# survives the run, and then:
#   - it shows up as an untracked file, or worse gets committed by a later `git add -A`;
#   - a second run of the suite writes the same name in the same place, so two runs share
#     state and the failure that follows is the hardest kind to read -- passing alone,
#     failing in a full run;
#   - and a grep over *.wz starts finding it, which makes a generated artefact look like
#     a source file.
#
# The middle one is not hypothetical: a private repository in this project had three
# generated sources land in its history because an interrupted run left them behind.
#
# MEASURED WHEN THIS WAS WRITTEN: all fourteen already write to $T, the per-test temporary
# directory the runner provides. So this test does not fix anything -- it keeps a property
# that is currently true from quietly becoming untrue, which is the only thing a test of a
# convention can do.
#
# WHAT IT DOES NOT CHECK: whether generating the source was a good idea at all. A five-line
# heredoc is cheaper than a checked-in fixture and the project rule is explicit that what
# sh can do in a few lines need not become a Wantzel program.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

bad=""
for f in $(git ls-files 'tests/*.sh' 'test.sh' 2>/dev/null); do
  case "$f" in tests/toolchain/generated_sources_are_temporary.sh) continue ;; esac

  # Every redirect whose target ends in .wz -- heredoc, printf or echo alike.
  for t in $(grep -oE '(cat|printf|echo)[^>]*>>?[[:space:]]*"?[^"[:space:]]*\.wz' "$f" 2>/dev/null \
             | grep -oE '"?[^"[:space:]]*\.wz$' | tr -d '"' | sort -u); do
    case "$t" in
      # $T is the runner's temporary directory; the others are locals a script sets to one
      # of its own. A bare or relative name is what this test is looking for.
      '$T'/*|'$TMP'*|'$tmp'*|/tmp/*|'$d'/*|'$dir'/*|'$out'/*|'$W'/*) ;;
      *) bad="$bad
  $f -> $t" ;;
    esac
  done
done

if [ -n "$bad" ]; then
  echo "a script writes generated Wantzel source outside a temporary directory:$bad"
  echo
  echo 'Write it to "$T/<name>.wz" instead -- the runner makes that directory per test and'
  echo "removes it afterwards, so two runs cannot share it and nothing is left behind."
  exit 1
fi

echo "every script that generates .wz source writes it to a temporary directory"
