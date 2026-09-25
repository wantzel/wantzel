# Command line

**Two arguments and one option to compile; two questions to ask it — the whole interface.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

```
wantzel <source.wz> <executable> [--debug]
wantzel --version
wantzel --lib
wantzel --lib <module>
```

Short on purpose: a compiler with thirty switches is thirty things to get wrong, and an
agent in a loop should not have to choose. Options go **after** the two file names. Run
`wantzel` with no arguments (or with one it does not know, such as `--help`) and it prints
these lines.

## `--debug`

Writes `<executable>.wzdbg` beside the binary: which address belongs to which source
line, and where every routine, parameter, local and global lives, with its type.

```bash
wantzel prog.wz bin/prog --debug                       # bin/prog and bin/prog.wzdbg
```

**A `--debug` build keeps every routine**: a plain build leaves out the routines a program
never calls, but the sidecar records addresses as the code is written, so a debug build skips
that step and is larger than a plain one -- the same program, with nothing moved. Plain text, one record per
line; format in [design.md](design.md). A library module is named `wantzel/lib/<module>.wz`
in it, wherever the compiler is installed; `wantzel --lib <module>` gives its source.

## `--version`

Prints the version and the standard library this compiler carries, then exits.

```console
$ wantzel --version
wantzel 0.5.0
library built in: 48 modules, 979949 bytes (485040 stored), sha256 5549b4a93a96...
```

The library is part of the compiler file, so the second line is a fact about the file, not
about where it is installed: how many modules, their size unpacked and as stored, and the
sha256 over their source. Two compilers that print the same line compile every `import` to
the same text. A compiler built without its library (only the bootstrap stages are) says
`library MISSING`.

## `--lib`

Without a name, lists the modules of the library this compiler carries, one per line, in
order; with a name, writes that module's source to standard output, byte for byte the
file it was built from.

```console
$ wantzel --lib
acme
aead
...
$ wantzel --lib io > io.wz          # the source of `import io;`, to read or to step into
$ wantzel --lib jsn
wantzel: no library module 'jsn' in this compiler; wantzel --lib lists them -- did you mean: wantzel --lib json
```

This is the source the compiler actually uses, so an editor showing a definition or a
debugger showing a line of a module reads it from here rather than from some other copy.
An unknown name is an error on standard error, with exit code 1 and nothing on standard
output.

## What has no flag, and why

| | why not |
|---|---|
| **optimisation level** | there is no optimiser; straightforward code generation keeps output recognisable as source, and is why compiling takes milliseconds |
| **include paths** | none to set. `import io;` reads the module from the compiler itself; `include "x.wz";` reads the file relative to the file that names it. There is nothing in between to configure |
| **a library directory** | none, and no environment variable either: the library is part of the compiler file. A `lib/` directory anywhere changes nothing. To try a changed module, include your copy as a file |
| **warnings** | none — something is an error or it is fine |
| **debug info in the binary** | every runtime check already carries its file and line, always, in the executable itself; `--debug` adds a *separate* file for a step-by-step debugger, never bytes in the binary |
| **stripping the build path** | nothing to strip — a runtime message carries at most the last two path segments (`src/ui/main.wz:412`), and a library module is always `wantzel/lib/<module>.wz`, so the same source gives the same binary built from any path |
| **target** | one output: a static x86-64 Linux ELF. The kernel is reached through `SYSCALL` directly, so there is no second platform to select |
| **linking** | no linker, nothing to link: no libc, no runtime, no shared libraries |

Each is a decision, not a gap. If one turns out wrong, it changes here, with a count
behind it.
