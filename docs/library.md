# Library

**Every module in `lib/`, and a compact reference for the ones most programs touch directly.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

`include "io.wz";` finds `lib/` without a path: the compiler looks there, beside its own
executable, before it looks beside your source (see [flags.md](flags.md)). These are
ordinary `.wz` files on disk — read them, step into them, change them under a ticket.

## All modules

| module | for |
|---|---|
| `acme.wz` | getting a certificate from a certificate authority (RFC 8555) |
| `aead.wz` | ChaCha20-Poly1305 as one operation (RFC 8439 §2.8) |
| `base64.wz` | base64 encoding and decoding (RFC 4648) |
| `certstore.wz` | keeping keys and certificates on disk, beside the binary |
| `chacha20.wz` | the ChaCha20 stream cipher (RFC 8439) |
| `chain.wz` | does a certificate chain up to something trusted? |
| `csr.wz` | a certificate signing request, and a self-signed certificate (RFC 2986, 5280) |
| `der.wz` | reading DER, and the parts of X.509 a TLS client needs (X.690, RFC 5280) |
| `fs.wz` | directories, file metadata and reading, on raw syscalls |
| `hash.wz` | open-addressing hash tables on caller-supplied arrays |
| `hkdf.wz` | HKDF (RFC 5869) and the TLS 1.3 key schedule (RFC 8446 §7.1) |
| `hmac.wz` | HMAC-SHA256 (RFC 2104 / RFC 4231) |
| `http.wz` | a non-blocking HTTP/1.1 server on epoll |
| `io.wz` | output, numbers and little-endian byte packing |
| `json.wz` | JSON scanning primitives |
| `jsonschema.wz` | validating JSON against a JSON Schema (2020-12), the useful subset |
| `jws.wz` | JSON Web Signature with ES256, and the JWK thumbprint (RFC 7515, 7638) |
| `kv.wz` | helpers for a small JSON object kept as compact text |
| `log.wz` | one JSON line per event on stderr, for journald or a file |
| `math.wz` | real arithmetic beyond the operators: `exp`, `log`, `pow`, trigonometry, text |
| `mcp.wz` | Model Context Protocol over JSON-RPC 2.0 |
| `mcphttp.wz` | MCP over HTTP: the endpoint routine for `app.request` |
| `net.wz` | sockets and epoll, straight on top of the system calls |
| `oauth.wz` | an OAuth 2.1 authorization server for MCP clients |
| `openapi.wz` | an OpenAPI 3.1 document and a Swagger UI page, generated from a `tools` block |
| `p256.wz` | the NIST P-256 curve and ECDSA verification (FIPS 186-4, SEC 2) |
| `p384.wz` | ECDSA over NIST P-384 (secp384r1), verification only |
| `poly1305.wz` | the Poly1305 one-time authenticator (RFC 8439) |
| `proc.wz` | processes: forking, reaping, and knowing how it ended |
| `protobuf.wz` | reader for the protobuf wire format |
| `rand.wz` | random bytes and numbers from the kernel |
| `router.wz` | a few helpers on top of `http.wz` for routing by path |
| `rsa.wz` | RSA-2048 signature verification, for certificate chains that are not ECDSA |
| `sha256.wz` | SHA-256 (FIPS 180-4) |
| `sha384.wz` | SHA-384 (FIPS 180-4) |
| `store.wz` | durable tables of fixed-size records: an append-only log |
| `time.wz` | calendar time without a time zone |
| `tls.wz` | a TLS 1.3 client: the handshake and the record layer |
| `tools.wz` | MCP and REST glue for a declared `tools` block |
| `toolsmcp.wz` | the MCP half of the glue for a declared `tools` block |
| `uuid.wz` | UUID version 4 (RFC 9562) |
| `websocket.wz` | a WebSocket server (RFC 6455) that takes over a connection from `http.wz`, on the same port |
| `x25519.wz` | X25519 key agreement on Curve25519 (RFC 7748) |
| `x509.wz` | reading an X.509 certificate (RFC 5280), on top of `der.wz` |

`tools.wz`/`toolsmcp.wz` are the transport for a declared `tools ... end;` block — see
[language.md §7b](language.md#7b-tools--a-tool-table-as-a-declaration). Together
`tls.wz`, `x25519.wz`, `chacha20.wz`, `poly1305.wz`, `aead.wz`, `hkdf.wz`, `hmac.wz`,
`sha256.wz`, `sha384.wz`, `p256.wz`, `p384.wz`, `rsa.wz`, `der.wz`, `x509.wz`, `chain.wz`,
`csr.wz`, `certstore.wz`, `jws.wz`, `acme.wz` are a TLS 1.3 client and server with nothing
linked.

The seven sections below cover the modules most programs touch directly. For the rest, the
routine comments in `lib/*.wz` are the reference, and [writing-wantzel.md](writing-wantzel.md)
already records several sharper pitfalls (`store.*`, `kv.*`, `oauth.*`, `sha256.hex`).

## `io` — output, numbers, byte access

`include "io.wz";`

The lowest layer: no buffering, no allocation, every call a syscall or a few instructions
over a buffer you already own.

| routine | meaning |
|---|---|
| `io.write(fd, a, n): int` | raw `write(2)`; returns bytes written, or negative on error |
| `io.read(fd, a, n): int` | raw `read(2)`; same contract |
| `io.out(fd, a, n)` | write and forget (a procedure, not a function) |
| `io.puts(fd, s: str)` | write a string **literal**, not a buffer |
| `io.putn(fd, v: int)` | write the decimal form of `v` |
| `io.fatal(s: str)` | write `s` and a newline to `STDERR`, then `halt(1)` — never returns |
| `io.push(b, at, s: str): int` | append literal `s` to `b` at `at`; returns the new position |
| `io.pushnum(b, at, v: int): int` | append the decimal form of `v` |
| `io.digits(v: int): int` | render `v` into `io.nbuf`; returns the length |
| `io.put32(b, at, v)` | write `v` as 4 bytes, little-endian |
| `io.get16/get32/get64(b, at): int` | read 2/4/8 little-endian bytes |
| `io.now: int` | monotonic nanoseconds, for elapsed time |
| `io.realtime: int` | wall-clock nanoseconds since the epoch |

`STDIN`, `STDOUT`, `STDERR` are the fd constants. `io.push`/`io.pushnum` **truncate rather
than fail**: a negative `at` passes through unchanged (so a `-1` from a refusing routine
elsewhere travels a chain undamaged), and a full buffer gets as much as fits, returning
`len(b)`. Compare the returned position to the one passed in to detect either case.

`io.now`/`io.realtime` call `io.fatal` if the underlying clock read fails, rather than risk
returning a stale or zero time that looks real. Does not arise on Windows.

Limits: no formatted output beyond decimal integers, no line-oriented reading.

```pascal
include "io.wz";

var
  buf: array[0..63] of char;
  n: int;

begin
  n := io.push(buf, 0, "count = ");
  n := io.pushnum(buf, n, 42);
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

## `fs` — directories, file metadata, byte search

`include "fs.wz";` (pulls in `io.wz`)

Read-only: nothing here creates, writes, renames or deletes. `fs.open` is a convenience for
the read-only case; writing goes through `sys3(SYS.open, ...)` directly.

| routine | meaning |
|---|---|
| `fs.stat(a: int): bool` | fill `fs.size`, `fs.mode`, `fs.mtime` for the NUL-terminated path at `a`; `false` if unreachable |
| `fs.isdir: bool` / `fs.isfile: bool` | read `fs.mode` from the last `fs.stat` |
| `fs.open(a: int): int` | open the path read-only; returns the fd, or negative on failure |
| `fs.opendir(a: int): int` | open for reading directory entries; resets the directory cursor |
| `fs.close(fd)` | close a descriptor |
| `fs.next(fd): bool` | step to the next entry (skips `.`/`..`); fills `fs.name`, `fs.namelen`, `fs.type`; `false` when exhausted |
| `fs.find(h, from, upto, n, nlen): int` | first occurrence of `n[0..nlen)` in `h[from..upto)`; `-1` if absent |

`fs.stat` takes a raw address, not a `str` — build it with `io.push` plus a manual
`chr(0)` terminator. `fs.type` is one of the kernel's `DT_*` constants (`DT_DIR`, `DT_REG`,
`DT_LNK`). `fs.find` works on any `array of char`, not just file content, and uses the SIMD
`scan` builtin for its leading byte.

Limits: no recursive walk — `fs.opendir`/`fs.next` gives one directory at a time, and
recursing (using `fs.type = DT_DIR`) is the caller's job.

```pascal
include "fs.wz";

var
  path: array[0..15] of char;
  n, fd, count: int;

begin
  n := io.push(path, 0, "/tmp");
  path[n] := chr(0);
  fd := fs.opendir(addr(path[0]));
  if fd < 0 then io.fatal("cannot open directory");
  count := 0;
  while fs.next(fd) do count := count + 1;
  fs.close(fd);
  io.putn(STDOUT, count);
  io.puts(STDOUT, "\n");
end.
```

## `time` — calendar time without a time zone

`include "time.wz";` (pulls in `io.wz`)

A moment is an `int`: seconds since `1970-01-01T00:00:00Z`. Proleptic Gregorian calendar,
UTC only, no DST, no leap seconds. Day arithmetic is exact for years 1..9999 and beyond.

| routine | meaning |
|---|---|
| `time.days(y, m, d): int` | days since 1970-01-01 for the civil date |
| `time.join(y, m, d, hh, mm, ss): int` | the full moment for a civil date and time |
| `time.split(t: int)` | fills `time.year`, `.month` (1..12), `.day`, `.hour`, `.minute`, `.second`, `.weekday` (0=Mon..6=Sun), `.yday` (0=Jan 1) — a procedure, read the fields immediately |
| `time.leap(y: int): bool` | is `y` a leap year? |
| `time.daysin(y, m: int): int` | days in month `m` of year `y`; `0` outside `1..12` |
| `time.iso(dst, at, t: int): int` | write `t` as `YYYY-MM-DDTHH:MM:SSZ`; returns the new position |
| `time.parseiso(s: array of char): int` | parse ISO 8601; returns the moment, sets `time.ok` |
| `time.pad(dst, at, v, w: int): int` | write `v` as `w` zero-padded digits |
| `time.num(s, at, n: int): int` | read `n` decimal digits at `s[at]`; `-1` if not digits |
| `time.nowsec: int` | current moment (`io.realtime div 1000000000`) |

`time.parseiso` accepts a bare date, no zone (read as UTC), a fractional part (dropped), `Z`,
or a `+hh:mm` offset (subtracted to reach UTC); a space is accepted for the `T`, as Postgres
writes it. **It signals failure through `time.ok`, not the return value** — `-1` is itself a
valid moment, so always check `time.ok`.

Limits: no time zones beyond UTC, no duration/interval type, no calendar arithmetic beyond
moment ↔ date. `time.nowsec` shares `io.realtime`'s fatal-on-clock-failure behavior.

```pascal
include "time.wz";

var
  s: array[0..15] of char;
  n: int;
  t: int;

begin
  n := io.push(s, 0, "2026-09-11");
  t := time.parseiso(s[0..n - 1]);
  if time.ok then io.putn(STDOUT, t) else io.puts(STDOUT, "bad");
  io.puts(STDOUT, "\n");
end.
```

## `math` — real arithmetic beyond the operators

`include "math.wz";` (pulls in `json.wz`, and through it `io.wz`)

Plain Wantzel over `real`: range reduction plus a series, identical results on Linux and
Windows, no C math library. A few ULP of accuracy over the ranges the routines target, not
IEEE-754-exact at every corner. Constants: `MATH.PI`, `MATH.E`, `MATH.LN2`, `MATH.HALFPI`,
`MATH.TWOPI`.

| routine | meaning |
|---|---|
| `math.abs/max/min(...)` | absolute value, larger, smaller |
| `math.floor(x): real → int` / `math.ceil(x)` | round to `int`; `x` must fit in an `int` |
| `math.isnan(x): bool` | is `x` NaN? |
| `math.pow2i(k: int): real` | `2^k`, exact |
| `math.powi(x: real; n: int): real` | `x^n`, integer `n`, by repeated squaring |
| `math.pow(x, y: real): real` | `x^y`; NaN if `x < 0` and `y` non-integer |
| `math.exp(x): real` | saturates: `+inf`-shaped above `709.7`, `0.0` below `-745.0` |
| `math.log/log10/log2(x): real` | NaN for `x < 0`, large negative for `x = 0` |
| `math.sin/cos/tan/asin/acos/atan/atan2(...)` | trig; `asin`/`acos` NaN outside `[-1, 1]` |
| `math.radians(deg)` / `math.degrees(rad)` | conversions |
| `math.fixed(dst, at, x: real, decimals: int): int` | fixed decimals (clamped `0..15`), rounds half away from zero |
| `math.text(dst, at, x: real): int` | shortest general form, up to 15 significant digits |
| `math.parse(s: array of char): real` | parse a decimal number; sets `math.ok` |

**`math.parse` signals failure through `math.ok`**, not the return value — `0.0` is both a
legitimate result and the failure value. `math.ok` is also `false` for a partial match: the
whole slice must be one number.

Limits: no hyperbolic functions, no complex numbers, no statistics, no arbitrary precision.
Three routines are internal only — `math.reduce`, `math.sinr`, `math.cosr` — call `math.sin`/
`math.cos` instead; the three give a silently wrong answer outside the first quadrant.

```pascal
include "math.wz";

var
  buf: array[0..31] of char;
  n: int;

begin
  n := math.fixed(buf, 0, math.pow(2.0, 10.0), 2);
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

## `json` — JSON scanning and writing primitives

`include "json.wz";` (pulls in `io.wz`)

No tree: a value stays in the input buffer, described by `(offset, length)`. The generated
`schema` parsers are built on this; reach for it directly only for open-ended input (a proxy,
a log line) where a `schema` does not fit.

| routine | meaning |
|---|---|
| `json.ws(b, at, last): int` | skip whitespace; first non-blank position |
| `json.skip(b, at, last): int` | step over one whole value, however nested |
| `json.string(b, at, last): int` | scan a string; fills `json.sat`/`json.send` |
| `json.number(b, at, last): int` | scan a number's integer part into `json.ival` |
| `json.real(b, at, last): int` | scan a number as `real` into `json.rval`, up to 18 significant digits |
| `json.boolean(b, at, last): int` | scan `true`/`false` into `json.bval` |
| `json.isnull(b, at, last): bool` | is the value `null`? (does not consume) |
| `json.literal(b, at, last, s: str): int` | does `b` at `at` spell `s`? |
| `json.strend(b, at, last): int` | given `at` just past an opening quote, find the closing one |
| `json.eq(b, at, last, s: str): bool` | does `b[at..last)` equal `s`? |
| `json.escaped(b, from, upto): bool` | does `b[from..upto)` contain a backslash escape? |
| `json.unescape(src, from, upto, dst, at): int` | decode a string body into `dst`; `-1` on malformed escape or no room |
| `json.copystr(src, from, upto, dst): int` | the same, always from `dst[0]` |
| `json.putstr(dst, at, s: str): int` | append `s` as a quoted, escaped string — **truncates** |
| `json.putslice(dst, at, src, from, upto): int` | quoted, escaped slice — **refuses** (`-1`), does not truncate |
| `json.escslice(dst, at, src, from, upto): int` | escaped, no quotes — truncates |
| `json.putb(dst, at, c: char): int` | one raw byte — **refuses** |
| `json.putraw(dst, at, src, from, upto): int` | verbatim, no escaping — truncates |
| `json.putreal(dst, at, v: real): int` | up to 15 significant digits; NaN/infinity become `null` — truncates |

All readers take `(b, at, last)` with `last` exclusive and return `-1` on malformed or
truncated input — there is no position to continue from on failure. **Two different write
contracts**: `putstr`/`escslice`/`putraw`/`putreal` truncate silently (compare the returned
position to detect it, like `io.push`); `putslice`/`putb` refuse and return `-1` — always
test their result, because they back the generated `<Schema>.write`, where a half-written
object is a syntax error, not a shorter one. A negative `at` passed to any of them comes back
unchanged, so a `-1` can travel a chain of appenders and be tested once at the end.

Limits: no tree, no path lookup, no in-place mutation. Field lookup by key is
`kv.find`/`kv.first`/`kv.next` in `lib/kv.wz`; a whole typed object is a `schema` declaration.

```pascal
include "json.wz";

var
  buf: array[0..127] of char;
  n: int;

begin
  n := io.push(buf, 0, "{\"name\":");
  n := json.putstr(buf, n, "probe");
  n := io.push(buf, n, ",\"count\":");
  n := io.pushnum(buf, n, 42);
  n := io.push(buf, n, "}");
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

## `http` — a non-blocking HTTP/1.1 server on epoll

`include "http.wz";` (pulls in `net.wz` and `json.wz`)

One process, one event loop, no threads, no allocation. Every connection owns a fixed slice
of two static buffers (`http.inbuf`, `http.outbuf`); the application defines
`procedure app.request`, called once per complete request, reading the request through the
module's globals.

| routine | meaning |
|---|---|
| `http.serve(port, workers: int)` | bind and run the event loop; never returns. `workers > 1` forks that many, sharing the port via `SO_REUSEPORT` |
| `http.maxbody(cap: int)` | reserve room for a body bigger than `INBUF`; call before `http.serve` |
| `http.method: int` | `HTTP.GET/POST/PUT/DELETE/PATCH/OPTIONS/HEAD`, or `0` |
| `http.pathis(s: str): bool` / `http.pathstarts(prefix: str): bool` | path match; the rest is `http.inbuf[http.restat..http.restend)` |
| `http.header(name: str): bool` | case-insensitive lookup; value at `http.inbuf[http.hvat..http.hvend)` |
| `http.bearer: bool` | the `Authorization: Bearer` token |
| `http.param(key: str): bool` | query-string value at `http.pval[0..http.pvlen)` |
| `http.form(key: str): bool` | `application/x-www-form-urlencoded` body value |
| `http.urldecode(src, from, upto, dst): int` | percent-decode; `-1` if malformed or no room |
| `http.add(s: str)` / `.addn(v)` / `.addc(c)` / `.addb(b, at, n)` | append to the reply body |
| `http.hdradd(s: str)` / `.hdraddslice(name; b, from, upto)` | add a response header before `finish` |
| `http.finish(status: int, ctype: str)` | write status line, headers, body; queue the reply — must be the **last** call for this request |
| `http.logging: bool` | set `true` for one JSON line per request on `STDERR` |

`http.param`/`.form`/`.header` share result buffers — a second lookup overwrites the first;
copy out what you still need. `http.hdradd`/`.hdraddslice` silently drop a header if the 2 KB
header buffer is full.

Requests larger than `INBUF` (256 kB) get `413` unless `http.maxbody` was called — then one
oversized body at a time per worker is read into an `mmap`-ed region; inside `app.request`,
`http.bodyinbig: bool` says whether to read `http.inbuf[http.bodyat..]` or
`view(http.bigbase, http.bodylen)`. A reply bigger than `OUTBUF` (512 kB) becomes `500`
instead of being sent. `http.form` does not know about the overflow region.

**Any include that brings in `http.wz`** — `tools.wz`, `mcphttp.wz`, `router.wz`,
`openapi.wz` — makes `app.request` mandatory, even if `http.serve` is never called; an empty
body suffices. A stdio-only MCP server includes `toolsmcp.wz` instead and needs no HTTP at
all.

Limits: no routing table beyond `router.wz`, no middleware, no HTTPS (plaintext only — TLS is
not attempted here), no chunked transfer encoding (every reply carries `Content-Length`).

```pascal
include "http.wz";

procedure app.request;
begin
  if http.pathis("/health") then
  begin
    http.add("ok"); http.finish(200, "text/plain"); return;
  end;
  http.add("hello from wantzel\n");
  http.finish(200, "text/plain");
end;

begin
  http.serve(8080, 1);
end.
```

## `websocket` — a WebSocket server on the same port as `http`

`include "websocket.wz";` (pulls in `net.wz`, `base64.wz` and `http.wz`)

RFC 6455, on the SAME listening socket `http.wz` already has. This module never opens a
socket of its own; it takes over a connection that `app.request` hands it.

| routine | meaning |
|---|---|
| `ws.take(fd: int): bool` | call from `app.request` after `http.detach := true`; reads `Sec-WebSocket-Key`, sends `101`, returns `true` on success |
| `procedure app.wsframe(fd: int)` | (application-defined) once per complete frame; payload at `ws.in[fd * WS.INMAX + ws.at .. +ws.len)`, opcode in `ws.op` |
| `procedure app.wsclose(fd: int)` | (application-defined) once per connection end, any reason |
| `ws.poll(timeout: int): int` | drive the loop; `timeout` ms, `0` = don't block, `-1` = block; returns connections served |
| `ws.sendtext(fd; a: array of char; n: int): bool` | one text frame |
| `ws.send(fd; opcode; a; n): bool` | general form: `WS.TEXT`, `WS.BIN`, or a control opcode |
| `ws.sendempty(fd; opcode): bool` | a frame with no payload |
| `ws.closefd(fd; code: int)` | send a close frame and drop the connection |

The takeover: on an upgrade request, set `http.detach := true` and call `ws.take(http.fd)`
**before returning from `app.request`** — that is the only point where `http.wz`'s parsed
headers still describe the request. If `ws.take` returns `false`, undo the detach and close
the fd yourself. Control frames (ping/pong/close) never reach `app.wsframe`.

Close codes: `1000` normal; `4000`–`4999` reserved by RFC 6455 for application-defined
meanings.

Limits: `WS.MAXCONN` 256 connections, `WS.INMAX` 64 KB buffered input per connection (over
that: `ws.closefd(fd, 1009)`), `WS.OUTMAX` 64 KB per outgoing frame. `http.serve` cannot also
call `ws.poll`, so a program wanting both protocols runs its own loop (`http.accept`,
`http.readable`, `http.flush`, plus `ws.poll` on every wake) instead of calling
`http.serve`. A program that never includes `websocket.wz` is unaffected.

```pascal
include "websocket.wz";

procedure app.wsframe(fd: int);
var base: int;
begin
  base := fd * WS.INMAX;
  ws.ignored := ws.sendtext(fd, ws.in[base + ws.at .. base + ws.at + ws.len - 1], ws.len);
end;

procedure app.wsclose(fd: int);
begin
end;

procedure app.request;
begin
  if http.pathis("/ws") and http.header("upgrade") then
  begin
    http.detach := true;
    if not ws.take(http.fd) then
    begin
      http.detach := false;
      net.close(http.fd);
    end;
    return;
  end;
  http.start;
  http.add("plain HTTP still works on this port\n");
  http.finish(200, "text/plain");
end;
```
