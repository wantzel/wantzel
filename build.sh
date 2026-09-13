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

echo "1. cc bootstrap/boot.c -> bin/wantzel0    (the one and only external step)"
cc -w -o bin/wantzel0 bootstrap/boot.c

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
