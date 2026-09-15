#!/bin/sh
# build.sh -- bootstrap the Wantzel compiler.
#
# Step 1 is the only step that uses an external compiler.  After it, the
# language compiles itself and the result is verified to be a fixpoint:
# the compiler produced by the bootstrap and the compiler produced by
# that compiler must be byte-identical.
set -e
cd "$(dirname "$0")"
mkdir -p bin

# Every file this script installs is written under a temporary name and RENAMED into
# place.  A rename within one filesystem is atomic: a reader sees either the old file or
# the new one, never half of one.  That matters because the suite rebuilds while the
# rest of it is running -- tests/toolchain/all_suites_green.sh calls this script, and test.sh,
# test-win.sh and embedded_lib_current.sh read bin/wantzel0 and src/embedded.wz.  Writing
# in place gave those readers a truncated file: `cc -o bin/wantzel0` empties the target
# first, so a concurrent ./bin/wantzel0 got "Permission denied" (measured: 2 failures in
# 176 attempts during one build), and a half-written src/embedded.wz fails
# embedded_lib_current.sh and tests/compiler/schema.wz without either naming the cause.
echo "1. cc bootstrap/boot.c -> bin/wantzel0    (the one and only external step)"
cc -w -o bin/wantzel0.new bootstrap/boot.c
mv -f bin/wantzel0.new bin/wantzel0

# The standard library goes INSIDE the compiler, so a binary that was downloaded rather
# than built can still resolve include "io.wz". Regenerated every build: src/embedded.wz
# is generated, never edited, and a stale copy would ship a library that differs from
# lib/ -- which tests/toolchain/embedded_lib_current.sh refuses.
#
# The generator is itself written in Wantzel and compiled by wantzel0, which needs no
# embedded copy: it reads lib/ from disk, and in this repository lib/ is right there.
echo "1b. generating src/embedded.wz from lib/"
./bin/wantzel0 tools/embedlib.wz bin/embedlib.new
mv -f bin/embedlib.new bin/embedlib
./bin/embedlib src/embedded.wz.new $(for f in lib/*.wz; do printf '%s %s ' "$(basename "$f")" "$f"; done)
mv -f src/embedded.wz.new src/embedded.wz

echo "2. boot   src/wantzel.wz       -> bin/wantzel.stage1 (first self-hosted compiler)"
./bin/wantzel0 src/wantzel.wz bin/wantzel.stage1

echo "3. stage1 src/wantzel.wz       -> bin/wantzel.stage2 (compiled by itself)"
./bin/wantzel.stage1 src/wantzel.wz bin/wantzel.stage2

echo "4. stage2 src/wantzel.wz       -> bin/wantzel.stage3 (and once more)"
./bin/wantzel.stage2 src/wantzel.wz bin/wantzel.stage3

if cmp -s bin/wantzel.stage1 bin/wantzel.stage2 && cmp -s bin/wantzel.stage2 bin/wantzel.stage3; then
    echo "5. fixpoint reached: stage1 = stage2 = stage3 ($(wc -c < bin/wantzel.stage2) bytes)"
else
    echo "5. FIXPOINT FAILED -- the compiler does not reproduce itself" >&2
    exit 1
fi

mv bin/wantzel.stage3 bin/wantzel
rm -f bin/wantzel.stage1 bin/wantzel.stage2
echo
echo "   ./bin/wantzel <source.wz> <executable>"
