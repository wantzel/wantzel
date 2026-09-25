<p align="center">
  <img src="docs/wantzel.svg" width="96" height="96" alt="Wantzel">
</p>

<h1 align="center">Wantzel</h1>

<p align="center">
  <strong>A programming language for the code AI agents write.</strong><br>
  Strict, fast and verbose. No dependencies. Errors an agent can act on.
</p>

<p align="center">
  <a href="https://wantzel.com">wantzel.com</a> ·
  <a href="docs/language.md">Language</a> ·
  <a href="examples/">Examples</a> ·
  <a href="docs/changelog.md">Changelog</a> ·
  MIT
</p>

---

Wantzel compiles in milliseconds into a static binary that needs almost no memory to run.
It refuses anything it cannot prove correct, and says why. That makes it a language agents
can write, and iterate on in large numbers, on the machine you already have.

```
your agent  ──writes──▶  wantzel  ──▶  a static binary
     ▲                      │
     └────────corrects──────┘  or: file, line and reason
                            — in milliseconds
```

The compiler is written in Wantzel and compiles itself. It emits static x86-64 Linux
executables directly: no assembler, no linker, no C library, no runtime.
On Windows, run it under WSL2.

> **Early days.** Anything may change before 1.0: the language, the library and the command
> line.

## Quick start

```bash
git clone https://github.com/wantzel/wantzel
cd wantzel && ./build.sh                            # build the compiler, once
./bin/wantzel examples/hello.wz hello && ./hello    # compile and run
```

That is the whole installation. If you download a release, take the archive rather than
the bare binary: `include` is resolved from the `lib/` directory beside the compiler.

## A first program

```pascal
include "io.wz";

begin
  io.puts(STDOUT, "hello, world\n");
end.
```

```console
$ wantzel hello.wz hello && ./hello
hello, world
```

The result is a static executable of about 9 kB. When something is wrong, the compiler
says where and what, in one line:

```console
$ wantzel oops.wz oops
wantzel: oops.wz:6: type error in assignment: expected int, found str
```

## Why Wantzel

| | |
|---|---|
| **Compile speed** | The compiler builds its own 8,100 lines in about 10 ms: fast enough to compile on every change, inside the loop rather than after it. |
| **No dependencies** | One static binary, and every program it produces is one too. Nothing to install per agent, nothing to tear down. |
| **Small at run time** | No runtime, no garbage collector, no virtual machine. |
| **Strict and verbose** | What it refuses, nobody has to review. What it accepts, it accepts in silence. Otherwise: the file, the line and the reason. |
| **HTTPS with nothing linked** | TLS 1.3 written in the language itself: X25519, ChaCha20-Poly1305, ECDSA P-256/P-384, RSA, chain verification and a trust store. [`examples/autocert.wz`](examples/autocert.wz) serves HTTP and HTTPS and gets and renews its own Let's Encrypt certificate from one event loop. |

## What is in the box

The standard library in [`lib/`](lib/) covers what a networked tool needs, with no C
underneath: files and processes, JSON and JSON Schema, an HTTP server, WebSocket on the same
port, an MCP server over stdio or HTTP, OAuth, TLS 1.3, ACME, and a persistent store.

A tool is one declared line; the compiler generates its JSON Schema, argument parsing,
dispatch and result writing.

```pascal
tools
  convert(ConvertArgs): ConvertResult "Convert Celsius to Fahrenheit." readonly idempotent;
end;
```

[`examples/`](examples/) holds single-file programs you can read in one sitting, among them
an MCP server, an HTTP server, an HTTPS client and server, and a file server over MCP.

## Documentation

| | |
|---|---|
| [Language](docs/language.md) | the binding specification, opening with a tour |
| [Syntax](docs/syntax.md) | keywords and spelling, as a reference |
| [Command line](docs/flags.md) | every flag, and what deliberately has none |
| [Writing Wantzel](docs/writing-wantzel.md) | the pitfalls, and how to get from an error to its cause |
| [Library](docs/library.md) | the standard library: every module, and the routines of each |
| [Conventions](docs/conventions.md) | how to lay out a project |
| [Testing](docs/testing.md) | the suite, and how to add to it |
| [Design](docs/design.md) | why the language is the way it is, and how the compiler works |
| [How-to](docs/howto.md) | background work, serving HTTPS, resolving names |
| [Changelog](docs/changelog.md) | what changed, and what it asks of you |

## Repository layout

| | |
|---|---|
| `src/` | the compiler, in Wantzel |
| `bootstrap/boot.c` | a small C compiler, used once to build the first binary -- just enough of the language to compile `src/` itself, for Linux |
| `lib/` | the standard library |
| `examples/` | single-file programs |
| `tests/` | the suite: `./wztest` runs it |

## Contributing and licence

Wantzel is MIT licensed; see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md) says
what is useful and how to report a bug, and [SECURITY.md](SECURITY.md) how to report a
vulnerability.

Questions, or something you built with it: <floris@wantzel.com>.
