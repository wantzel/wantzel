# `http` — a non-blocking HTTP/1.1 server on epoll

`include "http.wz";` (pulls in `net.wz` and `json.wz`)

One process, one event loop, no threads and no allocation: every connection owns a fixed
slice of two static buffers (`http.inbuf`, `http.outbuf`), indexed by its file descriptor.
The application supplies `procedure app.request`, which the loop calls once per complete
request; everything about that request (method, path, query string, headers, body) is
read through the module's globals rather than passed as arguments, because there are no
records as call arguments and one request is being served at a time.

```pascal
include "http.wz";

var
  hits: int;

procedure app.request;
begin
  hits := hits + 1;
  if http.pathis("/health") then
  begin
    http.add("ok"); http.finish(200, "text/plain"); return;
  end;
  if http.method <> HTTP.GET then
  begin
    http.add("only GET is served here\n");
    http.finish(405, "text/plain");
    return;
  end;
  http.add("hello from wantzel\npath: ");
  http.addb(http.inbuf, http.pathat, http.pathlen);
  http.add("\nrequest number: ");
  http.addn(hits);
  http.add("\n");
  http.finish(200, "text/plain");
end;

begin
  http.serve(8080, 1);
end.
```

## Starting the server

| | |
|---|---|
| `http.serve(port, workers: int)` | bind `port` and run the event loop; never returns. With `workers > 1` it `fork`s that many worker processes that all share the port through `SO_REUSEPORT`, so the kernel spreads connections across them — no threads, no locks, nothing shared between workers |
| `procedure app.request; forward;` | declared by the library; **the application must define it**, even a program that never actually serves HTTP but includes something that pulls `http.wz` in (see the pitfall below) |

`workers > 1` is only meaningful with more than one CPU actually available to use; tests
and single-core environments should pass `1`.

## Reading the request

These are read-only questions about the request currently being handled inside
`app.request` — they answer from the module's globals, filled by the parser before your
handler runs.

| | |
|---|---|
| `http.method: int` | one of `HTTP.GET`, `HTTP.POST`, `HTTP.PUT`, `HTTP.DELETE`, `HTTP.PATCH`, `HTTP.OPTIONS`, `HTTP.HEAD`, or `0` for anything else |
| `http.pathis(s: str): bool` | does the request path equal `s` exactly? |
| `http.pathstarts(prefix: str): bool` | does the path start with `prefix`? On a match, the rest of the path is `http.inbuf[http.restat..http.restend)` |
| `http.header(name: str): bool` | find a request header by name (case-insensitive); on a match its trimmed value is `http.inbuf[http.hvat..http.hvend)` |
| `http.bearer: bool` | the bearer token from an `Authorization: Bearer ...` header, as `http.inbuf[http.hvat..http.hvend)`; `false` if the header is absent or not a bearer token |
| `http.param(key: str): bool` | a query-string parameter (`GET /x?a=1`); on a match the decoded value is `http.pval[0..http.pvlen)` |
| `http.form(key: str): bool` | the same, for an `application/x-www-form-urlencoded` body |
| `http.urldecode(src, from, upto, dst): int` | percent-decode `src[from..upto)` into `dst` (`+` becomes a space); returns the length, or `-1` if malformed or it does not fit |

**`http.header` was case-sensitive on the literal side until 15 September 2026**: a header
name is case-insensitive in HTTP, so `http.header("Accept")` is now compared
case-insensitively against the bytes from the request on both sides. On a compiler
predating that fix, write the header name in the same case the client sends it (usually
lower case) — the failure mode was silent (`false`, no error), not a crash.

`http.param`/`http.form`/`http.header` all **position** their result in shared buffers
(`http.pval`, `http.hvat`/`http.hvend`): a second lookup overwrites the first. Copy a value
out before making another lookup if you still need it.

## Writing the response

Build the body first, then close off the reply — `http.finish` writes the status line and
headers directly in front of the body you already wrote, so the whole reply goes out in
one write.

| | |
|---|---|
| `http.add(s: str)` | append a string literal to the reply body |
| `http.addn(v: int)` | append the decimal form of `v` |
| `http.addc(c: char)` | append one character |
| `http.addb(b, at, n)` | append `n` bytes from `b` starting at `at` (for echoing part of the request, or any buffer) |
| `http.hdradd(s: str)` | add a response header before `http.finish`, e.g. `http.hdradd("Cache-Control: no-store")` |
| `http.hdraddslice(name: str; b, from, upto)` | the same, with the value taken from a buffer rather than a literal |
| `http.finish(status: int, ctype: str)` | close off the reply: writes the status line, `Content-Type`, `Content-Length`, any added headers, and the connection header, then queues the reply to be sent |

**`http.finish` must be the last thing `app.request` does for a given request** — nothing
after it should touch the reply buffers, because `http.finish` computes the body length
from the write cursor at the moment it is called.

`http.hdradd`/`http.hdraddslice` **silently drop** the header if there is not enough room
left in the fixed header buffer (`HDRROOM`, 2 KB) — there is no way to detect this from
the call itself; keep the number and size of custom headers modest.

## Logging

| | |
|---|---|
| `http.logging: bool` | set to `true` to have one JSON line per request written to `STDERR` (`{"t":...,"method":...,"path":...,"status":...,"us":...,"bytes":...}`) |

## What is not here

There is no routing table, no middleware chain, and no HTTPS — `http` answers plaintext
HTTP/1.1 only. `lib/router.wz` builds a small routing helper on top of `http.pathis`; TLS
is not attempted anywhere in the standard library. There is also no chunked transfer
encoding on the way out: every reply carries an explicit `Content-Length`, which is why
the body must be fully written before `http.finish`.

## The pitfall that costs the most time here

**Including `lib/tools.wz` (for an MCP server) pulls in `http.wz` too**, so even a
stdio-only program that never calls `http.serve` must still define `procedure
app.request` — otherwise the compiler refuses with `forward declared routine is never
defined` on the program's last line. An empty body is enough:

```pascal
procedure app.request;
begin
end;
```

## What this page leaves out, and why

`http.wz` exports more than the routines above. The rest run the event loop —
`http.serve` calls them, and an application does not:

`http.start`, `http.accept`, `http.readable`, `http.flush`, `http.drop`, `http.parse`,
`http.log`, `http.hdreq`, `http.lookup`, `http.hexval`, `http.bearer`.

They are omitted deliberately, not forgotten. Calling them from an application means
driving the loop by hand, and then `http.serve` is the wrong tool — the socket calls in
`lib/net.wz` are. If you are reading the source and want to know what one of them does, the
comment above it is the reference; they are written for the maintainer rather than the
caller, and that is the line this page draws.
