# A handler that fills tool.vbuf (1 MB) for a text/json VIEW field in the output schema:
# just under the limit works, and just over it is a loud refusal naming the tool and the
# limit -- not a silently truncated reply.
#
# Before this, io.push/json.escslice (the appenders a handler uses to fill tool.vbuf) stop
# advancing at len(tool.vbuf) by their own documented contract -- a caller-side refusal
# never happens -- so a handler that overfills it got a normal-looking reply built from
# truncated text, with tool.run returning >= 0 same as any other success.
#
# TOETSGROEP: schema
# DEKT: src/compiler.wz lib/toolsmcp.wz
. "$ROOT/tests/helpers.sh"

cat > "$T/vbuf.wz" <<'WZ'
import json;
type FillArgs = schema
  n: int "how many bytes to write into the view field";
end;
type FillResult = schema
  text: text "n bytes of 'a'";
end;
tools
  fill(FillArgs): FillResult "Write n bytes of 'a' into the reply." readonly;
end;
import toolsmcp;
function tool.fill(a: array of FillArgs; r: array of FillResult): int;
var at, i: int;
begin
  at := tool.vn;
  i := 0;
  while i < a[0].n do
  begin
    at := io.push(tool.vbuf, at, "a");
    i := i + 1;
  end;
  r[0].text_at := tool.vn; r[0].text_end := at; tool.vn := at;
  return 0;
end;
begin
  mcp.stdio;
end.
WZ

compile "$T/vbuf.wz" "$T/vbuf"

call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"fill","arguments":{"n":%s}}}\n' "$1" "$2"; }

VBUF=1048576

# ---- just under the limit: a normal reply, full length, not one byte short ------------
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
  call 2 $((VBUF - 1))
} > "$T/in_under"
out_under=$("$T/vbuf" < "$T/in_under" 2>"$T/err_under") \
  || { echo "the server exited non-zero on a reply just under the limit:"; cat "$T/err_under"; exit 1; }
reply_under=$(printf '%s\n' "$out_under" | grep '"id":2')
assert_contains "just under the limit: no error" "$reply_under" '"result"'
# the schema has no length field of its own -- count the a's in structuredContent directly
got_len=$(printf '%s' "$reply_under" | sed 's/.*"structuredContent":{"text":"//; s/"}.*//' | tr -d '\n' | wc -c)
assert_eq "just under the limit: the full text, not truncated" "$got_len" "$((VBUF - 1))"

# ---- one byte over the limit: a loud refusal, naming the tool and the limit -----------
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
  call 3 $VBUF
  call 4 3
} > "$T/in_over"
out_over=$("$T/vbuf" < "$T/in_over" 2>"$T/err_over") \
  || { echo "the server exited non-zero on a reply one byte over the limit:"; cat "$T/err_over"; exit 1; }
reply_over=$(printf '%s\n' "$out_over" | grep '"id":3')
# -2 (a handler-side refusal) surfaces the same way tool.fail does: isError:true with the
# message as the tool's own text, not a JSON-RPC protocol-level "error" (that channel is
# -3, the final dst buffer, a different limit -- see docs/library.md).
assert_contains "one byte over: a tool-level failure" "$reply_over" '"isError":true'
assert_contains "one byte over: names the tool" "$reply_over" 'tool fill:'
assert_contains "one byte over: names the limit" "$reply_over" "$VBUF bytes"

# the server keeps answering after the refusal -- this is a refusal, not a dead server
reply_next=$(printf '%s\n' "$out_over" | grep '"id":4')
assert_contains "the server answers the next call after the refusal" "$reply_next" '"aaa"'

echo "tool.vbuf: a reply of $((VBUF - 1)) bytes works in full; $VBUF bytes is refused loudly, naming the tool and the limit"
