#!/bin/sh
# build.sh -- bootstrap the Wantzel compiler.
#
# Step 1 is the only step that uses an external compiler.  After that, the
# language compiles itself and the result is verified to be a fixed point:
# stage2 and stage3 -- both produced by the self-hosted compiler -- must be
# byte-identical.  Stage1, produced by bootstrap/boot.c, does not have to
# match them byte for byte: boot.c only has to produce a
# CORRECT stage1, not an identical one.  It does not implement schema, tools
# or --debug -- none of which src/wantzel.wz's own source uses -- so it is
# free to be much smaller than the compiler it bootstraps.
set -e
cd "$(dirname "$0")"
mkdir -p bin

# Every file this script installs is written under a temporary name and RENAMED into
# place.  A rename within one filesystem is atomic: a reader sees either the old file or
# the new one, never half of one.  That matters because the suite rebuilds while the
# rest of it is running -- tests/toolchain/all_suites_green.sh calls this script, and
# test.sh reads bin/wantzel0.  Writing in place gave those readers a
# truncated file: `cc -o bin/wantzel0` empties the target first, so a concurrent
# ./bin/wantzel0 got "Permission denied" (measured: 2 failures in 176 attempts during one
# build).
echo "1. cc bootstrap/boot.c -> bin/wantzel0    (the one and only external step)"
cc -w -o bin/wantzel0.new bootstrap/boot.c
mv -f bin/wantzel0.new bin/wantzel0

# THERE IS NO GENERATED SOURCE. The standard library reaches the compiler in step 6, as
# bytes appended after the finished binary -- not as a generated .wz compiled into it,
# which is what an earlier version did and which made the C bootstrap and the self-hosted
# compiler differ.

echo "2. boot   src/wantzel.wz       -> bin/wantzel.stage1 (first self-hosted compiler)"
./bin/wantzel0 src/wantzel.wz bin/wantzel.stage1

echo "3. stage1 src/wantzel.wz       -> bin/wantzel.stage2 (compiled by itself)"
./bin/wantzel.stage1 src/wantzel.wz bin/wantzel.stage2

echo "4. stage2 src/wantzel.wz       -> bin/wantzel.stage3 (and once more)"
./bin/wantzel.stage2 src/wantzel.wz bin/wantzel.stage3

if cmp -s bin/wantzel.stage2 bin/wantzel.stage3; then
    echo "5. fixpoint reached: stage2 = stage3 ($(wc -c < bin/wantzel.stage2) bytes)"
else
    echo "5. FIXPOINT FAILED -- the compiler does not reproduce itself" >&2
    exit 1
fi

# 6. THE STANDARD LIBRARY, AS A TRAILER. The compiler proper is the fixed point just
# checked -- stage2 and stage3 carry no trailer, so that comparison is of the compiler
# alone. What follows it is data the ELF loader never maps (the program header stops
# before it) and the compiler reads from /proc/self/exe: lib/*.wz, each packed with
# lib/lz.wz, then an index and a footer (docs/design.md). bootstrap/libpack.wz writes it;
# it is built by stage3, which carries no library, so it imports nothing and takes the
# packer from lib/lz.wz by path. Deterministic: names in byte order, no timestamps, so the
# same lib/ always gives the same trailer. Nothing is generated into the source tree.
mods=$(ls lib/*.wz | LC_ALL=C sort)
sum=$(sha256sum $mods | sha256sum | cut -c1-64)
./bin/wantzel.stage3 bootstrap/libpack.wz bin/libpack
./bin/libpack "$sum" $mods > bin/wantzel.trailer
cat bin/wantzel.stage3 bin/wantzel.trailer > bin/wantzel.new
chmod +x bin/wantzel.new
rm -f bin/libpack bin/wantzel.trailer

# 7. AND IT READS BACK. Every module, unpacked by the new compiler, must be the file in
# lib/ byte for byte, and --version must carry the sum just computed. One difference and
# nothing is installed: a compiler with a wrong library compiles wrong programs quietly.
for f in $mods; do
    m=$(basename "$f" .wz)
    ./bin/wantzel.new --lib "$m" | cmp -s - "$f" || {
        echo "7. LIBRARY CHECK FAILED -- module $m does not read back as $f" >&2
        rm -f bin/wantzel.new; exit 1; }
done
./bin/wantzel.new --version | grep -q "sha256 $sum" || {
    echo "7. LIBRARY CHECK FAILED -- --version does not report sha256 $sum" >&2
    rm -f bin/wantzel.new; exit 1; }
echo "6. library appended: $(echo "$mods" | wc -l) modules, $(wc -c < bin/wantzel.new) bytes in all"
echo "7. every module reads back byte for byte"

mv bin/wantzel.new bin/wantzel
rm -f bin/wantzel.stage1 bin/wantzel.stage2 bin/wantzel.stage3
echo
echo "   ./bin/wantzel <source.wz> <executable>"
