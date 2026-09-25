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

# THERE IS NO STEP 1b ANY MORE. It used to generate src/embedded.wz from lib/ so the
# standard library travelled inside the compiler. That went on 16-09-2026: it cost a
# 238KB generated source in the repository, a permanent difference between the two
# counterparts (boot.c never had an embedded copy), no way to tell which copy answered an
# include, and no source on disk for an editor or debugger to show. lib/ ships beside the
# binary instead.

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

mv bin/wantzel.stage3 bin/wantzel
rm -f bin/wantzel.stage1 bin/wantzel.stage2
echo
echo "   ./bin/wantzel <source.wz> <executable>"
