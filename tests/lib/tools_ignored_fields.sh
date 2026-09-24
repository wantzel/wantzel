# An undeclared key in a tool's arguments is IGNORED, not refused -- and it is REPORTED.
#
# Two things used to be true in turn, and both were wrong on their own:
#
#   swallowing it   let a caller misspell an OPTIONAL field and get a perfectly normal
#                   answer computed with the default in its place, with nothing anywhere
#                   saying so.  The wrong number travelled on.
#   refusing it     closed that hole and broke every caller that sends a superset of what
#                   a tool declares -- which is what a caller written against a
#                   schema-validating server does, because ignoring undeclared input is
#                   the default there.
#
# So the call is answered and the key is named: in _meta.ignoredFields for MCP, and in
# the X-Ignored-Field and X-Ignored-Count headers for REST.  This test pins BOTH halves:
# that the answer comes back, and that it says what it dropped.
#
# TOETSGROEP: schema
. "$ROOT/tests/helpers.sh"

cat > "$T/srv.wz" <<'WZ'
include "json.wz";
type AddArgs = schema
  a: int "the left operand";
  b: int "the right operand";
  scale: int? "an optional multiplier";
end;
type AddResult = schema
  sum: int;
end;
tools
  add(AddArgs): AddResult "Add two whole numbers." readonly idempotent;
end;
include "tools.wz";
function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  if a[0].scale_ok and not a[0].scale_null then r[0].sum := r[0].sum * a[0].scale;
  return 0;
end;
procedure app.request;
begin
end;
begin
  mcp.stdio;
end.
WZ

compile "$T/srv.wz" "$T/srv"

call() {
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":$1}}" \
    | "$T/srv" 2>&1 | tail -1
}

# ---- the answer comes back at all -------------------------------------------------
plain=$(call '{"a":19,"b":23}')
assert_contains "a call with only declared fields is answered" "$plain" '"sum":42'
assert_contains "and says nothing about ignored fields" "$plain" '"isError":false'
case "$plain" in
  *ignoredFields*) echo "a clean call must not carry an ignoredFields report"; echo "  $plain"; exit 1 ;;
esac

extra=$(call '{"a":19,"b":23,"colour":"red"}')
assert_contains "an undeclared field does NOT fail the call" "$extra" '"sum":42'

# ---- and it is reported ------------------------------------------------------------
assert_contains "the undeclared field is named" "$extra" '"first":"colour"'
assert_contains "and counted" "$extra" '"count":1'
# NOT in structuredContent: that has to keep the shape the output schema declares, or a
# validating client rejects an answer that is otherwise correct
assert_contains "the report rides in _meta" "$extra" '"_meta":{"ignoredFields"'
assert_contains "structuredContent is untouched" "$extra" '"structuredContent":{"sum":42}'

# whatever the undeclared value holds: a nested object with a '}' inside a string is the
# case a naive skipper ends the whole object on
nested=$(call '{"a":1,"b":2,"junk":[1,{"x":"}"},null],"more":true}')
assert_contains "a nested undeclared value is stepped over, not parsed" "$nested" '"sum":3'
assert_contains "the FIRST undeclared field is the one named" "$nested" '"first":"junk"'
assert_contains "and all of them are counted" "$nested" '"count":2'

# ---- what must STILL be refused ----------------------------------------------------
# This is the half that makes ignoring safe to do at all.
badtype=$(call '{"a":"nineteen","b":23}')
assert_contains "a declared field with the wrong type is still refused" "$badtype" \
  "the arguments do not match the tool's input schema"

missing=$(call '{"a":19}')
assert_contains "a missing required field is still refused" "$missing" \
  "the arguments do not match the tool's input schema"

# A RENAMED REQUIRED FIELD is what the refusal existed to catch, and it is still caught:
# the lookalike is ignored and the real field is then absent.
renamed=$(call '{"aa":19,"b":23}')
assert_contains "a renamed required field is still refused" "$renamed" \
  "the arguments do not match the tool's input schema"

# A RENAMED OPTIONAL FIELD is the case that now gets through -- and the report is the
# whole reason that is acceptable.  Without it this is the silent wrong answer again.
optrenamed=$(call '{"a":10,"b":0,"scail":5}')
assert_contains "a renamed optional field is answered with the default" "$optrenamed" '"sum":10'
assert_contains "but the caller is told which field was dropped" "$optrenamed" '"first":"scail"'

# ---- the REST side, driven in process ---------------------------------------------
# No socket and no port: every piece of state tool.rest reads is a global, so the request
# can be staged directly.  That keeps this test safe to run beside anything else.
cat > "$T/rest.wz" <<'WZ'
include "json.wz";
type AddArgs = schema
  a: int;
  b: int;
end;
type AddResult = schema
  sum: int;
end;
tools
  add(AddArgs): AddResult "Add two whole numbers." readonly idempotent;
end;
include "tools.wz";
function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;
end;
procedure app.request;
begin
end;
var
  ok: bool;
  n: int;
// Stage one POST /api/<tool> with the given body and print the whole reply.
procedure once(path: str; body: str);
begin
  http.fd := 0;
  http.ibase := 0;
  http.obase := 0;
  http.keep := false;
  http.logging := false;
  http.method := HTTP.POST;
  http.pathat := 0;
  http.pathlen := io.push(http.inbuf, 0, path);
  http.bodyat := http.pathlen;
  http.bodylen := io.push(http.inbuf, http.bodyat, body) - http.bodyat;
  http.start;
  ok := tool.rest("/api/");
  if not ok then
  begin
    io.puts(STDOUT, "NOT A TOOL\n");
    return;
  end;
  io.out(STDOUT, addr(http.outbuf[http.rstart]), http.rend - http.rstart);
  io.puts(STDOUT, "\n----\n");
end;
begin
  once("/api/add", "{\"a\":19,\"b\":23}");
  once("/api/add", "{\"a\":19,\"b\":23,\"colour\":\"red\"}");
  once("/api/add", "{\"a\":19,\"b\":23,\"colour\":\"red\",\"size\":2}");
  // a key carrying a control character cannot reach the header raw: it would end the
  // header and let the caller write the ones after it
  once("/api/add", "{\"a\":1,\"b\":2,\"x\\u000dy\":1}");
end.
WZ

compile "$T/rest.wz" "$T/rest"
r=$("$T/rest")

clean=$(printf '%s' "$r" | sed -n '1,/^----$/p')

assert_contains "REST: the call succeeds" "$r" "200 OK"
case "$clean" in
  *X-Ignored*) echo "a clean REST call must carry no ignored header"; echo "$clean"; exit 1 ;;
esac
assert_contains "REST: the undeclared field is named in a header" "$r" "X-Ignored-Field: colour"
assert_contains "REST: and counted" "$r" "X-Ignored-Count: 1"
assert_contains "REST: two of them are counted as two" "$r" "X-Ignored-Count: 2"
# the body keeps its shape: the report is in headers precisely so it does not have to
# change what a consumer reads
assert_contains "REST: the body is unchanged" "$r" '{"sum":42}'

# the escaped control character arrives as harmless text, and no header is forged
assert_contains "REST: a control character cannot break out of the header" "$r" "X-Ignored-Count: 1"
case "$r" in
  *"X-Injected"*) echo "a caller-controlled key forged a header"; echo "$r"; exit 1 ;;
esac

echo "an undeclared field is ignored and reported, in MCP replies and REST headers;"
echo "wrong types, missing fields and renamed REQUIRED fields are still refused"
