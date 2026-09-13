# The examples that can run without a network actually produce what they promise.
#
# examples_compile.sh proves the nine programs still translate; this proves the three
# that need nothing but a terminal still WORK. That gap matters: a program can compile
# and print the wrong thing, and an example that lies is worse than one that is missing.
#
# The other six (httpd, mcpserver, mcpbridge, mcpfiles, mcpoauth, mcptools) want a
# socket or an MCP client before they do anything, so running them here would test the
# network rather than the language.
. "$ROOT/tests/helpers.sh"

compile "$ROOT/examples/hello.wz"  "$T/hello"
compile "$ROOT/examples/primes.wz" "$T/primes"
compile "$ROOT/examples/cat.wz"    "$T/cat"

assert_eq "hello prints its greeting" "$("$T/hello")" "hello, world"

# The sieve is a fixed computation, so the answer is a constant: 17984 primes below
# 200000. If that number moves, either the arithmetic or the bounds checking broke.
assert_contains "primes counts correctly" "$("$T/primes")" "primes below 200000: 17984"
assert_contains "primes finds the 1000th" "$("$T/primes")" "7919 17389 27449"

# cat has two paths, and they are easy to break independently: reading named files and
# reading standard input.
printf 'one\ntwo\n' > "$T/in.txt"
assert_eq "cat copies a named file" "$("$T/cat" "$T/in.txt")" "$(printf 'one\ntwo')"
assert_eq "cat copies standard input" "$(printf 'three\n' | "$T/cat")" "three"

# Two files in order: cat concatenates, it does not just print the last one.
printf 'second\n' > "$T/in2.txt"
assert_eq "cat concatenates in order" \
  "$("$T/cat" "$T/in.txt" "$T/in2.txt")" "$(printf 'one\ntwo\nsecond')"

echo "hello, primes and cat all do what they promise"
