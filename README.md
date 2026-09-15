# Wantzel

**A compiler for AI-written code: strict, dependency-free and extremely fast.**

Wantzel is a small, strictly typed, procedural language whose compiler is written in
itself. It produces static x86-64 executables for Linux and Windows — no assembler, no
linker, no C library, no runtime to install. The compiler is one file and carries its own
standard library, so the download is the whole toolchain.

> **Early days.** Anything may change before 1.0 — the language, the library, the
> command-line interface.

[**wantzel.com**](https://wantzel.com) — what the language is for, and why it is built this
way.

## Start here

**Download the compiler** — one file, and the standard library is inside it, so there is
nothing to put beside it and nothing to install:

```bash
curl -LO https://github.com/wantzel/wantzel/releases/latest/download/wantzel-0.2.1-linux-x86_64
chmod +x wantzel-0.2.1-linux-x86_64
```

**Or build from source**, with a C compiler you need exactly once:

```bash
git clone https://github.com/wantzel/wantzel && cd wantzel
./build.sh                      # bootstrap, then the compiler builds itself
```

Either way you now have a compiler. Write a program and run it:

```pascal
include "io.wz";
begin
  io.puts(STDOUT, "hello, world\n");
end.
```

```bash
./bin/wantzel hello.wz hello && ./hello
./bin/wantzel hello.wz hello.exe --target=windows   # a Windows binary, from Linux
```

(If you downloaded the binary, it is `./wantzel-0.2.1-linux-x86_64` in place of
`./bin/wantzel`. The `include "io.wz"` above needs no `lib/` directory either way.)

That second line cross-compiles, and there is nothing to install for it: `--target=`
picks the target, one compiler emits both, and a Windows build of that compiler does the
same in reverse.

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

## Numbers, all measured on one laptop

A six-core machine, 15 September 2026. Reproduce them with `./build.sh` and `./wztest`.

| | |
|---|---|
| the compiler compiling itself | **11 ms** for 6,582 lines, about **598,000 lines/second** |
| a compiled binary starting | **156 µs**, about **6,400 starts/second** — no linker, no libc to initialise |
| full bootstrap from C to a fixed point | **280 ms** (`boot.c` → stage1 = stage2 = stage3) |
| the whole test suite | **2.1 seconds**, 107 tests |
| peak memory to compile the compiler | **3.0 MB** |
| the compiler binary | **526 kB**, statically linked, no libc, no dynamic dependencies |
| **400 compilers at once** | **902 ms** wall clock, all 400 succeeded, all 400 byte-identical (50 take 113 ms, 100 take 235) |

That last row is the one that matters for generated code. Four hundred parallel
compilations of the whole compiler, on six cores, finish in under a second — and the time
grows in step with the number (50 → 113 ms, 100 → 235 ms, 400 → 902 ms), so nothing is
contending. The machine you already have is not the constraint on how many agents you run,
and a compile is cheap enough to put inside the loop rather than at the end of it.

Byte-identical output under that load is the other half: when four hundred builds of the
same source produce one distinct binary, any difference between two binaries is a real
difference and never a race.

**And it holds as the source grows**, which is the part a single number cannot tell you.
Name lookup goes through a hash index, so compile time grows in step with the program
rather than with the square of it: 2,048 globals take 3 ms, 4,096 take 4 ms, 8,192 take
6 ms and 16,384 take 10 ms. Doubling the names roughly doubles the time. That is what keeps a
compile inside the loop on a large generated source instead of only on a small one.

The rate depends heavily on what the source is made of, so treat one number as one shape
of code — and that caveat is larger than it sounds. Measured over three generated shapes,
same compiler, same machine: dense procedural code runs at about **667,000 lines a
second**, a program built largely from `schema` and `tools` declarations at about
**67,000** — a tenth, because each line written generates a great deal of code — and a
file that is mostly long string literals at about **41,000 lines** a second, which is
nonetheless **163 MB** a second, because its lines are enormous.

Lines per second spans a factor of sixteen across those shapes and megabytes per second a
factor of eighty. Neither unit describes the compiler on its own, which is why
`./wztest --bench` reports and guards a rate per shape rather than one headline figure.

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

Questions, or something you built with it: <floris@wantzel.com>. Larger example
applications are being built at [wantzel/demos](https://github.com/wantzel/demos).
