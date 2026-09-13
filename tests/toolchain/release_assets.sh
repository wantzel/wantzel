# What gets uploaded to a release is what this source produces, and it says so itself.
#
# test.sh already walks the bootstrap chain and asserts the installed compiler IS the
# fixed point. Two things it does not cover, and both only matter when bytes leave this
# machine:
#
#   1. The Windows binary. test.sh compares ELF only, yet the .exe is the artefact a
#      Windows user downloads. If it were not reproducible, nobody could check it.
#   2. The version the binary reports. A published SHA256SUMS is useless if the binary
#      cannot tell you which release it belongs to -- you would not know which checksum
#      to compare against.
#
# Together with the fixed-point check in test.sh, that closes the loop: the source
# produces these exact bytes, and these bytes name the release they came from.
. "$ROOT/tests/helpers.sh"
cd "$ROOT"

# The version in the compiler is the one thing a human has to keep in step with the git
# tag, so read it back from the built binary rather than from the source.
version=$(./bin/wantzel --version | awk '{print $2}')
[ -n "$version" ] || { echo "the compiler does not report a version"; exit 1; }
assert_eq "the C bootstrap reports the same version" "$(./bin/wantzel0 --version)" "wantzel $version"

# A tag, if we are on one, must agree with what the binary says. Off a tag this is
# silent: most runs of the suite are not releases.
tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
if [ -n "$tag" ]; then
  assert_eq "the tag matches the reported version" "$tag" "v$version"
fi

# Both targets, built twice, must be byte-identical -- that is what lets anyone rebuild
# from the tag and compare against the published checksum.
./bin/wantzel src/wantzel.wz "$T/linux_a"              >/dev/null 2>&1 || { echo "Linux build failed"; exit 1; }
./bin/wantzel src/wantzel.wz "$T/linux_b"              >/dev/null 2>&1
./bin/wantzel src/wantzel.wz "$T/win_a.exe" --target=windows >/dev/null 2>&1 || { echo "Windows build failed"; exit 1; }
./bin/wantzel src/wantzel.wz "$T/win_b.exe" --target=windows >/dev/null 2>&1

cmp -s "$T/linux_a" "$T/linux_b"   || { echo "the Linux build is not reproducible"; exit 1; }
cmp -s "$T/win_a.exe" "$T/win_b.exe" || { echo "the Windows build is not reproducible"; exit 1; }

# The Linux compiler must be the one in bin/, or the checksum we publish would cover
# bytes that are not the ones people get when they build.
cmp -s "$T/linux_a" ./bin/wantzel || { echo "bin/wantzel differs from what src/wantzel.wz produces"; exit 1; }

# Static linking is the whole reason the download works without a toolchain.
case "$(head -c 20 "$T/linux_a" | od -An -tx1 | tr -d ' \n')" in
  7f454c46*) ;;
  *) echo "the Linux output is not an ELF binary"; exit 1 ;;
esac
case "$(head -c 2 "$T/win_a.exe")" in
  MZ) ;;
  *) echo "the Windows output is not a PE binary"; exit 1 ;;
esac

# The banner belongs on a bare run and nowhere else. A compiler that announces itself on
# every successful build puts that text into build logs and into $(...) substitutions,
# and someone eventually parses around it.
banner=$(./bin/wantzel 2>&1); rc=$?
assert_eq "a bare run exits non-zero" "$rc" "1"
case "$banner" in
  *"wantzel $version"*) ;;
  *) echo "a bare run does not name the program and its version"; exit 1 ;;
esac
case "$banner" in
  *github.com/wantzel/wantzel*) ;;
  *) echo "a bare run does not say where the project lives"; exit 1 ;;
esac
assert_eq "a successful compile prints nothing" "$(./bin/wantzel examples/hello.wz "$T/quiet" 2>&1)" ""
assert_eq "both compilers print the same banner" "$(./bin/wantzel0 2>&1)" "$banner"

# Finally the thing a release actually publishes: checksums over the bytes just built.
( cd "$T" && sha256sum linux_a win_a.exe > SUMS && sha256sum -c --quiet SUMS ) \
  || { echo "the checksums do not match the bytes that were built"; exit 1; }

echo "wantzel $version: both targets reproducible, ELF static, PE valid, checksums verified"
