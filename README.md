# Wantzel — a self-hosting compiler and an MCP server with no dependencies

**A compiler built for code that AI writes: strict, dependency-free and extremely
fast.** Wantzel is a small, strictly typed, procedural language. The compiler `wantzel`
is written in Wantzel itself, compiles itself, and produces static x86-64 executables: no
assembler, no linker, no C library, no external tool of any kind. It targets **Linux and
Windows equally** — ELF binaries that talk to the kernel directly through syscalls, or
64-bit Windows PE32+ that talk to `kernel32`, `ws2_32` and `advapi32` — and either host
builds either target, because the compiler is the whole toolchain. See §12 of
[docs/language.md](docs/language.md).

You need a C compiler once, to translate `bootstrap/boot.c`. After that, never again.

**Why the name.** Pierre Wantzel proved in 1837 what *cannot* be done — trisecting an
angle with compass and straightedge, doubling a cube. People had tried for centuries; he
showed it was impossible. That is what a compiler should do: say what cannot work, before
you find out the hard way. A proof that something is impossible is liberating, because you
stop looking.

That matters more now that an AI often writes the code. An AI that does not know what is
impossible keeps searching — it writes something plausible, gets a vague error, builds a
workaround, and sometimes produces something that runs until one day in production it does
not. What it needs instead is a fast, hard answer at compile time with a line number. So
Wantzel is deliberately small: procedural, strictly typed, one way per concept, no heap,
no pointers, no generics, no overloading. Fewer ways to express a thing means fewer ways
to get it wrong, and predictability is exactly what a generator needs.

The same idea explains the two unusual keywords. Exposing one function to the outside world
normally takes a stack: a schema file, a validation layer that reads it, a parser, a
serialiser, a router, a framework to hold them together. Every one of those layers is
configured rather than compiled, so most of what can go wrong goes wrong while it runs —
a field that arrives in the wrong shape, a route that does not match, a validator that was
never reached.

In Wantzel a `schema` declaration *is* the parser: the compiler generates it, along with the
writer and the JSON Schema. A `tools` block generates the MCP tool table, the argument
parsing, the dispatch, the REST route and the OpenAPI document from that one declaration.
There is no layer left to misconfigure and nothing to keep in sync, because there is nothing
beside the declaration. A field that is not in the schema is not a validation error at run
time; it is a program that does not compile.

> **Early days.** Anything may change before 1.0 — the language, the library, the
> command-line interface.

```bash
./build.sh     # bootstrap + fixed-point check
./test.sh      # the toolchain checks (Linux)
./test-win.sh  # the same checks against the Windows output
```

**Or download a binary.** Each release carries a Linux x86-64 binary and a Windows
x86-64 `.exe`, built from the tagged commit. The Linux one is statically linked, so
there is nothing to install.

The Windows binary is built on Linux and exercised through Wine, including a round trip
where `wantzel.exe` compiles a program back to a Linux ELF that must be byte-identical to
the one the native compiler produces. It has not been run on real Windows hardware, so if
you do, a report either way is welcome.

On Windows, downloading is the way in: there is no build script for it, and the two
commands in `build.sh` assume a POSIX shell. If you would rather build there, WSL or any
Unix shell will do it, and the result runs natively either way — the compiler emits both
targets from either host.

You do not have to take our word for which source those bytes came from. The build is
bit-for-bit reproducible — no timestamps, no paths, no dependency versions leak into the
output — so you can check it yourself:

```bash
./bin/wantzel --version          # which release is this binary?
git checkout v0.1.0
./build.sh
sha256sum bin/wantzel            # compare with SHA256SUMS from the release
```

Matching hashes prove the binary is what this source produces. That is a stronger
guarantee than a signature, because it rests on a check anyone can repeat rather than on
a key you have to trust. `tests/toolchain/release_assets.sh` holds it up from our side:
it fails if the two compilers disagree about the version, if either target stops being
reproducible, or if `bin/wantzel` is not what `src/wantzel.wz` produces.

**One pass.** The compiler reads the source once and emits machine code
as it goes — no AST, no intermediate representation, no optimiser pass, no link step.
Forward jumps are backpatched in place. It compiles itself in a few hundredths of a
second, and a benchmark with a hard floor (`./wztest --bench`) keeps it that way, so a
regression shows up as a failing test rather than as a slow afternoon a year later.

The loop between writing a line and knowing whether it is right is the most valuable
thing a language can give you. At this speed compiling stops being a step you wait for.

There is no daemon, no incremental build state, no lock file and no warm cache — just a
process that reads source and writes a binary — so the compiler is cheap to *start*, not
only fast once warm. That matters when the same loop runs many times over, and because
there are no dependencies, parallel work merges without reconciling environments. See
[docs/design.md](docs/design.md).

**Two targets, and either host can build either one.** The compiler emits Linux ELF and
64-bit Windows PE32+ from the same source, with no cross-toolchain to install: there is
nothing to install, because the compiler is the whole toolchain.

```bash
./bin/wantzel examples/hello.wz hello       # Linux ELF
./bin/wantzel examples/hello.wz hello.exe   # Windows PE32+ — from Linux
./bin/wantzel examples/hello.wz app --target=windows   # PE, despite the name
```

The compiler itself is one of those programs, so `wantzel.exe` is a Wantzel compiler that
runs on Windows and emits both targets in turn — including Linux ELF, from Windows. That
round trip is tested rather than assumed: `test-win.sh` builds `wantzel.exe`, has it
compile a program to an ELF, and checks that ELF is byte-identical to the one the native
Linux compiler produces from the same source, and that it runs.

Wine is only how that test runs a Windows binary on a Linux machine; it is not needed to
build one, and not needed to use the output on real Windows.

On top of the language sit a network layer, a JSON layer and an **MCP server** whose
protocol parsers are generated by the compiler from `schema` declarations.

```bash
./bin/wantzel examples/mcpfiles.wz mcpfiles
./mcpfiles /path/to/project          # MCP over stdin/stdout
./mcpfiles /path/to/project 8080     # the same server over HTTP
```

To connect it to Claude Desktop (from WSL, with Claude Desktop on Windows):

```bash
./bootstrap/tools/install-claude-desktop.sh /path/to/project
```

The script builds the server, checks that it answers an `initialize` correctly, backs up
your configuration and adds one `mcpServers` entry that starts the binary through
`wsl.exe`. Restart Claude Desktop and ask it something like *"search for epoll in my
files"*; to remove it, delete that one key.

It goes over stdio rather than HTTP on localhost because Claude Desktop cannot reach a
local HTTP server: a custom connector has to be an `https://` URL, and
`claude_desktop_config.json` accepts only stdio servers. The HTTP transport itself works
fine — the official MCP Python SDK connects to it unchanged. If you want one long-running
service instead, `examples/mcpbridge.wz` is a 23 kB stdio program that forwards every
message to a running HTTP server over one keep-alive connection and reconnects when that
server restarts; `install-claude-desktop.sh --service /path/to/project 8099` sets that up
as a systemd user service.

## Measured

Measured once on a single machine (8 cores, 12-09-2026) with a load generator itself
written in Wantzel, against servers with identical JSON-RPC semantics. That comparison is
not maintained; the measurement that *is* watched continuously is compile speed
(`tests/bench/`, with a hard lower bound).

**MCP `tools/call`, 32 connections:**

| | req/s | latency, 1 connection | |
|---|---|---|---|
| Wantzel | **260,162** | 0.11 ms | 4 worker processes, event loop, zero allocations |
| Go | 189,349 | 0.14 ms | `net/http` + `encoding/json` into structs |
| Python | 6,401 | 0.43 ms | FastAPI + pydantic + uvicorn |

So roughly 1.4× Go and 40× the FastAPI/pydantic stack, at a third of Go's latency.

One caveat about the Python figure: uvicorn with `--workers 4` got no further than 716
req/s at 44 ms latency on this machine — the 40 ms delayed-ACK pattern. With a single
worker the same code does 6,401 req/s. That last number is the fair one; the multi-worker
mode is evidently broken here and that is not Python's fault.

**Plain HTTP server, 128 connections:** Wantzel 408,076 req/s against Go `net/http`
234,432 req/s.

**Computation** (131 MB byte scan): Wantzel 0.08 s, Go 0.06 s, C `-O2` 0.01 s — the last
because GCC auto-vectorises the loop. With the built-in SIMD primitive `scan`, Wantzel
does 2.6 GB in 0.10 s, against `memchr` at 0.07 s and Go's `bytes.IndexByte` at 0.09 s.

Hello world is 1,095 bytes; the MCP server 65 kB, static.

## The demo: a file explorer as an MCP server

[`examples/mcpfiles.wz`](examples/mcpfiles.wz) gives a model read access to one directory,
through four tools:

| tool | |
|---|---|
| `list_dir(path?)` | the contents of a directory |
| `read_file(path, offset?, limit?)` | read a file |
| `file_info(path)` | kind, size, modification time |
| `search(query, path?, max?)` | literal search through the whole tree, with file and line number |

Read-only and sandboxed: every path is resolved inside the given root, and anything
starting with `/` or containing `..` is refused — there are tests for that.

`search` uses the SIMD scan to find the first byte of the pattern, so it walks a tree at
the speed of `grep`:

```
/usr/include, 29 MB across 2,577 files, a term that occurs nowhere:
  mcpfiles   10-14 ms   (process start + MCP handshake + the whole tree)
  grep -rl   10-12 ms
```

## Further reading

- [docs/language.md](docs/language.md) — **what the language is.** Opens with a tour, then
  the binding specification: types, routines, statements, `schema`, `tools`, the runtime
  checks, memory without a heap, the limits, and both targets. If the compiler disagrees
  with this document, that is a bug in one of the two.
- [docs/design.md](docs/design.md) — the long form of the introduction above: the three
  problems this language answers (dependencies, stacks that grew, feedback at run time
  instead of compile time), what it does about each, and where the idea does not hold
- [docs/changelog.md](docs/changelog.md) — what changed, split by whether it touches the
  language, the compiler or the library

## The library

| | |
|---|---|
| `lib/io.wz` | writing, numbers, byte packing, monotonic clock |
| `lib/net.wz` | sockets, `epoll`, `SO_REUSEPORT`, non-blocking accept |
| `lib/http.wz` | HTTP/1.1 server: event loop, keep-alive, zero-copy responses |
| `lib/json.wz` | scanning, decoding escapes, writing JSON strings |
| `lib/mcp.wz` | JSON-RPC 2.0 and MCP, with stdio and HTTP transport |
| `lib/fs.wz` | directories, file info, reading, and searching with SIMD |
| `lib/tools.wz` | MCP and REST transport for a `tools` block |

The HTTP server runs one event loop per process and spreads connections across cores with
`SO_REUSEPORT`: no threads, no locks, no shared memory. Each connection has a fixed place
in two static buffers, indexed by descriptor. Responses are written before the body, so
header and body leave in a single `write`.

An application fills the holes the library leaves open — `app.request`, `app.tools` and
`app.call` are `forward` declarations that the compiler links up. That is how you get
callbacks without function pointers.

## How the compiler works

One pass, with no intermediate tree: the recursive-descent parser type-checks and emits
machine code as it reads. Values travel through `rax`, locals are `rbp`-relative, and an
array element is loaded with a single SIB instruction. A small rollback trick lets
constant and scalar operands land directly in the instruction (`add rax,[b]` instead of
push/pop).

`include` and `schema` share one mechanism: for a schema, the compiler generates Wantzel
source into the source buffer and compiles that as though it were an included file — error
messages then point at `<Name>`.

The output is a single RWX `PT_LOAD` segment at `0x400000`: ELF header, three hand-written
runtime routines (trap, arguments, SSE2 scan), the compiled code, the text segments, and
bss behind them.

## Files

| | |
|---|---|
| `bootstrap/boot.c` | the bootstrap compiler in C — the only file that needs `cc` |
| `src/wantzel.wz` | the same compiler in Wantzel; line for line the counterpart of `bootstrap/boot.c` |
| `build.sh` | bootstraps and verifies the fixed point |
| `wztest` | the suite: `tests/{lang,compiler,lib,limits}`, plus `tests/toolchain/` with `--toolchain` and `tests/bench/` with `--bench` |
| `test.sh` | the toolchain checks (fixed point, wantzel0 = wantzel, standalone ELF) |
| `test-win.sh` | the same checks against the Windows output (runs the `.exe` under Wine) |
| `bootstrap/tools/runexe.sh` | runs an `.exe` on a Linux machine, through Wine |
| `docs/language.md` | the binding specification; §12 covers both targets |
| `lib/` | io, net, http, json, mcp |
| `examples/` | `hello.wz`, `cat.wz`, `primes.wz`, `httpd.wz`, `mcpserver.wz`, `mcpfiles.wz`, `mcpbridge.wz` |
| `docs/testing.md` | how the suite is run and how a test is added |
| `docs/writing-wantzel.md` | the pitfalls and idioms of writing Wantzel |

`bootstrap/boot.c` and `src/wantzel.wz` must keep producing the same output, for both ELF
and PE; `test.sh` and `test-win.sh` compile every example with both and compare the bytes.
A change to the language therefore always belongs in both files.

## The language and its limits

The full description of the language is in [docs/language.md](docs/language.md) (types
including `real` and `record`, slices and `view`, `case`/`for`, `schema` v2, the `tools`
block). The memory model (arrays, indices, slices, `view`, `mmap`) is in
§10b of [docs/language.md](docs/language.md). The measured limits of compiler and runtime — how many
schema fields, how many tools, how deeply nested — are pinned by `tests/limits/`, with the
table in [tests/limits/README.md](tests/limits/README.md).

## Status and licence

Wantzel is before 1.0. The language is frozen in the sense that it does not change
casually — [docs/language.md](docs/language.md) is binding, and the compiler is checked
against it — but nothing here carries a compatibility promise yet. Anything may still
change.

Wantzel is released under the MIT licence; see [LICENSE](LICENSE). Parts of the
documentation in `docs/` are still in Dutch and are being translated.
