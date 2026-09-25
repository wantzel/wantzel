# Library

**Every module in `lib/`, and a compact reference for the ones most programs touch directly.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

The library is part of the compiler: `import io;` reads the module `io` from the compiler
you run, never from disk, so a program and a compiler file always build the same executable.
Its source is `lib/` in this repository; `wantzel --lib io` prints the copy inside your
compiler, byte for byte the same. Read it, step into it, and change it in `lib/` followed by
`./build.sh`.

## Import and include

```pascal
import io;                  // a module: a bare name, no quotes, no .wz, no path
import json;
include "model.wz";         // a file of your own, next to this file
include "store/orders.wz";  // a file of your own, in a directory next to this file
```

`import` reads a module from the library inside the compiler; `include` reads a file, relative
to the directory of the file that names it. A module never comes from disk and a file never
from the library, so a `lib/` directory or a file of your own that happens to share a module's
name changes nothing about an `import`. Both are textual and read once; a module imported by
another module is there for the rest of the program too. The complete rules and every error
message are in [language.md §1b](language.md#1b-imports-and-includes); the mistakes people make
with them, and an example of files including each other, in
[writing-wantzel.md](writing-wantzel.md#imports-and-includes).

## All modules

| module | for |
|---|---|
| `acme` | getting a certificate from a certificate authority (RFC 8555) |
| `aead` | ChaCha20-Poly1305 as one operation (RFC 8439 §2.8) |
| `autocert` | a certificate a server gets and renews by itself, from inside its own event loop (ACME, HTTP-01); `http.https` uses it |
| `base64` | base64 encoding and decoding (RFC 4648) |
| `certstore` | keeping keys and certificates on disk, beside the binary |
| `chacha20` | the ChaCha20 stream cipher (RFC 8439) |
| `chain` | does a certificate chain up to something trusted? |
| `csr` | a certificate signing request, and a self-signed certificate (RFC 2986, 5280) |
| `der` | reading DER, and the parts of X.509 a TLS client needs (X.690, RFC 5280) |
| `dns` | hostnames to IPv4 and IPv6 addresses: a DNS stub resolver over UDP, and TCP when truncated |
| `fs` | directories, file metadata and reading, on raw syscalls |
| `hash` | open-addressing hash tables on caller-supplied arrays |
| `hkdf` | HKDF (RFC 5869) and the TLS 1.3 key schedule (RFC 8446 §7.1) |
| `hmac` | HMAC-SHA256 (RFC 2104 / RFC 4231) |
| `http` | a non-blocking HTTP/1.1 server on epoll, plain and HTTPS, with automatic certificates |
| `io` | output, numbers and little-endian byte packing |
| `json` | JSON scanning primitives |
| `jsonschema` | validating JSON against a JSON Schema (2020-12), the useful subset |
| `jws` | JSON Web Signature with ES256, and the JWK thumbprint (RFC 7515, 7638) |
| `kv` | helpers for a small JSON object kept as compact text |
| `log` | one JSON line per event on stderr, for journald or a file |
| `lz` | LZ compression, packing and unpacking: the format the compiler stores this library in |
| `math` | real arithmetic beyond the operators: `exp`, `log`, `pow`, trigonometry, text |
| `mcp` | Model Context Protocol over JSON-RPC 2.0 |
| `mcphttp` | MCP over HTTP: the endpoint routine for `app.request` |
| `net` | sockets and epoll, straight on top of the system calls; IPv4 and IPv6 (IPv6 on Linux only for now) |
| `oauth` | an OAuth 2.1 authorization server for MCP clients |
| `openapi` | an OpenAPI 3.1 document and a Swagger UI page, generated from a `tools` block |
| `p256` | the NIST P-256 curve and ECDSA verification (FIPS 186-4, SEC 2) |
| `p384` | ECDSA over NIST P-384 (secp384r1), verification only |
| `poly1305` | the Poly1305 one-time authenticator (RFC 8439) |
| `proc` | processes: forking, reaping, and knowing how it ended |
| `protobuf` | reader for the protobuf wire format |
| `rand` | random bytes and numbers from the kernel |
| `router` | a few helpers on top of `http.wz` for routing by path |
| `rsa` | RSA-2048 signature verification, for certificate chains that are not ECDSA |
| `sha1` | SHA-1 (RFC 3174) -- not a security primitive; kept only for protocols that name it (`websocket.wz`'s handshake) |
| `sha256` | SHA-256 (FIPS 180-4) |
| `sha384` | SHA-384 (FIPS 180-4) |
| `store` | durable tables of fixed-size records: an append-only log |
| `time` | calendar time without a time zone |
| `tls` | TLS 1.3: a blocking client, and a server that runs inside an event loop |
| `tools` | MCP and REST glue for a declared `tools` block |
| `toolsmcp` | the MCP half of the glue for a declared `tools` block |
| `uuid` | UUID version 4 (RFC 9562) |
| `websocket` | a WebSocket server (RFC 6455) that takes over a connection from `http.wz`, on the same port |
| `x25519` | X25519 key agreement on Curve25519 (RFC 7748) |
| `x509` | reading an X.509 certificate (RFC 5280), on top of `der.wz` |

`tools.wz`/`toolsmcp.wz` are the transport for a declared `tools ... end;` block — see
[language.md §7b](language.md#7b-tools--a-tool-table-as-a-declaration). Together
`tls.wz`, `x25519.wz`, `chacha20.wz`, `poly1305.wz`, `aead.wz`, `hkdf.wz`, `hmac.wz`,
`sha256.wz`, `sha384.wz`, `p256.wz`, `p384.wz`, `rsa.wz`, `der.wz`, `x509.wz`, `chain.wz`,
`csr.wz`, `certstore.wz`, `jws.wz`, `acme.wz` are a TLS 1.3 client and server with nothing
linked; `autocert.wz` puts them together into a server that keeps its own certificate.

The sections below cover the modules most programs touch directly. For the rest, the
routine comments in `lib/*.wz` are the reference, and [writing-wantzel.md](writing-wantzel.md)
already records several sharper pitfalls (`store.*`, `kv.*`, `oauth.*`, `sha256.hex`).

## `io` — output, numbers, byte access

`import io;`

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
returning a stale or zero time that looks real.

Limits: no formatted output beyond decimal integers, no line-oriented reading.

```pascal
import io;

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

`import fs;` (pulls in `io`)

Read-only: nothing here creates, writes, renames or deletes. `fs.open` is a convenience for
the read-only case; writing goes through `sys3(SYS.open, ...)` directly.

| routine | meaning |
|---|---|
| `fs.stat(a: int): bool` | fill `fs.size`, `fs.mode`, `fs.mtime` for the NUL-terminated path at `a`; `false` if unreachable |
| `fs.isdir: bool` / `fs.isfile: bool` | read `fs.mode` from the last `fs.stat` |
| `fs.open(a: int): int` | open the path read-only; returns the fd, or negative on failure |
| `fs.opendir(a: int): int` | open for reading directory entries; returns the fd, or negative (with `fs.err`/`fs.errno`) on failure |
| `fs.close(fd)` | close a descriptor, and free its directory slot if it had one |
| `fs.next(fd): bool` | step to the next entry (skips `.`/`..`); fills `fs.name`, `fs.namelen`, `fs.type`; `false` when exhausted or on error (see `fs.err`) |
| `fs.forget(fd)` | free `fd`'s directory slot WITHOUT closing `fd` — for a caller that owns the fd's lifecycle itself (see below) |
| `fs.find(h, from, upto, n, nlen): int` | first occurrence of `n[0..nlen)` in `h[from..upto)`; `-1` if absent |

`fs.stat` takes a raw address, not a `str` — build it with `io.push` plus a manual
`chr(0)` terminator. `fs.type` is one of the kernel's `DT_*` constants (`DT_DIR`, `DT_REG`,
`DT_LNK`). `fs.find` works on any `array of char`, not just file content, and uses the SIMD
`scan` builtin for its leading byte.

**A recursive walk works**: each `fs.opendir` gets its own read buffer and position, so
opening a child directory while a parent's `fs.next` loop is still in progress does not
disturb the parent — recursing (using `fs.type = DT_DIR`) is the caller's job, same as
before, but nesting it is now safe. Limits: at most 16 directories open at once, process-wide
(`FS.MAXOPEN` in `lib/fs.wz`); a 17th `fs.opendir` fails with `fs.errno = 24` (`EMFILE`) and
`fs.err` naming it, until an open one is `fs.close`d.

**If you open a directory your own way** (not through `fs.opendir` — your own path
resolution or an `openat` wrapper, say) and still read it with `fs.next`, that fd gets a
slot the same as `fs.opendir` would give it. Close that fd your own way too, and **call
`fs.forget(fd)` first.** Operating systems reuse fd numbers: without `fs.forget`, the next
thing opened can get the same number, and `fs.next` on it would find the old slot still
claimed and resume reading from the old directory's position instead of starting fresh. A
caller that always goes through `fs.opendir`/`fs.close` never needs `fs.forget` — that pair
already does this for you.

```pascal
import fs;

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

`import time;` (pulls in `io`)

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
import time;

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

`import math;` (pulls in `json`, and through it `io`)

Plain Wantzel over `real`: range reduction plus a series, no C math library. A few ULP of accuracy over the ranges the routines target, not
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
import math;

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

`import json;` (pulls in `io`)

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
import json;

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

`import http;` (pulls in `net`, `json` and `autocert`, which brings the TLS stack and
`dns`)

One process, one event loop, no threads, no allocation per request. The application defines
`procedure app.request`, called once per complete request, reading the request through the
module's globals. A request is parsed in place in `http.inbuf`; the reply is built in
`http.outbuf`. The same loop terminates TLS itself — see *HTTPS* below.

| routine | meaning |
|---|---|
| `http.serve(port, workers: int)` | bind and run the event loop; never returns. `workers > 1` forks that many, sharing the port via `SO_REUSEPORT` |
| `http.maxbody(cap: int)` | accept request bodies up to `cap` bytes (above `INBUF`, each read into a region of its own connection's); call before `http.serve` |
| `http.maxbodymem(total: int)` | what all large bodies being read at once may hold together (256 MB); past it, `503` with `Retry-After` |
| `http.maxreply(cap: int)` | allow reply bodies up to `cap` bytes (at least `OUTBUF`); a larger reply becomes `500` |
| `http.maxconn(n: int)` | at most `n` connections at once (1..`MAXCONN`); call before `http.serve` |
| `http.timeouts(idle, header, body, send: int)` | the deadlines in seconds, `0` keeps the default; call before `http.serve` |
| `http.addport(port: int)` | listen on one more port too (listener 1, 2, ... in call order; at most 3, one fewer with `http.redirect`); call before `http.serve` |
| `http.https(host, email, store: array of char; staging: bool)` | HTTPS with a certificate from Let's Encrypt, obtained and renewed from this loop; the port given to `http.serve` speaks TLS, and port 80 redirects. Call before `http.serve` |
| `http.httpsfiles(certfile, keyfile: array of char): bool` | HTTPS with the chain and key in PEM files; `false` and `http.tlswhy` when they do not load. Call again to replace the certificate while serving |
| `http.redirect(port: int)` | the plain port of HTTPS mode (80 unless set): challenges, redirects, never the application |
| `http.istls: bool` | the request being served came over TLS |
| `http.listen(port, workers: int)` / `http.poll(timeout: int): int` | `http.serve` in two halves, for a program with its own loop: bind (and fork), then one round per call — waits up to `timeout` ms (`-1`: until something happens, at most until the next deadline check) |
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
| `http.fd`, `http.slot`, `http.lis` | the connection being served: its fd, its slot, the listener it came in on |
| `http.nopen`, `http.refused`, `http.evicted`, `http.timedout`, `http.queued` | counters: open now, answered `503` (or, on a TLS port, closed) for want of a slot, closed to make room, closed by a deadline, replies that waited for the socket |
| `http.tlsrefused`, `http.tlsfailed`, `http.tlskept` | TLS counters: closed at once (no certificate yet, or no session free), sessions that failed (not TLS, a bad record, an alert), reads that decrypted to more than the slot could take at once |

`http.param`/`.form`/`.header` share result buffers — a second lookup overwrites the first;
copy out what you still need. `http.hdradd`/`.hdraddslice` silently drop a header if the 2 KB
header buffer is full.

**Large requests.** A body larger than `INBUF` (256 kB) gets `413` unless `http.maxbody(cap)`
was called. Then each body up to `cap` is read into a region of its own connection's, mapped
when its headers arrive and unmapped as soon as it is answered — several can arrive at once,
and an answered one costs nothing. All of them together may hold `http.maxbodymem` (256 MB by
default); a body that would go past it is answered `503` with `Retry-After`, and one larger
than `cap` (or than that total) `413`. Inside `app.request`, `http.bodyinbig: bool` says
whether to read `http.inbuf[http.bodyat..]` or `view(http.bigbase, http.bodylen)`; `mcp.http`
and `tool.rest` do this themselves, `http.form` does not. A client that sends `Expect:
100-continue` (curl, for a body over 1 MB) is answered `100 Continue` once its body is
accepted, and gets the refusal instead when it is not.

**Large replies.** A reply is built in `http.outbuf` until it outgrows it; then it moves, whole,
to a region of its own that doubles as it grows, up to `http.maxreply` (`OUTBUF`, 512 kB, by
default). Past that the reply becomes a clean `500`. In the clear the region itself becomes
the reply's queued output, so a large reply is never copied a second time; over TLS it is
sealed into one region that is. What waits for a slow reader counts against `http.pendmax`
(128 MB): a connection that would push the total past it is closed, the others are not
affected. Code that writes into `http.outbuf` itself (`json.putstr(http.outbuf, http.wpos,
...)`) must stay within its first 512 kB; past that, append with `http.add`/`addb`/`addc`/`addn`.

**Limits, per worker process:**

| | size | |
|---|---|---|
| connections at once | `MAXCONN` = 4096 | lower with `http.maxconn`; any fd below `HTTP.MAXFD` = 65536 |
| request (headers + body) | `INBUF` = 256 kB | more through `http.maxbody`, a region per connection |
| large bodies being read, together | `http.maxbodymem` = 256 MB | past it, `503` with `Retry-After` |
| reply body | `OUTBUF` = 512 kB | more through `http.maxreply`; past the limit, `500` |
| input every connection owns | `HTTP.SLOTIN` = 16 kB | a larger request borrows a chunk |
| shared input chunks | `HTTP.CHUNKS` = 64 of 256 kB | that many large requests can be arriving at once |
| unsent reply bytes held | `http.pendmax` = 128 MB | all connections together |

Static memory is about 86 MB (4 MB of it the TLS stack), most of it pages that are never
touched unless a connection uses them. TLS sessions add a region of 68 MB, mapped on the first
TLS connection and likewise touched only as records arrive in pieces. Large bodies and
replies take memory only while they exist, within the limits above: at most
`http.maxbodymem` (256 MB) of bodies once `http.maxbody` is set, one reply being built (up to
`http.maxreply`, and as much again while it is sealed for TLS) and `http.pendmax` (128 MB) of
output waiting for slow readers. `http.serve` raises the soft limit on open files to 65536 (never above the hard
limit).

**Deadlines.** A connection that makes no progress is closed. Defaults, changed with
`http.timeouts`:

| waiting for | default | counted |
|---|---|---|
| the request line and headers | 10 s | from the first byte, or from the accept; never extended |
| the body | 30 s + 1 s per 16 kB of `Content-Length` | from the end of the headers |
| the next keep-alive request | 60 s | from the end of the last reply |
| the client to read the reply | 30 s | without progress |

**When it is full.** With every slot taken, a new connection closes the quiet connection
nearest its deadline (one between requests, or that has not sent anything) and takes its
place. If every connection is in the middle of a request, the new one gets `503` with
`Retry-After: 1` and is closed. A request that needs a chunk while all 64 are borrowed gets
`503` too. Pipelined requests are answered in order, one reply after the other.

**Your own loop.** `http.listen(port, workers)` once, then `http.poll(timeout)` repeatedly,
with whatever else the program drives in between (`ws.poll`, a timer). The fd-based routines
of older loops — `http.accept`, `http.readable(fd)`, `http.flush(fd)`, `http.drop(fd)`,
`http.open[fd]` — still work, but only `http.poll` enforces the deadlines.

**Any import that brings in `http`** — `tools`, `mcphttp`, `router`, `openapi` — makes
`app.request` mandatory, even if `http.serve` is never called; an empty body suffices. A
stdio-only MCP server imports `toolsmcp` instead and needs no HTTP at all.

**HTTPS.** One call before `http.serve` makes its port speak TLS 1.3 (`tls.wz`); nothing in
`app.request` changes:

```pascal
http.https("www.example.com", "admin@example.com", "/var/lib/myapp/certs", false);
http.serve(443, 1);
```

`http.https` configures `autocert.wz` and adds a plain listener on port 80 (`http.redirect`
moves it). The listeners open, a certificate in the store is installed, and then
`http.poll` steps the certificate manager: it wakes at least once a second and calls
`autocert.tick`, so the challenge is answered by port 80 while an order is pending. Port 80
answers `/.well-known/acme-challenge/<token>` for the order in progress (`404` otherwise),
redirects everything else to `https://<host>[:port]<path>` — `301` for `GET`/`HEAD`, `308`
for the rest, which keeps the method — once a certificate is installed, and says `503` with
`Retry-After` before that. **It never runs the application.** On the TLS port, before the
first certificate, a connection is closed at once. `autocert.*` settings (`setdirectory`,
`settiming`, `pin`, `quiet`) can be changed between `http.https` and `http.serve`.

`http.httpsfiles(certfile, keyfile)` is the same without an authority: the chain (one or more
`CERTIFICATE` blocks, the server's own first) and a P-256 key (`EC PRIVATE KEY` or
`PRIVATE KEY`) from PEM files — for development, tests, or a private authority. It may be
called again while serving: the next handshake uses the new pair, open connections carry on.
With `http.redirect(port)` the plain port redirects to the `Host` the request named.
A program that installs its certificate itself with `tls.setcert` sets `http.tlsmain :=
true` instead.

What changes on a TLS connection, and what does not:

- the request is decrypted in `http.pull` and the reply sealed in `http.emit`; parsing,
  pipelining, keep-alive, chunks, the big-body region and every limit above are the same
  code. A read is at most 32 kB; what it decrypts to beyond the room in the slot is kept
  for the next read (`http.tlskept`), never dropped — in a region that exists only while it
  holds bytes, 32 MB for all connections together (past that a connection is closed)
- the **header deadline also covers the handshake**: from the accept to the end of the first
  request's headers, never extended — a client that stops mid-ClientHello is closed by it
- a slot's TLS session is freed with the slot; closing sends `close_notify`, except after a
  reply that did not go out whole
- a refused request (`413`, `503`) is not closed at once: the connection lingers up to 5 s,
  swallowing what the client still sends, so a client busy uploading reads the refusal
  instead of a reset
- no slot free: the connection is closed rather than answered with a plaintext `503`
- `lib/websocket.wz` works on plain listeners only; on a TLS connection `ws.take` refuses

Where the time goes: a new handshake costs milliseconds of CPU (the P-256 signature), so new
connections per second are in the low hundreds per core; a request on an established
keep-alive connection costs a few times what it does in the clear. Keep connections alive.
HTTPS mode runs one worker (`http.serve(443, 1)`): two would each order a certificate. A certificate-manager step blocks the loop for one
request to the authority, bounded by its timeout (10 s), a few times per order.

Limits: no routing table beyond `router.wz`, no middleware, no chunked transfer encoding
(every reply carries `Content-Length`), no HTTP/2.

```pascal
import http;

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

## `mcp` — an MCP server, and how large its messages may be

`import toolsmcp;` for a server over stdio (pulls in `mcp` and `json`);
`import tools;` and `import mcphttp;` to serve the same tools over HTTP. The tools
themselves are a declared `tools ... end;` block — see
[language.md §7b](language.md#7b-tools--a-tool-table-as-a-declaration). `mcp.stdio` reads
one JSON-RPC message per line; `mcp.http`, called from `app.request`, answers one per POST.

**Limits.** Three variables, set before the transport starts; `0` keeps the default.

| variable | default | bounds | past it |
|---|---|---|---|
| `mcp.maxin` | 64 MB | one request message: a stdio line, an HTTP body | JSON-RPC error `-32600` (over stdio the line is dropped and the next one read) |
| `tool.maxout` | 64 MB | the result JSON of one tool call | JSON-RPC error `-32603`; over REST (`tool.rest`) a 500 |
| `mcp.maxout` | 160 MB | one reply message | JSON-RPC error `-32603` |

A reply carries a tool result twice — escaped as a text block and as `structuredContent` — so
`mcp.maxout` is larger than `tool.maxout`. The error names the limit that was hit, in the
message and as `data.limit`, and carries the caller's id when the request had one:

```json
{"jsonrpc":"2.0","id":12,"error":{"code":-32603,"message":"the tool result is larger than the maximum of 8388608 bytes","data":{"limit":8388608}}}
```

Nothing is ever cut short: a writer that does not fit makes the whole reply this error.

**Memory.** A message that fits the static buffers — `mcp.in` and `mcp.buf`, 4 MB each, and
`tool.out`, 1 MB — costs no system call. A larger one moves once into an anonymous mapping as
large as its limit; on Linux a page of it costs memory only when written. The request and
reply mappings are given back as soon as the message is answered. Tool results are written
into a mapping of `tool.maxout` made at the first call and kept for the next, and given back
after a result larger than 1 MB; with `tool.maxout` at 1 MB or less, `tool.out` is used and
nothing is mapped. Worst case with the defaults, while one maximum call is answered: 64 +
64 + 160 = 288 MB on top of the program's own records; between calls, at most 1 MB more than
the static buffers. `mcp.mapped` and
`mcp.mappedbytes` say what is held right now.

**Over HTTP** the message must fit the HTTP layer too: call `http.maxbody(n)` before
`http.serve` to accept requests larger than 256 kB, and `http.maxreply(n)` to send replies
larger than 512 kB. A reply larger than `http.maxreply` is answered with the JSON-RPC error
for `mcp.maxout`, naming that smaller size.

**A transport of your own** calls `n := mcp.handle(b, at, last)`: the reply is `n` bytes at
`view(mcp.obase, n)` — in `mcp.buf` whenever it fits there — and `mcp.done` gives a
mapping back once they have been sent. A `text`/`json` view field in the output schema is
built in `tool.vbuf`, 1 MB; a handler that fills it past that limit is refused with a
handler-side failure naming the tool and the limit (`tool <name>: reply exceeds 1048576
bytes`), not a reply built from silently truncated text. For a result that may exceed it,
use `text[N]` fields and arrays instead.

## `autocert` — a certificate that a server gets and keeps by itself

`import autocert;` (pulls in `tls`, `chain`, `acme`, `certstore`, `dns`)

**A server on `http.wz` does not call any of this itself: `http.https` does** (see *HTTPS*
in the `http` section). The routines below are for a program with a loop of its own.

A state machine that a server's own event loop steps: it orders a certificate from Let's
Encrypt (or any ACME authority) with the HTTP-01 challenge, keeps it on disk, renews it, and
hands each new one to the TLS server with `tls.setcert` — no certbot, no cron, no second
process, no restart. Every request to the authority is HTTPS whose certificate must chain to
a trusted root.

| routine | meaning |
|---|---|
| `autocert.sethost(h: array of char)` | the name the certificate is for (one name) |
| `autocert.setemail(e: array of char)` | a contact address for the account (optional) |
| `autocert.usestaging: bool` | `true`: Let's Encrypt's staging authority. Default: production |
| `autocert.setdirectory(url: array of char)` | another authority's directory URL (`https://` only); overrides staging |
| `autocert.setstore(dir: array of char)` | where keys and certificates live; default `certs/` beside the binary |
| `autocert.pin(name, a, b, c, d: int): bool` | a fixed IPv4 address for a name, used instead of DNS (the authority's name is otherwise resolved with `dns.resolve`) |
| `autocert.settiming(checkms, renewsec, retryms, timeoutms: int)` | check interval (1 day), renew window (30 days), first retry (1 h), one request (10 s); `0` keeps a value |
| `autocert.start: bool` | load what is stored, install a usable certificate, check the configuration; no network yet |
| `autocert.tick` | call from the loop's timer; does nothing until something is due, then **at most one** request |
| `autocert.waitms: int` | milliseconds the loop may sleep before the next `tick` matters |
| `autocert.answer(path, dst: array of char): int` | for `GET /.well-known/acme-challenge/<token>`: the key authorization in `dst` and its length, or `-1` (answer 404) |
| `autocert.havecert: bool`, `autocert.notafter: int` | a certificate is installed; its expiry in seconds since the epoch |
| `autocert.msg[0..autocert.msgn)` | the last log line; `autocert.quiet := true` keeps them off `STDERR` |

**What happens, and when.** At `start` a stored certificate that parses, matches its key,
names the host and is in date is installed at once, and **not** ordered again while it has
more than 30 days left — a restart is free, which matters because Let's Encrypt limits
orders per name. The certificate is renewed when fewer than 30 days (or a third of its
lifetime) remain. An order is directory → nonce → account (key created once and kept) → new
order → authorization → challenge → poll → finalize with a **new** key and CSR → poll →
download; the chain is then checked (host, our key, dates, each link signed by the next),
saved, and installed — the whole chain, leaf first, since a browser has only the root. A failure keeps the old certificate in service and retries after 1 h,
6 h, then every 24 h — or later if the authority sends `Retry-After` — and that schedule is
stored, so a crash-looping service does not hammer the authority either.

**The loop's side.** The challenge is fetched by the authority *while the order is
pending*, so the loop must keep serving port 80 between steps — which is why each `tick`
does one request and returns:

```pascal
if not autocert.start then halt(1);
while true do
begin
  wait := autocert.waitms;
  if wait > 1000 then wait := 1000;
  nev := net.wait(ep, addr(evs[0]), MAXEV, wait);
  ...   // port 80: n := autocert.answer(path, body); n >= 0: 200 with body[0..n), else 404
  ...   // port 443: a tls.open session per connection, fed by the loop (as http.wz does)
  autocert.tick;
end;
```

**The store** is one directory (0700, files 0600, every write atomic): `account.key`,
`<host>.pem` (the certificate key and chain in one file, so a crash cannot pair a new key
with an old certificate) and `<host>.retry`. The keys are PEM `EC PRIVATE KEY`, which
openssl reads. A missing or read-only store works — without a cache — and says so.

Limits: HTTP-01 only (no wildcards), one name per certificate, no revocation. A step blocks
the loop for the length of one HTTPS request: the name lookup (at most 12 s), the connect and
every TLS call are each bounded by the request timeout (10 s). `examples/autocertd.wz` is a
complete server on `http.https`.

## `websocket` — a WebSocket server on the same port as `http`

`import websocket;` (pulls in `net`, `base64`, `http` and `sha1`)

RFC 6455, on the SAME listening socket `http.wz` already has. This module never opens a
socket of its own; it takes over a connection that `app.request` hands it.

| routine | meaning |
|---|---|
| `ws.take(fd: int): bool` | call from `app.request` after `http.detach := true`; reads `Sec-WebSocket-Key`, sends `101`, returns `true` on success |
| `procedure app.wsframe(fd: int)` | (application-defined) once per complete frame; payload at `ws.in[ws.slot * WS.INMAX + ws.at .. +ws.len)`, opcode in `ws.op` |
| `procedure app.wsclose(fd: int)` | (application-defined) once per connection end, any reason |
| `ws.poll(timeout: int): int` | drive the loop; `timeout` ms, `0` = don't block, `-1` = block; returns connections served |
| `ws.sendtext(fd; a: array of char; n: int): bool` | one text frame |
| `ws.send(fd; opcode; a; n): bool` | general form: `WS.TEXT`, `WS.BIN`, or a control opcode |
| `ws.sendempty(fd; opcode): bool` | a frame with no payload |
| `ws.closefd(fd; code: int)` | send a close frame and drop the connection |

The takeover: on an upgrade request, set `http.detach := true` and call `ws.take(http.fd)`
**before returning from `app.request`** — that is the only point where `http.wz`'s parsed
headers still describe the request. If `ws.take` returns `false`, undo the detach and close
the fd yourself. Control frames (ping/pong/close) never reach `app.wsframe`. WebSocket runs
on plain listeners only: on a TLS connection (`http.istls`) `ws.take` returns `false`.

**Connections live in slots, not at their fd** — the same shape `http.wz` uses for its own
`MAXCONN` connections. `ws.in` (and every other per-connection table) is sized and indexed
by slot, not by fd, so inside `app.wsframe`/`app.wsclose` the base into `ws.in` comes from
`ws.slot` (set by this module right before the call), never from `fd` — an fd can be
arbitrarily large (up to `WS.MAXFD`, matching `http.wz`'s own fd range) while only
`WS.MAXCONN` connections are open at once.

Close codes: `1000` normal; `4000`–`4999` reserved by RFC 6455 for application-defined
meanings.

Limits: `WS.MAXCONN` 256 connections open at once, `WS.MAXFD` 65536 (the fd range `ws.take`
accepts — matches `http.wz`'s own), `WS.INMAX` 64 KB buffered input per connection (over
that: `ws.closefd(fd, 1009)`), `WS.OUTMAX` 64 KB per outgoing frame; `ws.take` refuses once
256 connections are already open, whatever the fd. `http.serve` cannot also call `ws.poll`,
so a program wanting both protocols runs its own loop — `http.listen` once, then `http.poll`
and `ws.poll(0)` on every wake — instead of calling `http.serve`. A program that never
imports `websocket` is unaffected.

```pascal
import websocket;

procedure app.wsframe(fd: int);
var base: int;
begin
  base := ws.slot * WS.INMAX;
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

## `dns` — hostnames to IPv4 and IPv6 addresses

`import dns;` (pulls in `net` and `rand`)

A stub resolver: it asks the nameservers the system is configured with, over UDP, and again
over TCP when an answer comes back truncated. `dns.resolve`/`dns.start`/`dns.poll` are A
(IPv4) only, unchanged in shape from before: an address is one `int`,
`a shl 24 + b shl 16 + c shl 8 + d`. `dns.resolve6`/`dns.start6`/`dns.poll6` are their AAAA
(IPv6) counterparts: an address does not fit in one `int` (128 bits against 64), so these
take a flat byte buffer instead, 16 bytes per address, network order. A name that is
already a literal (a dotted IPv4 quad for the `*4`/plain calls, the colon form for the
`*6` ones) comes back as itself, and `localhost` as `127.0.0.1` or `::1`, without a query.

| routine | meaning |
|---|---|
| `dns.resolve(name: array of char; out: array of int): int` | look up A records and wait, at most the lookup's total time (12 s); the number of addresses written to `out`, or a negative `DNS.*` code |
| `dns.resolve6(name: array of char; out: array of char): int` | the AAAA counterpart; `out`'s length must be a multiple of 16 |
| `dns.connect(name: array of char; port: int): int` | resolve BOTH A and AAAA (concurrently, so one slow record type does not delay the other), then connect to the first address that accepts — IPv6 addresses tried before IPv4, each in the order its records came back; the fd, or a `DNS.*` code (`DNS.NOCONNECT` when it resolved but nothing accepted) |
| `dns.start(name: array of char): int` · `dns.start6(name: array of char): int` | begin a lookup without blocking; a query number, or `DNS.BUSY` |
| `dns.poll(q: int; out: array of int): int` · `dns.poll6(q: int; out: array of char): int` | never blocks: `DNS.PENDING` (`0`) while running, then the count or a `DNS.*` code; collecting frees `q` (use `dns.poll6` for a query started with `dns.start6`) |
| `dns.fd: int` | the resolver's own epoll set — watch it for `EPOLLIN` in yours (shared between A and AAAA queries) |
| `dns.wait: int` | milliseconds until the next deadline, for your `epoll_wait`; `-1` when nothing runs |
| `dns.cancel(q: int)` | drop a lookup, of either kind |
| `dns.error(code: int): str` | a sentence for a `DNS.*` code |
| `dns.parseip(s: array of char): int` | a dotted-quad literal as an address, or `-1` |
| `dns.ipstr(dst, at, ip: int): int` | append an IPv4 address as text; returns the new position |
| `dns.parseip6(s: array of char; out: array of char): bool` | an IPv6 literal (with at most one `::` run) into 16 bytes, network order |
| `dns.ipstr6(dst, at: int; ip6: array of char): int` | append an IPv6 address as text, uncompressed (eight groups of four lower-case hex digits); returns the new position |
| `dns.loadconf(path: array of char): int` | read nameservers and options from a `resolv.conf`-style file; the count, or a negative errno |
| `dns.noservers` · `dns.addserver(a, b, c, d, port: int): bool` | replace the configured servers (at most `DNS.MAXNS`, 3) |
| `dns.settimeout(tryms, totalms: int)` | per attempt (5000, as the C library) and per lookup (12000); `0` keeps a value |
| `dns.flush` | empty the cache (both A and AAAA entries) |

The failures are kept apart, because they mean different things: `DNS.NXDOMAIN` (the name
does not exist), `DNS.NODATA` (it exists, without an address of the type asked), `DNS.SERVFAIL`,
`DNS.REFUSED`, `DNS.TIMEOUT` (no server answered), `DNS.BADNAME` (not a hostname: a bad
label, or a last label of digits only, such as a broken address),
`DNS.BADREPLY` (an answer that does not parse, or a CNAME chain that loops), `DNS.NETWORK`
(no socket, or nothing listens), `DNS.BUSY`, and from `dns.connect` `DNS.NOCONNECT`.
`DNS.NODATA` is type-specific: a name with only AAAA records answers `DNS.NODATA` to an A
query and its address to an AAAA one, and the other way round.

**Where the servers come from.** `/etc/resolv.conf`, on the first lookup: up to three
`nameserver` lines with an IPv4 address, and `options timeout:n attempts:n`. No server at
all means `127.0.0.1`, as the C library does.

**What a lookup does.** Every attempt has a fresh random id and its own socket on a random
source port, connected to the server; a reply counts only when its id and its question
(including the type asked, A or AAAA) match, so a forged datagram is ignored rather than
believed. A silent server costs one attempt's timeout and the next server is asked;
`SERVFAIL`, `REFUSED` and an unreachable port move on at once; `NXDOMAIN` is final. CNAME
chains are followed through the answer, under either type — only records on the chain
count — and a chain that stops short is asked for under its last name. Compressed names are
read with pointers followed only backwards, so a loop cannot hang it. Answers are cached by
name AND type (an A and an AAAA lookup of the same name are two cache entries), for their
TTL (32 names total); failures are not.

Limits: no `search` domains and no `/etc/hosts` beyond `localhost`, so give a full name;
`DNS.MAXQ` (8) lookups at once, of either type, sharing the same pool of slots.
`dns.connect`'s IPv6 support goes through `net.connect6`.

```pascal
import dns;

var
  addrs: array[0..DNS.MAXADDR - 1] of int;
  line: array[0..63] of char;
  n, i, at: int;

begin
  n := dns.resolve("localhost", addrs);
  if n < 0 then
  begin
    io.puts(STDERR, dns.error(n));
    io.puts(STDERR, "\n");
    halt(1);
  end;
  for i := 0 to n - 1 do
  begin
    at := dns.ipstr(line, 0, addrs[i]);
    at := io.push(line, at, "\n");
    io.out(STDOUT, addr(line[0]), at);
  end;
end.
```

From an epoll loop, without blocking: start the lookup, put `dns.fd` in your set once, wait
no longer than `dns.wait`, and ask `dns.poll` after every wake. `examples/host.wz` is the
blocking form as a command-line tool.

```pascal
q := dns.start("example.com");
if not net.watch(ep, EPOLL_ADD, dns.fd, EPOLLIN) then ...
while true do
begin
  n := dns.poll(q, addrs);                 // DNS.PENDING (0), a count, or a DNS.* code
  if n <> DNS.PENDING then break;
  r := net.wait(ep, addr(ev[0]), 16, dns.wait);   // serve your other fds here too
end;
```

## `tls` — TLS 1.3, a blocking client and an event-loop server

`import tls;` (pulls in the crypto modules it needs)

TLS 1.3 only, one cipher suite (`TLS_CHACHA20_POLY1305_SHA256`), one group (X25519). The
server signs with one P-256 key. No TLS 1.2, no resumption, no client certificates, no
HelloRetryRequest, no ALPN (clients then speak HTTP/1.1).

**The client** is blocking and handles one connection at a time:

| routine | meaning |
|---|---|
| `tls.connect(fd: int; host: str): bool` | the handshake on a connected socket; `tls.connectb(fd, hb, hn)` takes the name as bytes |
| `tls.write(b: array of char; n: int): bool` | send application data |
| `tls.read(b: array of char; max: int): int` | receive; `0` at close_notify, `-1` on error |
| `tls.close` | send close_notify |
| `tls.verified: bool` | the server proved its key and its chain reaches a root in the trust store (`chain.wz`) |
| `tls.deadline: int` | milliseconds each call above (and `tls.accept`) may take; `0` means 30 s. Past it the call fails with `tls.err = -110`. The socket is switched to non-blocking mode for this |

**The server** never touches a socket. The program's event loop owns each connection, hands
its session the bytes that arrived, and sends the bytes it gets back. Nothing blocks, so one
thread holds up to `TLS.MAXSESS` (4096) connections, and a client that stalls halfway through
its handshake costs its own session and nothing else.

| routine | meaning |
|---|---|
| `tls.setcert(chain: array of char; n: int; key: array of int): bool` | install the chain (DER certificates back to back, leaf first) and the leaf's P-256 private key; refused, keeping the old pair, unless the key matches the leaf |
| `tls.open: int` | a session for a new connection; `-1` when no certificate is installed or all are in use |
| `tls.feed(s: int; src, app, wire: array of char): int` | the bytes that arrived, `src`; returns how many were taken, `-1` when the session failed. Afterwards `app[0..tls.appn)` is decrypted data and `wire[0..tls.wiren)` must be sent — also on `-1`, when it is the alert |
| `tls.seal(s: int; src, wire: array of char): int` | encrypt `src` into `wire`; the number of bytes to send, `-1` when not established or `wire` is too small (it needs `len(src)` + 22 per 16 KB) |
| `tls.shut(s: int; wire: array of char): int` | our close_notify into `wire`: its length, or `0` |
| `tls.free(s: int)` | give the session back; its keys are wiped |
| `tls.state(s: int): int` | `TLS.ST.HANDSHAKE`, `TLS.ST.OPEN`, `TLS.ST.CLOSED` (the peer sent close_notify), `TLS.ST.FAILED`, `TLS.ST.UNUSED` |
| `tls.code(s: int): int`, `tls.why: str` | the alert that ended a failed session, and a sentence saying why |
| `tls.accept(fd: int): bool` | the blocking form: the whole handshake on one socket, then `tls.read`/`tls.write`/`tls.close` |

One step of the loop, when a TLS socket is readable:

```pascal
n := net.recv(fd, addr(raw[0]), len(raw));
used := tls.feed(s, raw[0..n - 1], inbuf[have..len(inbuf) - 1], outbuf);
// send outbuf[0..tls.wiren) -- the handshake flight, or the alert when used < 0
have := have + tls.appn;                 // decrypted request bytes
if used < 0 then ...                     // close the connection after sending
if used < n then ...                     // inbuf is full: keep raw[used..n-1], feed it later
```

- **Partial input is held by the session.** A ClientHello split across TCP segments or
  records, a record cut in half by a read — `tls.feed` keeps the piece and takes all of
  `src`. The one exception: a record is not opened until its plaintext fits in `app`, and
  then `tls.feed` returns less than `len(src)`. An `app` of `TLS.MAXPLAIN` (16384) bytes
  always has room for one record.
- **`wire` needs `TLS.MAXREC` (18432) bytes free while the handshake runs**: the server
  flight is built whole the moment the ClientHello is complete, and carries the certificate
  chain. After it, `tls.feed` only writes a KeyUpdate answer or an alert.
- **Malformed input fails that session only**: an alert goes into `wire`, `tls.state` says
  `TLS.ST.FAILED`, and every other session carries on. The caller closes the connection and
  calls `tls.free`.
- **`tls.setcert` is safe while sessions are open.** The next handshake uses the new chain;
  open sessions keep their keys.
- **The client and the server keep separate state**: a blocking `tls.connect` (to an ACME
  authority, say) can run while server sessions are open.
- A deadline is the caller's: a session never times out on its own, so the loop closes a
  connection that has not finished its handshake or request in time.

Memory: 256 bytes per session in a static table, plus 16645 bytes of reassembly each in a
region mapped by the first `tls.open` (68 MB of address space for 4096 sessions; only pages
that a record arrives into in pieces are ever touched). A program that only uses the client
maps nothing. Throughput on one core, measured on an x86-64 laptop: about 150 handshakes a
second (ECDSA signing is most of it) and about 30 MB/s of encrypted data.

`examples/serve.wz` is the complete server: HTTP and HTTPS on one loop, the ACME challenge,
and a certificate picked up from disk while running. `examples/localhttps.wz` is the
smallest one, on `tls.accept`.

## `lz` — packing and unpacking

`import lz;` (pulls in nothing)

The simplest LZ block format: runs of literal bytes and back-references into what was
written already, no entropy coding. Source text packs to about half its size; unpacking runs
at a few hundred MB/s. It is the format the compiler stores this library in, so it is
exercised on every `import`.

| routine | what it does |
|---|---|
| `lz.pack(src, n, dst): int` | `src[0..n)` packed into `dst`; the packed length, or `-1` when `dst` is too small |
| `lz.unpack(src, n, dst): int` | `src[0..n)` unpacked into `dst`; the original length, or `-1` when `dst` is too small or `src` is not a whole, valid stream |
| `lz.bound(n): int` | the largest result `lz.pack` can give for `n` bytes — size `dst` by it and packing never fails |

`lz.unpack` checks every count and offset before it uses it: damaged or hostile input gives
`-1`, never a read or write outside a buffer and never a runtime error. The same input always
packs to the same bytes. The format itself is described at the top of `lib/lz.wz`.
