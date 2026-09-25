# Changelog

**What changed, per version — three kinds of change, because they ask different things of you.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

| | what it affects | what it means for you |
|---|---|---|
| **Language** | anyone who **wrote** Wantzel code | a program that compiled yesterday may not today, or may mean something else |
| **Compiler** | anyone who **compiles** | the same program, the same meaning — but different messages, different code, different limits |
| **Library** | anyone who **imports** a library module | a routine, its behaviour or text it emits changed; your own code may need to follow |

**Before 1.0, a Language entry can appear in any release.** A construct that costs more than
it gives is removed rather than kept — see [`language.md`](language.md) §9. Read that row
first on every upgrade.

Newest first. Dates are the day the change landed.

## 0.5.0 — 25 September 2026

**One file.** The compiler now carries its standard library: download
`wantzel-linux-x86_64` and it compiles anything, with no `lib/` directory beside it and no
archive. A library module is imported with a new statement, `import io;`; `include` is for
files of your own and nothing else. (W-0000-0284) And a program no longer carries the
routines it never calls: a hello world is about 2 kB. (W-0000-0285)

**What may need your attention** if your program compiles today:

- `include "io.wz";` for a library module becomes `import io;` — no quotes, no `.wz`. The
  old form is refused, and the message gives the line to write. For a directory of sources:
  `for m in $(wantzel --lib); do sed -i "s/^\( *\)include \"$m\.wz\";/\1import $m;/" *.wz; done`.
  Rename a file of your own that has a module's name first: its include must stay one.
- `import` is a keyword now; a name `import` in your code must change.
- A `lib/` directory beside the compiler is no longer read, and nothing replaces a module:
  to try a changed copy, include it as a file (`include "./tls.wz";`).
- The release is one file, `wantzel-linux-x86_64` (no version in the name, so
  `.../releases/latest/download/wantzel-linux-x86_64` always points at the newest), with
  `SHA256SUMS`. There is no `.tar.gz` any more.

**Language**

- `import <module>;` reads a module of the standard library inside the running compiler —
  a bare name; nothing on disk, no variable, no flag.
- `include "path.wz";` is always a file, relative to the file that contains it (or absolute).
  A bare name is no longer looked up in the library first.

**Compiler**

- The standard library is a packed trailer after the compiler's ELF image; `wantzel --lib`
  lists its modules and `wantzel --lib <module>` prints one; `--version` reports the modules,
  their size and a sha256 over their source.
- A library module is named `wantzel/lib/<module>.wz` in messages, runtime checks and debug
  information, wherever the compiler is installed: the same source gives the same executable
  from a checkout and from a download (it used to carry the install directory's name).
- Every wrong spelling of an import or an include is refused with the right one:
  `import "io";`, `import io.wz;`, `include io;`, `include "io.wz";` without such a file,
  and an unknown module (with the nearest name).
- The hint "there is an include further down this file" looks for an include or an import at
  the start of a line; it fired on the word in comments and strings.
- The bootstrap compiler (`bootstrap/boot.c`) carries no library and refuses `import`.
- A routine your program never calls, directly or indirectly, no longer reaches the
  executable: the compiler builds the call graph from its own relocations, then compacts
  the code it keeps. Always on, no flag -- except under `--debug`, which skips this pass
  because the sidecar's addresses are written as the code is generated, before compaction
  would know what moved. A `--debug` build is therefore larger than a plain one, and no
  longer byte-identical to it.
  Measured against 0.4.0: `hello.wz` with an unused `import tls;` drops from 348 KB to
  56 KB, `examples/serve.wz` from 500 KB to 257 KB, and `examples/mcpfiles.wz`, which uses
  most of what it imports, from 847 KB to 707 KB. (W-0000-0285)

**Library**

- `lz.wz`, new: `lz.pack`, `lz.unpack`, `lz.bound` — the compression the compiler stores the
  library with; damaged input gives `-1`, never a read past a buffer.
- The examples `autocert.wz` and `jsonschema.wz` are now `autocertd.wz` and `jsoncheck.wz`,
  so that no file outside `lib/` has a module's name.

- `lib/oauth.wz` (security): a `redirect_uri` or `state` could carry a percent-encoded CR LF
  into the `Location` header of the redirect (header injection), and a registered
  `redirect_uri` or `client_name` could put markup on the sign-in page. `/register` now
  refuses a `redirect_uri` that is not `http://` or `https://` or holds a control character,
  space, quote, backslash, backtick or angle bracket; `/authorize` (GET and POST) refuses such
  a `redirect_uri` or `state`, and a `state` with `&`; the client name is HTML-escaped. A
  client that registered such a `redirect_uri` before can no longer use it. (25 September)

## 0.4.0 — 25 September 2026

**One target: Linux x86-64.** The compiler now emits a static ELF for Linux and nothing else.
The Windows backend -- the PE writer, the Windows runtime, `winapi` and `winproc` -- is gone,
and with it a quarter of the compiler's source: it is one file again, `src/wantzel.wz`, and
compiles itself in about 9 ms. On Windows, run Wantzel under WSL. The library gains IPv6 and
AAAA lookups, re-entrant directory walks, and constant-time ECDSA signing.

**What may need your attention** if your program compiles today:

- `--target=` is no longer an option, and `winapi(...)` / `winproc(...)` no longer exist. A
  program or build script that uses either stops compiling. There is no replacement on
  Linux, where `sys1`..`sys6` reach the kernel directly.
- `lib/websocket.wz`: inside `app.wsframe` and `app.wsclose`, the base into `ws.in` is
  `ws.slot * WS.INMAX`, no longer `fd * WS.INMAX`.
- `lib/fs.wz`: a directory opened without `fs.opendir` and closed without `fs.close` must
  call `fs.forget(fd)`; code that read `fs.dbuf`/`fs.dlen`/`fs.dpos` directly no longer
  compiles (they are per-directory now, and internal).
- A `tools` handler that fills `tool.vbuf` to its 1 MB limit is now refused with an error
  instead of answering with truncated text.

**Compiler**

- A `tools` handler that fills `tool.vbuf` (1 MB, a `text`/`json` view field in the output
  schema) to its limit is now refused loudly, naming the tool and the limit, instead of
  the generated writer silently going on with truncated text (W-0000-0257). The check is
  generated once as a shared routine rather than copied into every tool's arm, so a
  program with many tools no longer pays for it per tool (W-0000-0275).
- The compiler targets Linux only: a static x86-64 ELF. Windows output (`--target=windows`,
  the PE writer and the runtime that translated syscalls to the Windows API) and the
  `winapi`/`winproc` builtins are gone, and `--target=` is no longer an option.
- `bootstrap/boot.c`, the C bootstrap compiler, no longer implements `schema`, `tools`
  or `--debug`: none of that is needed to compile `src/wantzel.wz` itself, which is the
  only job this file has. It refuses those loudly instead of miscompiling them. The
  bootstrap fixed point is now stage2 = stage3
  (both produced by the self-hosted compiler); stage1, produced by `boot.c`, only has to be
  correct, not byte-identical. See [design.md](design.md#bootstrapping-one-small-c-compiler-once).
- `src/compiler.wz` is folded back into `src/wantzel.wz`: one file holds the compiler and
  its command line, as before 17-09-2026. The split let a host include the compiler
  without its own executable ending the program; nothing ended up using that from outside
  this repository, and one file is simpler.

**Library**

- `lib/net.wz` gains IPv6 sockets: `net.connect6`, `net.listen6`, `net.socket6`, on top of
  `AF_INET6` and a 28-byte `sockaddr_in6`. `net.listen6` sets `IPV6_V6ONLY`, so it can share a port
  number with a `net.listen` on the same machine instead of colliding with it.
- `lib/dns.wz` resolves AAAA records: `dns.resolve6`, `dns.start6`, `dns.poll6`, alongside
  the existing A-only `dns.resolve`/`dns.start`/`dns.poll`, sharing the same lookup
  machinery, cache (now keyed on name and record type) and CNAME-chain following.
  `dns.connect` now resolves both A and AAAA for a name and tries every address --
  IPv6 first, IPv4 as the fallback -- so a host with only AAAA records, previously
  unreachable from Wantzel at all, can be connected to by name.
- `lib/fs.wz`: directory iteration is re-entrant. `fs.opendir`/`fs.next` used to share one
  read buffer and position for the whole process, so opening a subdirectory while its
  parent was still being read silently reset the parent's place in its own listing --
  fewer entries, no error. Each open directory now gets its own slot (a small table, up
  to 16 at once; a 17th `fs.opendir` fails with `fs.errno = 24`, `EMFILE`), so a recursive
  walk works. New: `fs.forget(fd)`, for a caller that opens a directory its own way (not
  through `fs.opendir`) and closes it its own way too -- call it before that close, or a
  reused fd number can inherit another directory's old read position.
- `lib/dns.wz` waits as long as the C library does: 5 s an attempt, 12 s a lookup (was 2 s
  and 5 s). A local caching resolver that has to ask upstream the slow way -- systemd-resolved
  while it re-probes its upstream server -- answers seconds later, and the old bounds turned
  such an answer into "no nameserver answered in time".
- `lib/http.wz` refuses (413, 431, 503) by half-closing the connection and draining what the
  client still sends, instead of closing it outright: closing a socket with unread input
  still in its receive buffer answers with a reset, so a client mid-upload could lose the
  status that told it why. A header block that never ends now answers 431, and one that
  never arrives in time answers 408, both of which used to be a silent close. `net.wz` gains
  `net.shutdown` (W-0000-0259).
- New module `lib/sha1.wz` (RFC 3174), moved out of `lib/websocket.wz`, which now includes
  it. A program that needs SHA-1 for something other than the WebSocket handshake no longer
  has to copy the routine out of a module that also pulls in `lib/http.wz` (W-0000-0243).
- `lib/websocket.wz` connections now live in `WS.MAXCONN` slots, not at their fd -- the same
  shape `lib/http.wz` already uses. `ws.take` used to refuse any fd of 256 or more outright;
  now it refuses only once 256 connections are already open, whatever the fd. Inside
  `app.wsframe`/`app.wsclose`, the base into `ws.in` comes from the new `ws.slot`, not from
  `fd` (W-0000-0258).
- `p256.sign` and the arithmetic it uses on the secret nonce and private key -- scalar
  multiplication and modular inversion -- are constant-time: no branch or table/array index
  keyed on a secret bit. Scalar multiplication is now a Montgomery ladder with constant-time
  conditional swaps; modular inversion is Fermat exponentiation with a constant-time select
  instead of the previous branchy binary GCD. `lib/tls.wz` signs every TLS server handshake
  with this routine, so its timing is now exposed to any network client, not just a local
  ACME operator -- measured (a quiet machine, best of several): signing went from about 4 ms
  to about 14 ms, the cost of removing that timing channel (W-0000-0266).
- `p256.sign`/`p256.genkey`'s k*G now uses a precomputed fixed-base comb table
  (`p256.mulbase`) instead of the general Montgomery ladder, while staying constant-time: the
  table lookup scans every entry and selects with a constant-time fold, never reads at a
  secret index, and the additions never take a secret-dependent shortcut (a fixed public
  blinding point keeps the running total away from the point at infinity for the whole
  multiply, so there is no secret-conditional case to branch on). Measured (a quiet machine,
  median of ten): signing dropped from about 14 ms back down to about 8.5 ms (W-0000-0260).

## 0.3.2 — 24 September 2026

**A patch release for servers that face the internet.** A program that includes `lib/http.wz`
now terminates TLS in its own event loop, obtains and renews its Let's Encrypt certificate
from that loop, resolves hostnames, and carries requests and replies of many megabytes over
thousands of connections at once — with no reverse proxy, no certbot, no second process.
The language is unchanged.

**What may need your attention** if your program compiles today:

- `lib/http.wz` includes `lib/autocert.wz`, and with it the TLS stack and `lib/dns.wz`. A
  server that never asks for HTTPS pays only in binary size. `http.osend` and `http.oend` are
  gone: the finished reply is `http.outbuf[http.rstart..http.rend)`.
- `tls.connect` and `tls.accept` switch the socket to non-blocking and keep a wall-clock
  deadline (`tls.deadline`, 30 s). A caller that read the socket directly afterwards has to
  expect `EAGAIN`.
- `ch.verify` no longer tries every root in the store when none is named as the issuer: a
  chain whose issuer is not in the store is refused at once.
- The reply of `mcp.handle` is at `view(mcp.obase, n)`; it is still in `mcp.buf` whenever it
  fits there.
- Every Windows executable imports `iphlpapi.dll`, for the nameservers.

**Library**

- `lib/http.wz` keeps connections in slots instead of at their fd: 4096 at once per worker
  (was 256, and any fd from 256 up was closed on sight), any fd up to 65536. Static memory
  drops from 192 MB to 82 MB: each connection owns 16 kB of input, a larger request borrows
  one of 64 shared 256 kB areas, and a reply waits in memory of its own only while the
  socket cannot take it. Largest request and reply are unchanged.
- `http.serve` raises the soft open-file limit to 65536 (at most the hard limit) on Linux.
- New deadlines close stalled connections: headers 10 s from the first byte (never
  extended), body 30 s plus 1 s per 16 kB, idle keep-alive 60 s, sending 30 s without
  progress. `http.timeouts(idle, header, body, send)` changes them.
- When every slot is busy, an idle connection is closed to make room; if there is none, the
  new connection gets `503` with `Retry-After: 1`. `http.maxconn(n)` sets a lower limit.
  Counters: `http.nopen`, `http.refused`, `http.evicted`, `http.timedout`, `http.queued`.
- Fixed: pipelined requests are answered in order. Bytes after the first request of a read
  were dropped, and the next request could overwrite a reply still being sent.
- New: `http.listen(port, workers)` and `http.poll(timeout)` for a program with its own
  loop, `http.addport(port)` for more listening ports, `http.lis` and `http.slis` for the
  listener a connection came in on. The finished reply is `http.outbuf[http.rstart..http.rend)`;
  `http.osend`/`http.oend` are gone. `http.accept`, `http.readable`, `http.flush`,
  `http.drop` and `http.open[fd]` still work.
- `lib/dns.wz`: hostnames to IPv4 addresses, over UDP to the nameservers in
  `/etc/resolv.conf` and TCP when an answer is truncated; CNAME chains, a TTL cache, and
  distinct failures (`DNS.NXDOMAIN`, `DNS.SERVFAIL`, `DNS.TIMEOUT`, ...). Blocking
  (`dns.resolve`, `dns.connect`, at most 5 s) or from an epoll loop (`dns.start`, `dns.poll`).
- `examples/host.wz`: a `host`-like lookup tool. `examples/wget.wz` takes a hostname in the
  URL, looks it up, and checks the certificate against it.

- New `lib/autocert.wz`: a server gets and renews its own Let's Encrypt certificate from
  inside its event loop — one HTTPS request per tick, the HTTP-01 answer from memory,
  verified chain, atomic store, backoff that survives a restart, and the new certificate
  handed to `tls.setcert` without a restart. `examples/autocert.wz` is a complete server.
- `ch.verify` builds the path by name only: the roots whose subject is the certificate's
  issuer are tried, and a chain whose issuer is no root in the store is refused at once. It
  used to fall back to trying the signature against every root, which cost seconds of CPU
  per handshake with a system bundle (28 s for one certificate nobody issued) -- in the
  caller's thread, which for a server is a way to be stalled by anyone who connects.
- `lib/tls.wz` serves many TLS connections from one event loop: `tls.open`, `tls.feed`,
  `tls.seal`, `tls.shut`, `tls.free` and `tls.state` drive a session per connection without
  touching the socket, so a slow client no longer holds up the others. Up to 4096 sessions.
- The server answers KeyUpdate, drops the compatibility change_cipher_spec, and fails only
  the session that sent malformed input, with an alert.
- `tls.setcert` takes a chain (DER certificates back to back, leaf first) and refuses a key
  that does not belong to the leaf, keeping the pair it had. It is safe while sessions are
  open.
- `tls.accept` runs on the same session code; its callers are unchanged.
- The blocking calls (`tls.connect`, `tls.accept`, `tls.read`, `tls.write`, `tls.close`)
  each end within `tls.deadline` milliseconds, 30 s by default, instead of retrying a
  stalled peer without a time limit. They put the socket in non-blocking mode.
- `examples/serve.wz` uses the new server, gives each connection a deadline, and picks up a
  new certificate from disk while running.

- MCP messages of many megabytes: a request up to `mcp.maxin` (64 MB), a tool result up to
  `tool.maxout` (64 MB) and a reply up to `mcp.maxout` (160 MB). A message larger than the
  static buffers moves into a mapping that is given back afterwards; static memory is
  unchanged. Past a limit the answer is a JSON-RPC error that names it (`data.limit`).
- Fixed: a reply larger than 4 MB was cut short or stopped the server, and a stdio line
  longer than 4 MB earned two errors. A tool result past its limit is now a JSON-RPC error
  (`-32603`), no longer a tool result with `isError`.
- The reply of `mcp.handle` is at `view(mcp.obase, n)` — in `mcp.buf` whenever it fits
  there, as before. A transport of its own calls `mcp.done` after sending.
- Fixed: `mcp.http` and `tool.rest` read a body larger than the HTTP input buffer (the
  `http.maxbody` region) from the wrong buffer. An MCP reply larger than the HTTP layer
  can send is a JSON-RPC error instead of a plain-text 500.

- `lib/http.wz` serves HTTPS itself, in the same loop: `http.https(host, email, store,
  staging)` gets and renews a Let's Encrypt certificate through `lib/autocert.wz`, and
  `http.httpsfiles(cert, key)` takes one from PEM files (reloadable while serving). The port
  given to `http.serve` then speaks TLS; `app.request` is unchanged (`http.istls`).
- In HTTPS mode a plain listener (port 80, `http.redirect`) answers the ACME challenge,
  redirects to `https://` once there is a certificate (`301`, `308` for other methods than
  GET and HEAD) and answers `503` before — never the application.
- The header deadline covers the TLS handshake; a refused TLS request lingers briefly so the
  client reads the `413`/`503`; counters `http.tlsrefused`, `http.tlsfailed`, `http.tlskept`.
- `lib/http.wz` now includes `lib/autocert.wz` (and with it the TLS stack and `lib/dns.wz`):
  every program on it is about 0.5 MB larger.
- `lib/autocert.wz` installs the whole chain instead of only the leaf, which browsers
  refused; resolves the authority through `lib/dns.wz` (`autocert.pin` still overrides);
  bounds its TLS calls with `tls.deadline`; reads PKCS #8 (`PRIVATE KEY`) keys too.
- `ws.take` refuses a TLS connection instead of writing to it in the clear.
- `examples/autocert.wz` is `http.https` plus options; `--pin` is no longer needed.

- Large requests: `http.maxbody(cap)` now reads each body past `INBUF` into a region of its
  own connection's, freed once answered, so several arrive at once (was: one region per
  worker, a second big body got `413`). `http.maxbodymem(total)` bounds them together
  (256 MB); past it, `503` with `Retry-After`. `http.bigowner`, `http.biglen` and
  `http.bigtotal` are gone; `http.bodyinbig` and `http.bigbase` work as before.
- Large replies: `http.maxreply(cap)` allows replies past `OUTBUF` (512 kB); the reply moves
  to a region that grows as needed and, in the clear, becomes the queued output itself. Past
  the limit, still a clean `500`.
- `Expect: 100-continue` is answered once a body is accepted; curl no longer waits a second
  before sending a body over 1 MB.
- An MCP reply over HTTP is limited by `http.maxreply`, no longer by 512 kB (`mcp.httproom`
  asks `http.replyroom`).

**Compiler**

- A Windows executable opens UDP sockets (`socket` with `SOCK_DGRAM`), a non-blocking
  `connect` reports `EINPROGRESS` instead of a refusal, and an open of `/etc/resolv.conf` is
  answered with the DNS servers Windows uses, from `GetNetworkParams` — so `lib/dns.wz`
  runs unchanged there. Every `.exe` now imports `iphlpapi.dll`.
- Fixed: the C bootstrap (`bin/wantzel0`) compiles `for` loops. It refused every one, so it
  could not build any program that includes `lib/http.wz`, `lib/sha256.wz` or another
  module with a `for`.
- `test.sh` no longer reports "identical output" when a compiler refused the source (it
  compared the previous source's files); both targets are checked, and a refusal is shown.

## 0.3.1 — 24 September 2026

**A patch release for Windows.** A Windows executable now starts a server that writes its
process id and checks another process, connects out over TCP, and sleeps as long as it is
asked. Nothing that compiles today changes meaning.

**Compiler**

- A Windows executable now translates `getpid`, `kill` and `connect`: `proc.self`,
  `proc.alive`, `proc.kill` and `net.connect` work there instead of stopping the program.
- `nanosleep` on Windows sleeps the time asked for; it slept 1 ms whatever it was given.

## 0.3.0 — 24 September 2026

**The standard library now lives on disk, beside the compiler.** It used to be embedded in
the binary; now `lib/` sits next to `bin/`, and `wantzel --version` says which library it
uses and whether it is there. A release archive keeps the two together. Copying only the
binary somewhere else is the one thing that no longer works.

**What can break code that compiles today:**

| if your source | then |
|---|---|
| includes `ui.wz` or `uicap.wz` | they are removed; nothing in the library used them |
| relies on a schema refusing an unknown JSON key | the key is now skipped and recorded instead |
| names a tool like a generated or library `tool.*` routine | it is reported at your line |

Also in this release: TLS certificates that Chromium accepts (DER lengths in their shortest
form), a WebSocket server, reporting instead of silent failures across `lib/`, tool names up
to 126 characters, clearer errors for a keyword used as a name, and `--debug`. The VS Code
extension and the two window examples are gone; `winmessage.wz` remains as the Win32 example.

**Library**

- **Fixed: `lib/der.wz` now writes every length in its shortest form**, as DER requires.
  `der.close` shrinks the header it opened, and `der.put`, `der.putbits` and `der.putstr` use
  `0x81` for lengths 128-255. The old fixed `0x82` form was accepted by OpenSSL and curl but
  rejected by BoringSSL, so Chromium-based browsers failed every certificate made by
  `csr.selfsign` with `ERR_SSL_PROTOCOL_ERROR`. New: `der.putlen`.
- **Removed: the VS Code extension (`editors/vscode/`) and the examples `winwindow.wz` and
  `x11window.wz`**, together with their tests and the two window recipes in `howto.md`.
  `winmessage.wz` stays as the Win32 example; `winproc` keeps its own test.
- **Removed: `lib/ui.wz` and `lib/uicap.wz`**, the component layer for native windows, and
  their tests. Nothing else used them.
- **`examples/mcpfiles.wz` and `examples/mcpserver.wz` now declare their tools in a
  `tools` block**, like `examples/mcptools.wz`, instead of registering each one by hand
  with `mcp.add`. Same tools, same behaviour; `mcpserver.wz`'s `count` is now
  `wordcount` because a `tools` block turns a tool's name directly into its handler
  `tool.<name>`, and `tool.count` is already generated by the compiler.
- **`lib/p384.wz`: `p384.sign` and `p384.genkey` no longer read past their nonce buffer.** It held
  32 bytes where a P-384 scalar needs 48, so the first real call stopped with an index out of
  range. The test now signs with a fresh key and verifies the result.
- **`lib/store.wz`, `lib/fs.wz`, `lib/proc.wz`: failures that returned a silent `false` now
  say why.** `store.apply`/`store.write` fill `store.err`/`store.det` on an out-of-range
  table or row and on a write that does not fit the buffer; `store.snapshot` fills them on
  every write, fsync or truncate that fails, matching the sibling branches that already did.
  `fs.stat` and `fs.next` gained `fs.err`/`fs.errno`, left empty for the common case (a
  missing path, an exhausted directory) and filled for a real failure, so the two no longer
  read the same. `proc.alive(pid)` now calls `io.fatal` for `pid <= 0` instead of answering
  `false`: 0 and a negative pid address a process group to `kill(2)`, not one process, so
  that was never a real answer to ask for.
- **`lib/tls.wz`, `lib/x509.wz`, `lib/p256.wz`, `lib/p384.wz`: malformed input now leaves a
  reason.** A CertificateVerify signature with impossible DER, an unloadable leaf key, or a
  hostname refused because more names existed than the parser kept, used to come back as a
  bare `false`. They now set `tls.err`/`tls.errmsg`, `x509.err`, or the new `p256.err` /
  `p384.err`. Whether a signature itself verifies stays a bare boolean, unchanged.
- **`lib/websocket.wz`: a WebSocket server (RFC 6455) that takes over a connection from
  `lib/http.wz`, on the SAME port.** Handshake (SHA-1 + base64 accept key), text/binary
  frames both ways, ping/pong, a close that carries a code, and masking of client frames
  checked and enforced. `app.request` sets `http.detach := true` and calls `ws.take` on
  an `Upgrade: websocket` request; `lib/http.wz` then lets go of the fd (closes nothing)
  instead of replying, and this module answers the 101 and reads frames from its own
  epoll set via `ws.poll`, called from the application's own loop. No new mandatory hook
  on `lib/http.wz` — a program that never sets `http.detach` is unchanged. See
  `docs/library.md`. Linux and `--target=windows`, through `lib/net.wz` only.
- **`lib/http.wz`: `app.request` can hand a connection off instead of replying.** Set
  `http.detach := true` before returning; `lib/http.wz` removes the fd from its own
  bookkeeping and epoll set without closing it. Added for `lib/websocket.wz`'s takeover,
  but the mechanism itself has no WebSocket in it — any module could use it the same way.
  A program that never sets it sees no change.
- **`lib/toolsmcp.wz`: an MCP server over stdio no longer has to define `app.request`.**
  `lib/tools.wz` is now split in two: `lib/toolsmcp.wz` holds `app.tools` and `app.call`
  and brings only `lib/mcp.wz`; `lib/tools.wz` includes it and adds `tool.rest` and
  `lib/http.wz`. A program that includes `lib/tools.wz` is unchanged. A stdio-only server
  with a `tools` block includes `lib/toolsmcp.wz` and drops its empty `app.request`.
- **`kv.bytes`/`kv.same` and `hash.put`/`hash.del`/`hash.putpad`/`hash.delpad` now stop
  the program with `io.fatal` on a range or key that violates the caller's contract**
  (a negative or out-of-bounds position, a key of the wrong length, a negative value),
  instead of returning the same plain `false` as an ordinary "these differ" or "the table
  is full". `json.wellformed` keeps its return value but adds `json.toolarge`, so a
  caller can tell "too large to answer" apart from "not valid JSON".
- **`lib/http.wz`: `http.param`/`http.form` returning `false` no longer hides a malformed
  value.** A key whose value has bad percent-encoding, or is too long for `http.pval`,
  used to answer exactly like a key that is absent. `http.lookup` now sets the new
  `http.paramerr` flag in that case, so a caller can tell "missing" from "malformed".
- **`lib/acme.wz`: `acme.find`/`acme.copy` now report why a lookup failed, through
  `acme.err`.** A genuine parse error (a body that is not JSON, a truncated object, a
  malformed member) used to answer exactly like an ordinary well-formed object that simply
  lacks the key; a value too long for the destination used to answer exactly like the key
  being absent. Both now set `acme.err` with a specific reason; a plain missing key stays
  silent, unchanged.
- **`lib/oauth.wz`: `oauth.take`, `oauth.readcookie` and `oauth.newsession` now report why
  through the new `oauth.err`.** `oauth.take`'s failure used to be thrown away at every
  call site; `oauth.readcookie` answered the same `false` for "no session cookie" and "a
  session cookie too large to be real"; `oauth.newsession` collapsed a full session table,
  a failed write and a full index into one `false`, so its caller always reported 503 "no
  room for more sessions" even when that was not the reason. `oauth.err` follows the same
  first-reason-wins convention as `acme.err` and `store.err`.

**Compiler**

- **Windows: each `epoll` set is its own set.** The runtime kept one interest table for
  the whole process, so every `epoll_create1` returned the same handle, an fd added to one
  set was reported by all of them, and `EPOLL_CTL_DEL` on one removed it from the others.
  Sets are now independent, as on Linux; a set can be watched inside another (ready when
  one of its fds is; a cycle is `ELOOP`, a set inside itself `EINVAL`), closing a set
  takes it out of every set, and there are at most 16 at once (one more is `EMFILE`).
- **A tool name that clashes with a generated or library `tool.*` name is now reported at
  its own line**, with a message naming the clash: `tool name "count" is reserved: the
  tools block generates tool.count; choose another name`. It used to point at a line of
  the compiler-generated `<tools>` text (`<tools>:19: name already used by a variable or
  constant`), or, for a name `lib/tools.wz`/`lib/toolsmcp.wz` declares, at a line deep
  inside that library. A duplicate tool name in the same block is reported the same way,
  naming the earlier line instead of `<tools>:N: duplicate declaration`.
- **The compiler finds its own `lib/` when started with a backslash path.** On Windows,
  where there is no `/proc/self/exe`, the search anchor always fell back to `argv[0]`, and
  that fallback only split on `/`. Started as `C:\tools\wantzel.exe`, that left no
  separator at all, so the search collapsed to a relative `lib/` and `include "io.wz"`
  failed with "looked in the library first: lib/io.wz" from any working directory without
  its own copy of the library. The fallback now splits on `\` as well as `/`.
- **A tool name may be up to 126 characters** (was 62). The name of a tool is also its
  name over MCP and REST, so a server that mirrors an existing service cannot shorten it.
- **A keyword used as a name is named.** `var: int;` in a record gives `var is a keyword
  and cannot name a record field`, on that line; the same for a schema field and a routine
  name. It used to surface lines later, for example as `missing end of the schema`.
- **`undeclared identifier` points at the include order** when an include further down the
  file might declare the name: a name is only visible after the include that declares it.
- **`--debug` writes a debug sidecar.** `wantzel prog.wz prog --debug` writes `prog.wzdbg`
  beside the executable: a line table (address to file and line, with the statement starts
  a debugger may stop at), every routine with its frame layout, parameters and locals with
  their `rbp` offsets and types, every global with its address and type, and the record
  layouts. Plain text, one record per line, for both targets. The executable itself is
  byte-identical with and without the flag. Format: `docs/design.md`.
- **Windows: a peer resetting or closing a socket no longer crashes the program.** The
  runtime's `recv` and `send` took `SOCKET_ERROR` -- a 32-bit -1 the register does not
  sign-extend -- for 4294967295 bytes transferred, so an HTTP server on `lib/http.wz` died
  in `http.parse` as soon as a browser or curl closed an idle keep-alive connection. They
  now recognise the error by its low half and ask `WSAGetLastError`: only a would-block
  is `EAGAIN`; a reset is `ECONNRESET`, a broken pipe `EPIPE`, as on Linux, so the server
  drops the connection. A failed `bind` or `listen` is reported the same way instead of
  being taken for success.
- **A keyword used as a name is reported as that.** `to: int;` in a `var` block, a schema
  field called `type`, a tool, a constant, a type, a routine or a parameter named after a
  keyword now gives `to is a keyword and cannot name a variable` on its own line, instead of
  `missing begin of the main program`, `missing end of the schema` or whatever the parser
  failed to find next. For a schema field the message adds the repair: rename the field and
  keep the JSON key with `kind "type"`.

**Library**

- **`lib/store.wz`: a layout version per table.** `store.layout(t, v)` declares it (0 when
  not called); it is written into the snapshot and into every log record. A store of an
  older layout opens only with a registered step: `store.upgrade(t, oldv, oldsize)` copies
  the old bytes and zeroes the rest (fields added at the end), `store.carry` moves byte
  ranges when fields move or disappear, and steps chain. Otherwise, and for a newer layout,
  `store.opendir` refuses and `store.err`/`store.det` name the table and both versions.
  `store.upgraded(t)` says which layout was converted. Snapshots are now written as
  `PHS2`; a `PHS1` snapshot, and a log from before versions, reads as layout 0. An older
  binary refuses a `PHS2` snapshot rather than misread it.

**Read this row first: the standard library is no longer inside the compiler binary.** It is
read from `lib/` beside the compiler's own executable. **Download the archive, not the bare
binary** — the archive contains `lib/`; a lone binary cannot resolve `include "io.wz"` and
now says so, naming the path it looked for.

**Compiler**

- **`--version` now says where the library is**, and whether it is actually there:
  `library /opt/wantzel/lib/` — or the same path followed by
  `NOT FOUND -- copy lib/ next to the compiler`. Since the standard library is read from
  disk, a compiler copied away from its `lib/` cannot resolve `include "io.wz"`, and that
  is the one thing about an installation you cannot otherwise look up.

**Compiler**

- **A line with several runtime checks stores its place once.** `a[i] := b[j] + c[k]` is
  three bounds checks and one `file.wz:line`, and each stored copy costs its text plus an
  eight-byte length and padding. Measured on the compiler itself: 1016 place strings, 662 of
  them distinct — 298817 bytes down to **287697**, 3.7%, with every message still naming its
  own line.

- **`winapi()` checks the argument count** for the imports the compiler carries itself:
  `winapi(): CreateFileA takes 7 arguments, not 2`. Win32 passes the first four arguments in
  registers, so a call with too few used to compile and then read a register nobody set —
  wrong behaviour rather than a crash. A named import (`winapi("user32.dll", ...)`) is left
  alone: its arity lives in a DLL on another machine, and refusing there would be guessing.

- A hex escape with no two digits now gives **one message instead of two**: the version with
  the example (`as in x41 or xff`) is what both paths report. Which of the two fired used to
  depend on whether the source happened to end first, so the help you got depended on where
  your file ended.

**Language**

- **A schema now ignores a key it does not declare, and records it.** `parse` skips the
  value and succeeds instead of returning `-1`; `json.ignoredn` counts the skipped keys and
  `b[json.ignored0..json.ignored1)` is the first. A caller may therefore send a superset of
  what a schema declares. It stays safe because the keys are recorded: a renamed *optional*
  field would otherwise be answered with the default in its place and nothing would say so.
  A renamed *required* field still fails, a declared field given a value it cannot hold
  still gives `-1`, and `json.badkey0..json.badkey1` now names that declared field. **If you
  relied on a schema refusing an undeclared key, check `json.ignoredn` after `parse`.**

- **A schema field can name its JSON key**: `rdxcap "rdX": int;`. Identifiers are
  case-insensitive, so `rdX` and `rdx` are one name in Wantzel and two on the wire — and a
  key like `content-type` is not an identifier at all. A string literal before the colon,
  which needs no new keyword.

- **`language.md` §7b documents three limits of a `tools` block.** An input field must be
  `text[N]`, not a view: the handler never receives the buffer a view points into. A view
  in the result is copied in literally, so escape it with `json.escslice`. Over REST only a
  schema mismatch gives 422; `tool.fail` gives 400, a result too large for the buffer 500.

**Conventions**

- **Keep the levels apart: a helper file carries the vocabulary.** Code reads like
  pseudocode because the words live in one file and the decisions in another — with the test
  for when a routine is mixing them, and when a wrapper is not worth having. See
  [`conventions.md`](conventions.md) §6.

- **An error names the fact first and the repair after a dash** — the shape the compiler's
  messages already mostly had, now written down so a new message does not invent a third
  form. See [`conventions.md`](conventions.md) §5.

- **`agent-permissions:` in the first 512 bytes of a file says how it is meant to be
  treated** — `read` (do not change), `none` (do not open), or absent for ordinary. It is a
  hint rather than a guard, like `.gitignore`, and an unrecognised value restricts nothing.
  See [`conventions.md`](conventions.md) §4.

**Library**

- **`lib/http.wz`: a request or reply larger than its buffer gets a clean HTTP error
  instead of a dropped connection.** A request bigger than `INBUF` (256 kB) used to fill
  the buffer and then reset with no status code, indistinguishable from a crash; it now
  answers `413 Payload Too Large`. A reply bigger than `OUTBUF` (512 kB) used to write past
  the buffer and trap the worker, taking down every other connection it was serving at that
  moment; it now answers `500` instead. `http.maxbody(cap)`, called once before
  `http.serve`, reserves one shared region with `mmap` for the body of whichever connection
  is currently reading past `INBUF` — one region, not one per connection, so it does not
  multiply `MAXCONN` static buffers by `cap`.
- **`lib/uicap.wz`: a component rendered as a list of draw calls instead of pixels.**
  `lib/ui.wz` declares its four drawing routines `forward` and a target supplies them;
  this supplies a target that records them. A program that includes it renders a
  component to text — one line per call, with its geometry, corner radius, colour and
  string — which compares with `diff`, runs without a display, and names what differs
  rather than showing that something does. `cap.begin`, `cap.dump`, and queries
  (`cap.find`, `cap.countop`, `cap.colat`) for checking a component without a window.
  Truncation is counted and printed, so a capture that overflowed cannot compare equal
  to one that did not.
- **`UI_SURFACE` was the wrong colour**: `0x25273C`, a blue-tinted slate, where the
  value beside it read `0x252526`. It is the panel background, so it affected every
  surface drawn at rest. Found by writing the tokens out in hex — every test compared
  against the symbol and so agreed with the typo.
- **`io.argn` and `io.argstr`: a command-line argument, as a number or copied into a
  buffer.** Five examples had written the same loop over `argch` by hand
  (`serve.wz`, `getcert.wz`, `tcpproxy.wz`, `x11window.wz`, `wget.wz`) — one of them
  said so in a comment, naming the threshold this crosses. `argc()` and `argch()`
  remain the builtins; this is the copy loop around them, in one place.
- **`examples/localhttps.wz`: HTTPS on loopback, with a certificate the program makes
  itself.** `csr.selfsign`, `tls.setcert` and `tls.accept` in about eighty lines — the
  "1. Localhost" case from `docs/howto.md`, working end to end rather than
  only described. No VPS and no authority: ACME cannot issue for `localhost`, so the
  certificate is signed by the program and a client has to be told to trust it, which the
  example and the test both show by using `curl --cacert`/`-k`.
- **`lib/ui.wz`: the start of a component layer, so that a program with a window does not
  begin by writing a button.** Immediate mode — `if ui.button(panel, "Save", x, y, w, h)
  then save;` every frame, with the `if` as the callback. No widget objects, nothing to
  construct and nothing to free: what persists between frames is a hover, an active and a
  focus id in fixed arrays. This first entry carries identity (an FNV-1a hash of parent and
  label, so two panels can each hold a *Close*), the press/cancel/focus machinery, `ui.label`
  and the button in its four states.

  **It draws through four routines declared `forward`** — `ui.rect`, `ui.rrect`, `ui.text`
  and `ui.textw` — which the program supplies for the target it is built for. So the
  component layer names no platform, and the half that *decides* anything is testable
  without opening a window.
- **`lib/tools.wz` tells the caller which fields it ignored.** A tool call carrying a key
  its input schema does not declare is answered rather than refused, and the reply says what
  was dropped: `_meta.ignoredFields` (`first` and `count`) in an MCP result, and the
  `X-Ignored-Field` and `X-Ignored-Count` headers in a REST reply. It goes there rather than
  in the body because `structuredContent` has to keep the shape the output schema declares,
  and a REST list tool's body is a bare array with nowhere to put a note. The key is
  reported as it stands in the request, with anything outside printable ASCII replaced by
  `?` so a caller cannot forge a response header.

- `lib/` is ordinary Wantzel source on disk and nowhere else. You can read it, step into it
  in a debugger, and change it: edit `lib/io.wz` beside the compiler and the next compile
  uses your version, with nothing to rebuild.

- **`lib/chacha20.wz` and `lib/poly1305.wz`**: the AEAD that TLS 1.3 uses, verified against
  the test vectors in RFC 8439 rather than against our own output.

- **`net.connect`: an outgoing TCP connection**, which the library did not have — `net.wz`
  could listen and accept but never call out.

- **`examples/tcpproxy.wz`: forward a port, in one static binary of about 20 kB.** The
  plumbing a TLS terminator needs — accept, connect, forward, event loop — without the
  encryption, which is the part that has to be right before a handshake is worth writing.

- **`examples/jsonget.wz`: one field out of a JSON document, for a shell script.**
  `jsonget a.b.2.id < reply.json`, and `--valid` to check a document parses. **1.04 ms per
  call** against 37.8 ms for the scripting one-liner it replaces: the cost of a one-liner is
  starting an interpreter, not the parsing, and it only shows up once the helper runs in a
  loop.

- **`examples/winmessage.wz` and `examples/winwindow.wz`: calling Win32 from Wantzel.** A
  message box (three lines, and proof that `winapi()` reaches a function the compiler has
  never heard of) and a window with a real `WndProc` handed over by `winproc`. Both build
  only for Windows, which `examples_compile.sh` now states rather than assumes.

- **`examples/x11window.wz`: a window on X11 with no library at all.** X11 is a binary
  protocol over a Unix socket, so a program that can open a socket can open a window — about
  two hundred lines, nothing linked, nothing installed.

- **`fs.map` and `fs.unmap`: one call for "map this file".** A stat, an open, an mmap and a
  close, which every caller used to write out again — including the close, which is the part
  that gets forgotten. A mapping keeps its own reference, so a caller who does not know that
  leaks a descriptor per file.

- **`json.pretty` lays a JSON document out over lines**, two spaces per level, one key per
  line, no trailing comma. It copies values rather than reparsing them, so a number stays
  exactly as it was written. Invalid input is refused instead of repaired. `examples/jsonpretty.wz`
  is the whole program around it: read, call, print.

- **TLS 1.3, client and server, in `lib/`.** `lib/tls.wz` speaks TLS 1.3 with
  ChaCha20-Poly1305 over X25519 (`lib/x25519.wz`, `lib/hkdf.wz`), and `tls.accept` serves it.
  Certificates: `lib/der.wz` and `lib/x509.wz` read them, `lib/csr.wz` writes a request,
  and `csr.selfsign` makes one for `localhost`.
- **`tls.verified` means the chain reaches a trusted root.** `lib/chain.wz` walks the chain
  against a trust store — the system bundle, or two built-in roots on a machine without
  one. Signatures: `lib/p256.wz` (ECDSA P-256, sign and verify), `lib/p384.wz` with
  `lib/sha384.wz`, and `lib/rsa.wz` (RSA-2048/4096, PKCS#1 v1.5 and PSS).
- **Fixed: `tls.connectb` sent an empty SNI extension**, so public servers refused the
  handshake with `unrecognized_name`.
- **ACME: `lib/acme.wz`, `lib/jws.wz` and `lib/certstore.wz`** request a certificate from
  an authority and keep it beside the binary, so a restart does not ask again and run into
  the authority's weekly limit.
- **`examples/serve.wz`** serves HTTP, HTTPS and the ACME challenge from one event loop;
  **`examples/getcert.wz`** fetches a certificate, **`examples/wget.wz`** fetches a URL.
  Which of the three situations you are in: `docs/howto.md`.
- **`p256.sign` is 2.3× faster** (9.2 ms → 4.0 ms): the modular inverse by binary GCD.
- **`lib/jsonschema.wz`: a JSON document checked against a JSON Schema**, naming the place
  that failed. Called `lib/schema.wz` for a day; renamed because a common name in `lib/`
  shadowed a program's own `schema.wz`.
- **`json.wellformed`**, and the schema check uses it: `{"a":}`, `{"a" 1}` and `{"a":1,}`
  were reported valid against `{"type":"object"}`.
- **Fixed: `json.pretty` accepted malformed input** (`{"a":}`, `[1,,2]`, a bare word) and
  printed something that looked formatted. It now refuses it.
- **`io.put64`**, the 64-bit writer beside `io.get64`.

**Language**

- **`local` keeps a name inside its file.** Put it in front of a top-level `var`, `const`,
  `procedure` or `function` and nothing outside that file can see it — two files can now
  both declare `hidden.n` without colliding. Public is still the default, so existing
  source is unchanged. The unit is the file: no module system, no separate compilation.
  `local` is now a keyword, so a routine or variable that was called exactly `local` needs
  a different name (a dotted name like `dpy.local` is unaffected).

- **A schema is declared like every other type: `type X = schema ... end;`**, where it used
  to be `schema X = record ... end;`. The old form is refused by name, so an older source
  gets the new spelling rather than a puzzle. Nothing else changes: the fields, the
  optional `?`, the descriptions and the generated `parse`/`write`/`jsonschema` are the
  same.

  The word `record` in the old form said nothing — a schema body could never be anything
  else, and a schema shares none of a record's machinery (it has eleven tables of its own
  and touches the record tables not at all). What it did do is offer two shapes for what
  looks like one thing, `type X = record` beside `schema X = record`, where the difference
  is not in the form but only in the meaning. That is the kind of distinction a generator
  gets wrong.

**Library**

- **An oversized input line no longer ends an MCP server silently.** `mcp.stdio` used to
  `return` when a single line filled the input buffer, so the client waited for a reply
  that never came — the worst failure this transport has, because nothing says anything is
  wrong. It now answers with a JSON-RPC parse error, drops the line and carries on.
- **`MCPBUF` is 4 MB, up from 1 MB.** A reply carries text as a JSON string, and escaping
  can multiply a byte by six (`\u00XX` for a control byte), so a 256 kB file answered
  verbatim needs 1.5 MB of room. Measured: 200 kB of control bytes becomes 1.2 MB of valid
  JSON, which the old buffer could not hold. It is a static array, so the cost is address
  space and not work.

**Compiler**

- **"`io.putc` is declared in `io.wz`; add: `include "io.wz";`" is no longer said about a
  name that is not there.** The compiler checked only that `lib/io.wz` EXISTS, never that it
  declares the name — so any misspelling whose prefix happens to be a library got a
  confident pointer to a file that does not have it, and often to an `include` that was
  already three lines up. It now reads that one file and asks; when the name is not in it,
  the message is the plain `undeclared identifier: io.putc`. The hint is unchanged where it
  was right.

- **A name that is one typo from a real one now says which.** `io.putc` answers
  `undeclared identifier: io.putc -- did you mean io.puts?`. Only one edit, and only within
  the module the prefix names: measured against the errors that writers really make, a name
  that was invented rather than mistyped has its nearest neighbour three to five edits away,
  and a suggestion at that distance is worse than none.

- **The compiler can be included by another program.** `src/compiler.wz` holds all of it
  and has no main program; `src/wantzel.wz` is the command-line program around it. A source
  file ending in `end.` is a *program*, and only one of those is allowed per compilation, so
  before this the compiler could only be used as a separate executable — which is where
  finding it on `PATH`, finding `lib/` beside it, and starting it at all came from.

  An error still exits, from 234 places in 45 mutually recursive routines; threading a
  return value through those is a rewrite of the parser's control flow, not a refactor. A
  host that must survive a failed compile calls `compile` in a `fork`: the child may exit,
  the parent reads its code. Note that the language has one global namespace, so a host
  prefixes its own names — the compiler owns short ones like `i`, `out` and `line`.
- **An include that cannot be opened names the library path it tried.** For a bare name
  like `io.wz` the compiler looks in `lib/` beside its own executable first, and when that
  file is absent the message now says so on a second line. It used to print only the name
  written on the line — which the reader can already see, and which sent them looking in
  their own directory for a file the compiler expected elsewhere. This is the case a
  download without `lib/` produces. An include containing a `/` is unchanged: one path was
  tried, one path is named.
- **`lib/` is found when the compiler is started through `PATH`.** The search path is
  anchored on the compiler's own executable, read from `/proc/self/exe` instead of taken
  from `argv[0]`. Started by its bare name — which is what an editor or a script does —
  `argv[0]` is `wantzel` with no directory in it, and the anchor used to collapse to a
  relative `lib/`: `include "io.wz"` then depended on the working directory and failed in a
  correct installation. Naming the compiler by an absolute path is no longer necessary.
- A constant array index outside the array's bounds is now a **compile error** rather than a
  runtime one: `a[9]` on an `array[0..3]` is refused while the line is being read. The
  runtime check stays and is still the only possible one for an `array of T` parameter,
  whose length only the caller knows. A literal and a named constant are both covered; a
  runtime variable is unchanged.
- The compiler no longer carries a copy of the standard library. One search path, `lib/`
  next to the executable; a bare name is looked for there and then beside the source, and a
  name containing `/` is only ever a path. Before, a third place could answer an include and
  nothing said which one had — so behaviour depended on the working directory.
- **The binary is 48% smaller**: 536561 → 280313 bytes.
- A runtime message names its file relative to the project, at most two directory segments
  deep (`src/win32/main.wz:412`). The same source therefore produces the same executable
  whether you name it relatively or absolutely, and no binary carries the directory layout of
  the machine that built it. Measured before the fix on a program with 1288 checks: 513024
  bytes against 581632, from identical source, with the build machine's home directory
  embedded 1288 times.

**Editor**

- The VS Code extension no longer ships snippets. It keeps highlighting, compile errors in
  the Problems panel, and build and run — and it stays at those three on purpose. The
  complete working programs live in `docs/writing-wantzel.md`, where a test compiles them on
  every run and anyone can find them, not only a VS Code user.

**Tests**

- The certificate and signature tests (`base64`, `jws`, `p256`, `sha384`, `selfsign`,
  `serve`) no longer call Python; `openssl`, `base64` and `xxd` are the independent side.
- `english_only.sh` counts distinct Dutch words per line, no longer lists `over`, and checks
  string literals in every `.wz` and `.sh` file; it found test output that was not English.
- `no_foreign_code.sh` accepts addresses at the reserved `example.com/.net/.org` domains and
  judges each address rather than the whole line.
- `examples/jsonpretty.wz`: the error routine is called `fail`.

---

## 0.2.1 — 15 September 2026

**Three keywords are gone: `program`, `repeat ... until`, `case`.** A source using them is
refused with a message naming the replacement.

| if your source has | write instead |
|---|---|
| `program name;` at the top | delete that line |
| `case x of ...` | an if-chain (`else` binds to the nearest unclosed `if`) |
| `repeat ... until done` | `while true do begin ... if done then break; end` |
| an output name ending in `.exe` | add `--target=windows`; the name alone no longer selects the target |

Forty-three keywords became thirty-nine.

**Language**

- The `program` header is gone; a file starts with its first declaration. `program` is an
  ordinary name again.
- `repeat ... until` is gone; write `while true do begin ... if done then break; end`.
- `case` is gone; write an if-chain instead.
- `\xHH` is a byte escape in a `char` or `str` literal, with exactly two hex digits
  (`"\x41BC"` is three characters).
- The target comes from `--target=` only; a `.exe` name with no `--target` is refused
  rather than quietly built for Linux.
- A dotted name part may start with a digit (`Reading.level.1`); only the first character
  of a whole identifier must be a letter or `_`.

**Compiler**

- Naming a DLL function the compiler already imports reuses its import rather than adding
  a second one.
- The fixed part of a runtime message is stored once instead of once per check: the
  compiler itself went from 554,041 to 534,169 bytes, GUI programs 9-10% smaller.
- Imports from two DLLs, interleaved, now get the right IAT slot (a bug could jump to
  address zero).
- `undeclared identifier` names the identifier even when it belongs to no known library.
- `winproc(name)` gives a Windows API callback the compiler can call: an adapter that
  moves arguments from the Windows convention (`rcx, rdx, r8, r9`) to this language's
  (`rdi, rsi, rdx, rcx`), adds the 32-byte shadow space, and preserves `rdi`/`rsi`/`rbx`.
  Not `addr()` on a routine — this language has no function pointers. Windows targets only.
- `winapi()` takes a DLL and a function by name: `winapi("user32.dll", "MessageBoxA", 0,
  text, title, 0)` compiles and resolves at link time, whether or not the compiler has
  ever heard of the function. An empty name, or a DLL name without `.dll`, is refused at
  compile time.
- `winapi()` refuses an import slot that does not exist, at compile time (a literal slot
  only; a non-literal slot still cannot be checked).
- `schar()` on a `str` that was never assigned refuses (`runtime error: string index out
  of range`) instead of segfaulting. `slen()` on the same still answers `0`.
- A generated `<Schema>.parse` refuses an unknown key instead of silently filling in the
  default (`json.badkey0`/`json.badkey1` name it). Declare optional protocol members as
  `json?` if you need to accept a superset.
- A missing `include` names the library that declares the identifier, when one does.
- A name colliding only by capitalisation (`STORE.SET` vs `store.set`) says so explicitly.
- A `str` where `array of char` is expected gets its own message: only a string *literal*
  converts; use `io.push` into a buffer and slice it.
- An undefined tool handler is reported at the writer's own `tools` entry, not at a
  generated line nobody can open.
- The VS Code extension's Run menu finds the compiler by walking up from the file, not
  only at the workspace root.

**Library**

- `lib/proc.wz` can start another program: `proc.arg0`, `proc.arg`, `proc.exec` wrap
  `execve`. The environment is empty by default, for repeatable tests.
- `mcp.name`/`mcp.version` default to `wantzel-mcp`/`0` instead of crashing an application
  that never set them.
- `store` refuses a log record that does not fit its declared size instead of dropping it
  silently; `store.opendir` then returns `false` with `store.err`/`store.det` naming the
  table and both sizes.
- `store.apply` is now a function returning `bool` (was a procedure).
- `store.close` is valid after a failed `store.opendir`.
- `kv.isobject`, `kv.count`, `kv.match` no longer move the cursor `kv.vat`/`kv.vend`.
- New `kv.text(b, dst, at)`: decoded text of the value the cursor stands on (`-1` if not a
  JSON string or it does not fit).
- `mcp` and `oauth` declare the protocol members they receive (`capabilities`,
  `clientInfo`, `_meta`, RFC 7591 fields) — an undeclared member used to make the stricter
  parser refuse a genuine handshake.
- The OpenAPI tags are English (`read`/`write`, were Dutch).
- A request header name is case-insensitive on both sides (`http.header("Accept")` used to
  need exact case).

**Documentation**

- `docs/syntax.md`, `docs/flags.md` rewritten as standalone references, checked against
  the compiler by script.
- `docs/design.md`, `docs/howto.md`, `docs/design.md` added or restructured (later folded
  into `design.md`/`howto.md`/`library.md`; see the top of this changelog for the current
  shape).
- `docs/language.md` documents `winproc` and the DLL import model.
- `docs/writing-wantzel.md` gains argument order for the most-used routines, failure
  return values, the buffer-and-length pattern, and two complete example programs.

**Tests**

- `no_python.sh` refuses a file that IS Python, not only one that mentions it.
- The Windows checks that need no emulator (PE header, `.exe` byte comparison) run in
  every `--toolchain` run instead of only under Wine.
- The VS Code extension's problem matcher, build task and nine snippets are tested on
  every `--toolchain` run.
- `tests/bench/startup.sh` measures binary startup time with the loop written in Wantzel,
  not shell.
- `lib/openapi.wz` compiles standalone and has its own test.
- `english_only.sh` also checks string literals that ship.
- `--windows` no longer runs unconditionally; a surviving Wine process now fails the test.

---

## 0.2.0 — 15 September 2026

One language change, and it breaks existing sources: `{ }` is no longer a comment.

**Language**

- The `{ }` block comment is gone; `//` is the only comment form. A `{` outside a string is
  now refused; write a multi-line comment as several `//` lines.

**Compiler**

- Name lookup uses a hash index instead of a linear walk: 16,384 globals, 1,296 ms → 16 ms,
  growth now linear.
- Keyword recognition dispatches on the first character first: the compiler compiling
  itself, 12.8 ms → 10.3 ms (~590,000 lines/s).
- The compile-speed floor in `tests/bench/` is raised to 400,000 lines/s, and a new bench
  guards the shape of the growth, not only the speed.

---

## 0.1.2 — 14 September 2026

One theme: a failure that could still pass quietly no longer can.

**Language**

- `net.watch` and `net.nonblock` are now functions, not procedures — a call that ignored
  the result no longer compiles.
- `kv.match` answers differently for a stored list: a filter list now means containment.

**Compiler**

- A generated `<Schema>.write` refuses a buffer it does not fit in, instead of writing
  past the end of it.
- A required schema field given as JSON `null` is rejected.
- A source that fills the data segment gets a compile error, not a crash.
- The capacity limits are four times larger.

**Library**

- `io.now` and `io.realtime` stop the program when the clock cannot be read.
- `net.watch` and `net.nonblock` return a `bool` instead of the raw syscall result.
- `kv.match` does containment when the stored value is a list.
- `json.putraw`, `json.putstr`, `json.escslice`, `io.push`, `io.pushnum`, `json.putreal` no
  longer write past the end of their buffer.
- A negative position travels through the appenders unchanged instead of being treated as 0.
- New: `json.putb(dst, at, c)` — writes one byte of JSON structure.
- The standard library travels inside the compiler, so a downloaded binary resolves
  `include "io.wz"` without `lib/` beside it.

**Tooling**

- The Windows tests sit behind `./wztest --windows`, which halves an ordinary run.
- `test-win.sh` no longer fails on its own cleanup.
- `./build.sh` installs every file by renaming it into place.
- A `.wz` test runs in its own temporary directory.

---

## 0.1.0 — 13 September 2026

First public release.

**Compiler**

- An unresolved forward declaration names the routine, and every one is reported.

**Library**

- The session cookie is called `session`.
- The login, failure and logout pages are in English.

---

## How to add an entry

One bullet, one or two lines: what changed, and what it means for someone using it. The
reasoning belongs in the ticket, not here — a changelog is scanned by someone deciding
whether to act, not read as justification. Put it under Language, Compiler or Library, in
the same commit as the change.
