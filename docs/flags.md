# Command line

**Two arguments and two options — the whole interface.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

```
wantzel <source.wz> <executable> [--target=linux|windows] [--debug]
wantzel --version
```

Short on purpose: a compiler with thirty switches is thirty things to get wrong, and an
agent in a loop should not have to choose. Options go **after** the two file names.

## `--target`

`--target=linux` (default) or `--target=windows` (short: `-tlinux`, `-twindows`).

```bash
wantzel prog.wz bin/prog                      # an ELF
wantzel prog.wz bin/prog.exe --target=windows # a PE32+
```

**The output name decides nothing.** A `.exe` name with no `--target` used to select
Windows on its own — a second, invisible way to choose the target — so it is now refused:

```
wantzel: the output name ends in .exe but no target was given; add --target=windows
         (or --target=linux to build an ELF under that name)
```

## `--debug`

Writes `<executable>.wzdbg` beside the binary: which address belongs to which source
line, and where every routine, parameter, local and global lives, with its type.

```bash
wantzel prog.wz bin/prog --debug                       # bin/prog and bin/prog.wzdbg
wantzel prog.wz bin/prog.exe --target=windows --debug  # bin/prog.exe and bin/prog.exe.wzdbg
```

**The executable is byte-identical with and without the flag** — the sidecar is the whole
difference, so the build you debug is the build you ship. Plain text, one record per
line; format in [design.md](design.md).

## `--version`

Prints the version and where the library is, then exits.

```console
$ wantzel --version
wantzel 0.2.1
library /opt/wantzel-0.2.1-linux-x86_64/lib/
```

The second line is a diagnosis, not a setting: the standard library is read from disk, so
a compiler copied away from its `lib/` cannot resolve `include "io.wz"`. If the directory
is missing, the line says so instead of the path:

```
library /home/you/bin/lib/   NOT FOUND -- copy lib/ next to the compiler
```

There is no flag to point the include path elsewhere (see below).

## What has no flag, and why

| | why not |
|---|---|
| **optimisation level** | there is no optimiser; straightforward code generation keeps output recognisable as source, and is why compiling takes milliseconds |
| **include paths** | one fixed path: `lib/` beside the compiler binary. `include "io.wz"` looks there first, then beside the source file; a name with `/` is a path and is only looked for beside the source. Move the include target by moving the compiler |
| **warnings** | none — something is an error or it is fine |
| **debug info in the binary** | every runtime check already carries its file and line, always, in the executable itself; `--debug` adds a *separate* file for a step-by-step debugger, never bytes in the binary |
| **stripping the build path** | nothing to strip — a runtime message carries at most the last two path segments (`src/win32/main.wz:412`), so the same source gives the same binary built from any path |
| **linking** | no linker, nothing to link: no libc, no runtime, no shared libraries |

Each is a decision, not a gap. If one turns out wrong, it changes here, with a count
behind it.
