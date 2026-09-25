# What gets uploaded to a release is what this source produces, and it says so itself.
#
# test.sh already walks the bootstrap chain and asserts the installed compiler IS the
# fixed point. Two things it does not cover, and both only matter when bytes leave this
# machine:
#
#   1. Reproducibility of the published binary: built twice, byte-identical, and the
#      bytes in bin/ are the bytes the source produces.
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
# THE FIRST LINE ONLY: --version also reports the library, on a second line.
version=$(./bin/wantzel --version | head -1 | awk '{print $2}')
[ -n "$version" ] || { echo "the compiler does not report a version"; exit 1; }
# THE FIRST LINE ONLY. --version also reports the library, which the bootstrap compiler
# does not carry -- what has to agree between the two compilers is the version.
assert_eq "the C bootstrap reports the same version" \
  "$(./bin/wantzel0 --version | head -1)" "wantzel $version"

# AND WHICH LIBRARY IT CARRIES. The library is part of bin/wantzel (build.sh appends it
# after the fixed point), so --version names it: modules, bytes, sha256. The bootstrap
# compiler carries none and says so -- it only builds src/wantzel.wz, which imports nothing.
assert_contains "the Wantzel compiler reports the library it carries" \
  "$(./bin/wantzel --version)" "library built in: "
assert_contains "the C bootstrap reports that it carries no library" \
  "$(./bin/wantzel0 --version)" "library none"

# A tag, if we are on one, must agree with what the binary says. Off a tag this is
# silent: most runs of the suite are not releases.
tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
if [ -n "$tag" ]; then
  assert_eq "the tag matches the reported version" "$tag" "v$version"
fi

# Built twice, the compiler must be byte-identical -- that is what lets anyone rebuild
# from the tag and compare against the published checksum.
./bin/wantzel src/wantzel.wz "$T/linux_a"              >/dev/null 2>&1 || { echo "Linux build failed"; exit 1; }
./bin/wantzel src/wantzel.wz "$T/linux_b"              >/dev/null 2>&1

cmp -s "$T/linux_a" "$T/linux_b"   || { echo "the Linux build is not reproducible"; exit 1; }

# The Linux compiler must be the one in bin/, or the checksum we publish would cover
# bytes that are not the ones people get when they build. bin/wantzel is that compiler
# with the standard library appended after it (build.sh step 6), so the comparison covers
# the compiler's own length -- and the rest must be a trailer it can read.
cmp -s -n "$(wc -c < "$T/linux_a")" "$T/linux_a" ./bin/wantzel \
  || { echo "bin/wantzel differs from what src/wantzel.wz produces"; exit 1; }
[ "$(wc -c < ./bin/wantzel)" -gt "$(wc -c < "$T/linux_a")" ] \
  || { echo "bin/wantzel carries no library after the compiler; run ./build.sh"; exit 1; }

# Static linking is the whole reason the download works without a toolchain.
case "$(head -c 20 "$T/linux_a" | od -An -tx1 | tr -d ' \n')" in
  7f454c46*) ;;
  *) echo "the Linux output is not an ELF binary"; exit 1 ;;
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
# wantzel0's bare-run banner is intentionally its own: it is the bootstrap
# compiler, not a release artefact, and its banner says so rather than repeating wantzel's.
assert_contains "wantzel0's banner names itself as the bootstrap compiler" \
  "$(./bin/wantzel0 2>&1)" "the C bootstrap compiler"

# Finally the thing a release actually publishes: checksums over the bytes just built.
( cd "$T" && sha256sum linux_a > SUMS && sha256sum -c --quiet SUMS ) \
  || { echo "the checksums do not match the bytes that were built"; exit 1; }

echo "wantzel $version: reproducible, ELF static, checksums verified"

# THE DOWNLOAD HAS ONE NAME, IN EVERY RELEASE: wantzel-linux-x86_64, no version in it.
#
# The quick start downloads .../releases/latest/download/wantzel-linux-x86_64, and GitHub
# only answers that address when every release carries a file of exactly that name. A
# versioned name in the README (wantzel-0.4.0-linux-x86_64, the old form) is an instruction
# that stops working at the next release; the version belongs to the tag and to --version.
latest="https://github.com/wantzel/wantzel/releases/latest/download/wantzel-linux-x86_64"
for doc in README.md docs/howto.md; do
  versioned=$(grep -oE 'wantzel-[0-9]+\.[0-9]+\.[0-9]+-linux-x86_64' "$doc" || true)
  if [ -n "$versioned" ]; then
    echo "$doc names a download with a version in it:"
    printf '%s\n' "$versioned" | sort -u | sed 's/^/  /'
    echo "  the release asset is wantzel-linux-x86_64 in every release; use $latest"
    exit 1
  fi
done
grep -qF "$latest" README.md || {
  echo "README.md does not give the download of the newest release ($latest)"
  exit 1
}
