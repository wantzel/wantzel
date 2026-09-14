#!/bin/sh
# test.sh -- verify the Wantzel toolchain: bootstrap fixpoint, agreement between
# the C bootstrap and the self-hosted compiler, language behaviour, the
# runtime safety checks, and the compile-time type checks.
cd "$(dirname "$0")"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        want: %s\n        got:  %s\n' "$3" "$2"; fi; }

[ -x ./bin/wantzel0 ] && [ -x ./bin/wantzel ] || { echo "run ./build.sh first" >&2; exit 1; }

echo "bootstrap"
./bin/wantzel0 src/wantzel.wz "$T/s1" && ./"${T#./}/s1" >/dev/null 2>&1
"$T/s1" src/wantzel.wz "$T/s2" && "$T/s2" src/wantzel.wz "$T/s3"
if cmp -s "$T/s1" "$T/s2" && cmp -s "$T/s2" "$T/s3"; then ok "fixpoint stage1 = stage2 = stage3"; else bad "fixpoint"; fi
if cmp -s "$T/s3" ./bin/wantzel; then ok "the installed compiler is the fixpoint"; else bad "the installed compiler differs"; fi

echo "the C bootstrap and the self-hosted compiler agree"
for f in examples/*.wz tests/compiler/feat.wz tests/compiler/incl.wz tests/compiler/schema.wz src/wantzel.wz; do
    ./bin/wantzel0 "$f" "$T/a" 2>/dev/null && ./bin/wantzel "$f" "$T/b" 2>/dev/null
    if cmp -s "$T/a" "$T/b"; then ok "identical output for $f"; else bad "differing output for $f"; fi
done

echo "language behaviour"
./bin/wantzel tests/compiler/feat.wz "$T/feat" 2>/dev/null
same "feature suite" "$(cd "$T" && ./feat XYZ)" "$(cat tests/compiler/feat.out)"
./bin/wantzel examples/hello.wz "$T/hello" 2>/dev/null
same "hello" "$("$T/hello")" "hello, world"
./bin/wantzel examples/primes.wz "$T/primes" 2>/dev/null
same "sieve" "$("$T/primes" | head -1)" "primes below 200000: 17984"
./bin/wantzel tests/compiler/incl.wz "$T/incl" 2>/dev/null
same "includes and array parameters" "$("$T/incl")" "$(cat tests/compiler/incl.out)"
./bin/wantzel examples/cat.wz "$T/cat" 2>/dev/null
same "cat via stdin" "$(echo piped | "$T/cat")" "piped"
same "cat a file" "$("$T/cat" examples/hello.wz | head -1)" "{ hello.wz -- the smallest useful Wantzel program }"

echo "schemas and MCP"
./bin/wantzel tests/compiler/schema.wz "$T/schema" 2>/dev/null
# READ THE GOLDEN FILE; do not write the expectation out a second time.
# These lines stood here word for word beside tests/compiler/schema.out, and the same
# expectation maintained in two places drifts: extending schema.wz broke this script and
# tests/toolchain/freeze.sh while a plain ./wztest stayed GREEN -- only --toolchain saw
# the difference, so whoever does not run it notices nothing.
same "compiled schema parser" "$("$T/schema")" "$(cat tests/compiler/schema.out)"

./bin/wantzel examples/mcpserver.wz "$T/mcp" 2>/dev/null
mcpsend() { printf '%s\n' "$1" | "$T/mcp" | head -1; }
same "mcp initialize" \
  "$(mcpsend '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')" \
  '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"wantzel-mcp","version":"1.0"}}}'
same "mcp tools/call add" \
  "$(mcpsend '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23}}}')" \
  '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"42"}]}}'
same "mcp string id is echoed" \
  "$(mcpsend '{"jsonrpc":"2.0","id":"x-1","method":"ping"}')" \
  '{"jsonrpc":"2.0","id":"x-1","result":{}}'
same "mcp unknown method" \
  "$(mcpsend '{"jsonrpc":"2.0","id":3,"method":"completion/complete"}')" \
  '{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no such method"}}'
same "mcp resources/list is answered empty" \
  "$(mcpsend '{"jsonrpc":"2.0","id":9,"method":"resources/list"}')" \
  '{"jsonrpc":"2.0","id":9,"result":{"resources":[]}}'
same "mcp echoes the protocol version" \
  "$(mcpsend '{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')" \
  '{"jsonrpc":"2.0","id":10,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"wantzel-mcp","version":"1.0"}}}'
same "mcp escapes survive a round trip" \
  "$(mcpsend '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":"a\"b\nc"}}}')" \
  '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"a\"b\nc"}]}}'
same "mcp notification is silent" \
  "$(printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' | "$T/mcp" | wc -c)" "0"
same "mcp missing tool argument" \
  "$(mcpsend '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add","arguments":{"a":1}}}')" \
  '{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"add needs two integers a and b"}],"isError":true}}'

./bin/wantzel examples/mcpfiles.wz "$T/files" 2>/dev/null
mkdir -p "$T/root/sub"
printf 'alpha beta\ngamma delta\n' > "$T/root/one.txt"
printf 'beta again\n' > "$T/root/sub/two.txt"
filesend() { printf '%s\n' "$1" | "$T/files" "$T/root" | head -1; }
# The text out of {"result":{"content":[{"type":"text","text":"..."}]}}, with the JSON
# escapes the server actually emits turned back into characters.  sed rather than a JSON
# parser because this repository depends on nothing: the shape is fixed, it is our own
# server answering, and a test that needed another language to read one field would
# contradict the thing being tested.
jtext() {
  sed -e 's/.*"text":"//' -e 's/"}\].*//' \
      -e 's/\\"/"/g' -e 's/\\\\/\\/g' | sed -e 's/\\n/\n/g'
}
same "files list_dir" \
  "$(filesend '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_dir","arguments":{}}}' | jtext | sort | tr '\n' '|')" \
  "|1 directories, 1 files|dir    sub|file   one.txt|"
same "files read_file" \
  "$(filesend '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"one.txt"}}}' | jtext)" \
  "alpha beta
gamma delta"
same "files search finds both" \
  "$(filesend '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"beta"}}}' | jtext | grep -c ':.*beta')" \
  "2"
same "files search reports line numbers" \
  "$(filesend '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search","arguments":{"query":"gamma"}}}' | jtext | head -1)" \
  "one.txt:2: gamma delta"
same "files sandbox refuses .." \
  "$(filesend '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"../../etc/passwd"}}}' | jtext)" \
  "that path is outside the served directory"
same "files sandbox refuses absolute paths" \
  "$(filesend '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"/etc/passwd"}}}' | jtext)" \
  "that path is outside the served directory"
same "files file_info" \
  "$(filesend '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"file_info","arguments":{"path":"one.txt"}}}' | jtext | sed -n '3p')" \
  "size: 23 bytes"

# the HTTP transport and the stdio->HTTP bridge must agree with stdio
./bin/wantzel examples/mcpbridge.wz "$T/bridge" 2>/dev/null
PORT=$(( 8200 + $$ % 700 ))
"$T/files" "$T/root" $PORT >/dev/null 2>&1 &
sleep 1
CALL='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"beta"}}}'
same "http transport answers" \
  "$(printf '%s' "$CALL" | curl -sS --max-time 5 -X POST --data-binary @- http://127.0.0.1:$PORT/mcp | jtext | grep -c ':.*beta')" \
  "2"
same "bridge matches stdio" \
  "$(printf '%s\n' "$CALL" | "$T/bridge" $PORT | jtext | grep -c ':.*beta')" \
  "2"
same "bridge passes notifications silently" \
  "$(printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' | "$T/bridge" $PORT | wc -c)" \
  "0"
pkill -f "$T/files" 2>/dev/null || true
sleep 0.2

echo "runtime safety checks"
rt() {                      # rt <name> <expected output>, source on stdin
    cat > "$T/c.wz"
    ./bin/wantzel "$T/c.wz" "$T/c" >/dev/null 2>&1 || { bad "$1 (did not compile)"; return; }
    same "$1" "$("$T/c" 2>&1 | sed "s|$T/c.wz|SRC|")" "$2"
}

rt "index above upper bound" "runtime error: array index out of range at SRC:2" <<'PX'
program t; var a: array[10..20] of int; i: int;
begin i := 21; a[i] := 1; end.
PX

rt "index below lower bound" "runtime error: array index out of range at SRC:2" <<'PX'
program t; var a: array[10..20] of int; i: int;
begin i := 9; a[i] := 1; end.
PX

rt "local array bounds" "runtime error: array index out of range at SRC:2" <<'PX'
program t;
procedure p; var b: array[0..3] of char; i: int; begin i := 4; b[i] := 'x'; end;
begin p; end.
PX

rt "division by zero" "runtime error: division by zero at SRC:2" <<'PX'
program t; var i, j: int;
begin i := 0; j := 7 div i; end.
PX

rt "modulo by zero" "runtime error: division by zero at SRC:2" <<'PX'
program t; var i, j: int;
begin i := 0; j := 7 mod i; end.
PX

rt "chr out of range" "runtime error: chr() argument outside 0..255 at SRC:2" <<'PX'
program t; var i: int; c: char;
begin i := 256; c := chr(i); end.
PX

rt "string index" "runtime error: string index out of range at SRC:2" <<'PX'
program t; var s: str; c: char;
begin s := "abc"; c := schar(s, 3); end.
PX

rt "falling out of a function" "runtime error: function ended without executing a return at SRC:2" <<'PX'
program t; var i: int;
function f(x: int): int; begin if x > 100 then return 1; end;
begin i := f(1); end.
PX

rt "locals start at zero" "00" <<'PX'
program t; var o: array[0..7] of char;
procedure p; var k: int; a: array[0..3] of int; begin
  o[0] := chr(48 + k + a[3]); sys3(1,1,addr(o[0]),1); k := 9; end;
begin p; p; end.
PX

rt "array parameter bounds" "runtime error: array index out of range at SRC:2" <<'PX'
program t; var b: array[0..3] of char;
procedure p(a: array of char); begin a[len(a)] := 'x'; end;
begin p(b); end.
PX

echo "compile-time checks"
ce() {                      # ce <name> <expected diagnostic>, source on stdin
    cat > "$T/c.wz"
    same "$1" "$(./bin/wantzel "$T/c.wz" "$T/c" 2>&1 | sed "s|$T/c.wz|SRC|")" "$2"
}

ce "char := int" "wantzel: SRC:1: type error in assignment: expected char, found int" <<'PX'
program t; var c: char; begin c := 65; end.
PX

ce "int := char" "wantzel: SRC:1: type error in assignment: expected int, found char" <<'PX'
program t; var i: int; begin i := 'A'; end.
PX

ce "int + bool" "wantzel: SRC:1: type error in arithmetic: expected int, found bool" <<'PX'
program t; var i: int; b: bool; begin i := i + b; end.
PX

ce "int as a condition" "wantzel: SRC:1: type error in if condition: expected bool, found int" <<'PX'
program t; var i: int; begin if i then i := 1; end.
PX

ce "and on ints" "wantzel: SRC:1: type error in and: expected bool, found int" <<'PX'
program t; var i: int; begin i := i and 1; end.
PX

ce "ordering bools" "wantzel: SRC:1: only int, char and real can be ordered" <<'PX'
program t; var b, c: bool; begin c := b < b; end.
PX

ce "undeclared name" "wantzel: SRC:1: undeclared identifier" <<'PX'
program t; begin zz := 1; end.
PX

ce "wrong argument type" "wantzel: SRC:1: type error in argument: expected int, found char" <<'PX'
program t; procedure p(x: int); begin end; begin p('a'); end.
PX

ce "too many arguments" "wantzel: SRC:1: too many arguments in call" <<'PX'
program t; procedure p(x: int); begin end; begin p(1,2); end.
PX

ce "too few arguments" "wantzel: SRC:1: wrong number of arguments in call" <<'PX'
program t; procedure p(x: int; y: int); begin end; begin p(1); end.
PX

ce "discarded result" "wantzel: SRC:1: the value of this function call is not used" <<'PX'
program t; function f: int; begin return 1; end; begin f; end.
PX

ce "procedure as a value" "wantzel: SRC:1: a procedure has no value" <<'PX'
program t; var i: int; procedure p; begin end; begin i := p; end.
PX

ce "array without index" "wantzel: SRC:1: an array can only be used with a subscript, len() or addr()" <<'PX'
program t; var a: array[0..3] of int; i: int; begin i := a; end.
PX

ce "subscript on a scalar" "wantzel: SRC:1: subscript applied to a variable that is not an array" <<'PX'
program t; var i, j: int; begin j := i[0]; end.
PX

ce "assignment to const" "wantzel: SRC:1: cannot assign to or take the address of a constant" <<'PX'
program t; const K = 1; begin K := 2; end.
PX

ce "duplicate global" "wantzel: SRC:1: duplicate global declaration" <<'PX'
program t; var i: int; i: char; begin end.
PX

ce "unfulfilled forward" "wantzel: SRC:1: forward declared routine f is never defined" <<'PX'
program t; function f: int; forward; begin end.
PX

ce "comparing strings" "wantzel: SRC:1: strings cannot be compared with = or <>; compare their characters" <<'PX'
program t; var b: bool; begin b := "a" = "b"; end.
PX

ce "; before else" "wantzel: SRC:1: unexpected else (no ';' may precede it)" <<'PX'
program t; var i: int; begin if i > 0 then i := 1; else i := 2; end.
PX

ce "wrong array element type" "wantzel: SRC:1: type error in array argument: expected char, found int" <<'PX'
program t; var b: array[0..3] of int; procedure p(a: array of char); begin end; begin p(b); end.
PX

ce "scalar where array expected" "wantzel: SRC:1: this parameter needs an array" <<'PX'
program t; var i: int; procedure p(a: array of char); begin end; begin p(i); end.
PX

ce "missing include file" "wantzel: SRC:2: cannot open the included file" <<'PX'
program t;
include "nowhere/nothing.wz";
begin end.
PX

ce "schema needs record" "wantzel: SRC:2: a schema body starts with 'record'" <<'PX'
program t;
schema S = { a: int; };
begin end.
PX

ce "unknown schema field type" "wantzel: SRC:3: a schema field is int, real, bool, text, text[N], text of (...), json, or a schema declared earlier" <<'PX'
program t;
schema S = record
  a: float;
end;
begin end.
PX

ce "shadowing a builtin" "wantzel: SRC:1: that name is built in" <<'PX'
program t; var len: int; begin end.
PX

ce "break outside a loop" "wantzel: SRC:1: break outside a loop" <<'PX'
program t; begin break; end.
PX

ce "bad forward signature" "wantzel: SRC:2: parameter type differs from the forward declaration" <<'PX'
program t; function f(a: int): int; forward;
function f(a: char): int; begin return 1; end; begin end.
PX

ce "eleven parameters" "wantzel: SRC:1: a routine may take at most ten arguments (an array counts as two)" <<'PX'
program t; procedure p(a,b,c,d,e,f,g,h,i,j,k: int); begin end; begin end.
PX

ce "six arrays is too many" "wantzel: SRC:1: a routine may take at most ten arguments (an array counts as two)" <<'PX'
program t; procedure p(a,b,c,d,e,f: array of int); begin end; begin end.
PX

ce "return value in a procedure" "wantzel: SRC:1: a procedure cannot return a value" <<'PX'
program t; procedure p; begin return 1; end; begin end.
PX

ce "missing final dot" "wantzel: SRC:2: missing . after the final end" <<'PX'
program t; begin end
PX

echo "generated executables are self-contained"
./bin/wantzel examples/hello.wz "$T/h" 2>/dev/null
if head -c4 "$T/h" | od -An -c | grep -q '177   E   L   F'; then ok "ELF magic"; else bad "ELF magic"; fi
if ldd "$T/h" 2>&1 | grep -q "not a dynamic executable"; then ok "no dynamic linking"; else bad "dynamically linked"; fi
if [ "$(wc -c < "$T/h")" -lt 4096 ]; then ok "hello world under 4 kB ($(wc -c < "$T/h") bytes)"; else bad "unexpectedly large"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
