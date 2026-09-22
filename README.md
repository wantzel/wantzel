# Wantzel

**A programming language for the code AI agents write.**

Compiles in milliseconds, into a dependency-free binary that needs almost no memory to run —
and refuses anything it cannot prove correct, out loud. So agents can write code here, and
iterate on it in large swarms, on the machine you already have.

The compiler is written in Wantzel and compiles itself. It produces static x86-64
executables for Linux and Windows: no assembler, no linker, no C library, no runtime.

> **Early days.** Anything may change before 1.0 — the language, the library, the
> command-line interface.

[**wantzel.com**](https://wantzel.com) — what it is for, in one page.

## Try it

```bash
git clone https://github.com/wantzel/wantzel
cd wantzel && ./build.sh                      # build, once
./bin/wantzel examples/hello.wz hello && ./hello   # compile and run
```

**Take the archive, not the bare binary**, if you download a release: almost every program
begins with an `include`, and those are resolved from a `lib/` directory beside the compiler.

## Why

- **Compile speed** — over 800,000 lines per second. Fast enough to compile on every change,
  which is what makes iterating possible at all.
- **Dependency-free binaries** — one static binary, and the programs it produces are the
  same. Nothing to install per agent, so there is nothing to isolate and nothing to tear down.
- **Low memory at run time** — no runtime, no garbage collector, no virtual machine.
- **A strict, verbose compiler** — what it refuses is what nobody has to review, and what it
  accepts it accepts in silence. Otherwise: the file, the line, and the reason.

## The documentation

**The language**

- [`docs/language.md`](docs/language.md) — the binding specification, opening with a tour
- [`docs/syntax.md`](docs/syntax.md) — the keywords and the spelling, as reference
- [`docs/flags.md`](docs/flags.md) — the command line, and what deliberately has no flag
- [`docs/conventions.md`](docs/conventions.md) — how to lay out a project

**Writing it**

- [`docs/writing-wantzel.md`](docs/writing-wantzel.md) — the pitfalls, and how to get from an
  error message to its cause
- [`docs/testing.md`](docs/testing.md) — the suite, and how to add to it
- [`examples/`](examples/) — eleven single-file programs, among them an MCP server, an HTTP
  server, a file server over MCP and an OAuth flow

**Why it is like this**

- [`docs/design.md`](docs/design.md) — the reasoning behind the language
- [`docs/internals/`](docs/internals/) — how the compiler works, with the measurements the
  design rests on
- [`docs/howto/`](docs/howto/) — a window on X11 or Win32, background work with fork,
  signing a Windows executable
- [`docs/changelog.md`](docs/changelog.md) — what changed, and what it asks of you

## Layout

| | |
|---|---|
| `src/` | the compiler, in Wantzel |
| `bootstrap/boot.c` | the same compiler in C, used once to build the first one |
| `lib/` | the standard library |
| `examples/` | single-file programs |
| `tests/` | the suite; `./wztest` runs it |

## Status and licence

Pre-1.0 and measured rather than claimed. MIT; see [LICENSE](LICENSE). Contributions are
welcome: [CONTRIBUTING.md](CONTRIBUTING.md) says what is useful and how to report a bug.

Questions, or something you built with it: <floris@wantzel.com>.
