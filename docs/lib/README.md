# The standard library

`lib/` is included directly by name — `include "io.wz";` finds it without a path, because
the compiler looks in `lib/` beside its own executable before it looks beside your source
(see [`../flags.md`](../flags.md)). These are ordinary Wantzel files on disk: you can read
them, step into them, and change them. One page per module: what it is for, every routine it
exports with its signature and what it returns, and — the part a signature alone does not
show — **what happens when a call fails**. `-1`, `false` and `0` do not mean the same thing
from one routine to the next; each page says which one a given routine uses and why.

| | |
|---|---|
| [`io.md`](io.md) | output, decimal numbers, little-endian byte access, the two clocks |
| [`fs.md`](fs.md) | directories, file metadata, byte search — read-only |
| [`json.md`](json.md) | JSON scanning and writing primitives, underneath the generated `schema` parsers |
| [`http.md`](http.md) | a non-blocking HTTP/1.1 server on epoll |
| [`time.md`](time.md) | calendar time without a time zone: ISO 8601 in and out, a moment as seconds since the epoch |
| [`math.md`](math.md) | real arithmetic beyond the operators: `exp`, `log`, `pow`, trigonometry, fixed-decimal text |

This covers the six modules most programs touch directly. The rest of `lib/` —
`oauth`, `store`, `kv`, `mcp`, `openapi`, `protobuf`, `sha256`, `proc`, `hash`, `net`,
`base64`, `router`, `log`, `uuid`, `mcphttp`, `rand`, `hmac`, `tools` — is not yet
documented here; for those, the routine comments in `lib/*.wz` are the reference, and
[`../writing-wantzel.md`](../writing-wantzel.md) already records several of their sharper
pitfalls (`store.*`, `kv.*`, `oauth.*`, `sha256.hex`).

Every code example on these pages compiles against the current `wantzel` — see
[`../testing.md`](../testing.md) for how that is checked.
