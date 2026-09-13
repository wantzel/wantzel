# Wantzel

**A compiler for AI-written code: strict, dependency-free and extremely fast.**

Wantzel is a small, strictly typed, procedural language whose compiler is written in
itself. It produces static x86-64 executables for Linux and Windows — no assembler, no
linker, no C library, no runtime to install. The compiler is one file and carries its own
standard library, so the download is the whole toolchain.

> **Early days.** Anything may change before 1.0 — the language, the library, the
> command-line interface.

## Start here

Download a binary from [Releases](https://github.com/wantzel/wantzel/releases), or build
from source with a C compiler you need exactly once:

```bash
git clone https://github.com/wantzel/wantzel && cd wantzel
./build.sh                      # bootstrap, then the compiler builds itself
```

Then write a program and run it:

```pascal
program hello;
include "io.wz";
begin
  io.puts(STDOUT, "hello, world\n");
end.
```

```bash
./bin/wantzel hello.wz hello && ./hello
./bin/wantzel hello.wz hello.exe          # a Windows binary, from Linux
```

That second line cross-compiles, and there is nothing to install for it: the target
follows from the output name, one compiler emits both, and a Windows build of that
compiler does the same in reverse.

## What it can do

- **One binary, no dependencies.** Nothing to install, nothing to pin, nothing to
  reconcile when two branches merge. The standard library lives in this repository and
  ships inside the compiler.
- **An MCP server or a REST API from one declaration.** A `schema` block *is* the parser:
  the compiler generates it, along with the writer and the JSON Schema. A `tools` block
  generates the MCP tool table, the argument parsing, the dispatch, the REST route and the
  OpenAPI document. There is no layer left to misconfigure — a field that is not in the
  schema is not a run-time validation error, it is a program that does not compile.
- **Errors that are the whole answer.** One line on stderr, always the same shape, with
  the file and line in it: `wantzel: file.wz:12: type error in assignment: expected int,
  found bool`. No warnings, no grey zone, no "compiles with remarks".
- **Both targets, either host.** ELF talking to the kernel through syscalls, or 64-bit
  Windows PE32+ talking to `kernel32`, `ws2_32` and `advapi32`.

See [`examples/`](examples/) for a file-explorer MCP server, an HTTP server, and the
smaller programs.

## Why it is built this way

A growing number of programmers rarely type their own code and read only some of it. When
you did not write it, you cannot tell by eye whether a conversion is safe or whether an
index can run past the end — and plausible code is exactly what a generator is good at
producing. So the compiler has to hold what you used to hold: what it refuses, you do not
have to check.

That is also why it is small. Procedural, strictly typed, one way per concept, no heap, no
pointers, no generics, no overloading. Fewer ways to express a thing means fewer ways to
get it wrong, and predictability is what a generator needs.

**The name.** Pierre Wantzel proved in 1837 what *cannot* be done — trisecting an angle
with compass and straightedge, doubling a cube. People had tried for centuries; he showed
it was impossible. That is what a compiler should do: say what cannot work, before you
find out the hard way.

[docs/design.md](docs/design.md) has the long form.

## The demo: a file explorer as an MCP server

[`examples/mcpfiles.wz`](examples/mcpfiles.wz) gives a model read access to one directory
through four tools — `list_dir`, `read_file`, `file_info` and `search` — all generated
from one `tools` declaration. It is read-only and sandboxed: every path is resolved inside
the given root, and anything starting with `/` or containing `..` is refused.

```bash
./bin/wantzel examples/mcpfiles.wz mcpfiles
./mcpfiles /path/to/project          # MCP over stdin/stdout
./mcpfiles /path/to/project 8080     # the same server over HTTP
```

## Further reading

- [docs/language.md](docs/language.md) — the binding specification, opening with a tour
- [docs/design.md](docs/design.md) — why the language is the way it is
- [docs/writing-wantzel.md](docs/writing-wantzel.md) — the pitfalls, and how to get from
  an error message to its cause
- [docs/changelog.md](docs/changelog.md) — what changed

## The library

| | |
|---|---|
| `lib/io.wz` | writing, numbers, byte packing, the clock |
| `lib/net.wz` | sockets and `epoll` |
| `lib/http.wz` | an HTTP/1.1 server with an event loop and keep-alive |
| `lib/json.wz` | scanning, escapes, writing JSON |
| `lib/mcp.wz` | JSON-RPC 2.0 and MCP, over stdio or HTTP |
| `lib/fs.wz` | directories, file info, and searching with SIMD |
| `lib/tools.wz` | MCP and REST transport for a `tools` block |

An application fills the holes the library leaves open: `app.request`, `app.tools` and
`app.call` are `forward` declarations the compiler links up. That is how you get callbacks
without function pointers.

## Files

| | |
|---|---|
| `src/wantzel.wz` | the compiler, in Wantzel |
| `bootstrap/boot.c` | the same compiler in C — the only file that needs `cc`, and only once |
| `lib/` | the standard library: io, net, http, json, mcp |
| `examples/` | small programs, an HTTP server, and the MCP demo |
| `docs/` | the specification, the design, how to test, and the pitfalls |
| `build.sh`, `wztest` | build and test |

`bootstrap/boot.c` and `src/wantzel.wz` are counterparts and must produce identical
output; the suite compiles every example with both and compares the bytes. A change to
the language belongs in both files.

## Limits

How many schema fields, how many tools, how deeply includes may nest: every limit is
proved by a test with a case that just fits and one that just does not. The table is in
[tests/limits/README.md](tests/limits/README.md).

## Status and licence

Before 1.0. The language does not change casually — the specification is binding and the
compiler is checked against it — but nothing here carries a compatibility promise yet.

MIT; see [LICENSE](LICENSE). Contributions are welcome: [CONTRIBUTING.md](CONTRIBUTING.md)
says what is useful and how to report a bug.
