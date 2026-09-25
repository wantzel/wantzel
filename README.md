<p align="center">
  <img src="docs/wantzel.svg" width="96" height="96" alt="Wantzel">
</p>

<h1 align="center">Wantzel</h1>

<p align="center">
  <strong>A programming language built for AI-written code.</strong><br>
  Compiles in milliseconds. Static binaries. Strict checks and clear errors.
</p>

<p align="center">
  <a href="https://wantzel.com">wantzel.com</a> ·
  <a href="docs/language.md">Language</a> ·
  <a href="examples/">Examples</a> ·
  <a href="docs/changelog.md">Changelog</a> ·
  MIT
</p>

---

Wantzel compiles to small, dependency-free binaries. Invalid programs are rejected with the
file, line and reason, so an agent can correct mistakes after every change.

1. Your agent writes a program.
2. `wantzel` returns a binary or a clear error in milliseconds.
3. The agent corrects the code and tries again.

The compiler is written in Wantzel and compiles itself. It emits static x86-64 Linux
executables directly, without an assembler, linker, C library or runtime. Windows users run
it under WSL2.

> **Early days.** Anything may change before 1.0: the language, the library and the command
> line.

## Quick start

```sh
curl -fsSLO https://github.com/wantzel/wantzel/releases/latest/download/wantzel-linux-x86_64
curl -fsSLO https://github.com/wantzel/wantzel/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS                  # wantzel-linux-x86_64: OK
mv wantzel-linux-x86_64 wantzel && chmod +x wantzel
./wantzel --version
```

That file contains the compiler and the complete standard library. There is nothing else to
install or build. `./wantzel --lib` lists the embedded modules; `./wantzel --lib io` prints
one. Move the binary to a directory on your `PATH`, such as `~/.local/bin/`, to call it as
`wantzel` from anywhere.

## A first program

```pascal
import io;

begin
  io.puts(STDOUT, "hello, world\n");
end.
```

```console
$ ./wantzel hello.wz hello && ./hello
hello, world
```

`import io;` loads a module embedded in the compiler. `include "mine.wz";` reads one of your
own files. The result is a static executable of about 2 kB. Invalid code gets one clear
error:

```console
$ ./wantzel oops.wz oops
wantzel: oops.wz:6: type error in assignment: expected int, found str
```

## Why Wantzel

| | |
|---|---|
| **Fast feedback** | The compiler builds its own 8,100 lines in about 10 ms. |
| **No dependencies** | The compiler and generated programs are static Linux binaries. No packages or runtime to install. |
| **Small at run time** | No virtual machine or garbage collector. |
| **Clear errors** | Rejected code reports the file, line and reason. |

Two languages shaped Wantzel. *Turbo Pascal* showed how immediate an edit-run loop can feel.
*Go* showed the value of shipping one static binary. One shaped the feedback loop; the other
shaped the result.

## What is in the box

The embedded standard library covers files, processes, JSON, HTTP, WebSocket, MCP, OAuth,
TLS 1.3, ACME and persistent storage. Its source is in [`lib/`](lib/); none of it calls into
C.

A tool is one declared line; the compiler generates its JSON Schema, argument parsing,
dispatch and result writing.

```pascal
tools
  convert(ConvertArgs): ConvertResult "Convert Celsius to Fahrenheit." readonly idempotent;
end;
```

[`examples/`](examples/) contains complete single-file programs, including MCP and HTTP
servers, an HTTPS client and server, and a file server over MCP.

## Build from source

You need `git`, a C compiler available as `cc`, and a POSIX shell with coreutils, including
`sha256sum`. The C compiler is used once to build `bootstrap/boot.c`.

```sh
git clone https://github.com/wantzel/wantzel
cd wantzel && ./build.sh
./bin/wantzel examples/hello.wz hello && ./hello
```

`./build.sh` completes these steps in well under a second:

1. `cc` builds the minimal bootstrap compiler as `bin/wantzel0`.
2. The bootstrap compiles `src/wantzel.wz`. That compiler compiles stage 2, which compiles
  stage 3.
3. Stage 2 and stage 3 must be byte-identical. The build stops if the compiler cannot
  reproduce itself exactly.
4. The build embeds the standard library in stage 3, reads every module back and compares
  it with its source. The result becomes `bin/wantzel`.

To check the bootstrap, fixed point and full suite:

```sh
./wztest --toolchain
```

Each release tag builds to the exact published file:

```sh
tag=$(git describe --tags --abbrev=0)                  # the newest release
git checkout -q "$tag" && ./build.sh
curl -fsSLO "https://github.com/wantzel/wantzel/releases/download/$tag/SHA256SUMS"
cp bin/wantzel wantzel-linux-x86_64 && sha256sum -c SHA256SUMS
```

## Documentation

| | |
|---|---|
| [Language](docs/language.md) | the binding specification, opening with a tour |
| [Syntax](docs/syntax.md) | keywords and spelling, as a reference |
| [Command line](docs/flags.md) | every flag, and what deliberately has none |
| [Writing Wantzel](docs/writing-wantzel.md) | common mistakes and how to diagnose them |
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
| `bootstrap/boot.c` | the minimal C compiler used once to compile `src/` for Linux |
| `bootstrap/libpack.wz` | packs `lib/` into the trailer `build.sh` appends to the compiler |
| `lib/` | the standard library, as source; `build.sh` packs it into the compiler |
| `examples/` | single-file programs |
| `tests/` | the suite: `./wztest` runs it |

## Contributing and licence

Wantzel is MIT licensed; see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md) says
what is useful and how to report a bug, and [SECURITY.md](SECURITY.md) how to report a
vulnerability.

Questions, or something you built with it: <floris@wantzel.com>.
