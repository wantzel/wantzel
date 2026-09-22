# Command line

```
wantzel <source.wz> <executable> [--target=linux|windows]
wantzel --version
```

Two arguments and one option. That is the whole interface, and it is short on purpose: a compiler with thirty switches is thirty things to get wrong, and an agent in a
loop should not have to choose.

## The options

### `--target=linux` | `--target=windows`

Which operating system the executable is for. **The default is Linux.**

```bash
wantzel prog.wz bin/prog                      # an ELF
wantzel prog.wz bin/prog.exe --target=windows # a PE32+
```

**The output name decides nothing.** A name ending in `.exe` used to select Windows on its
own, so `wantzel x.wz backup.exe` handed back a Windows binary nobody asked for — a second
way to choose the target, and an invisible one. A `.exe` name without `--target` is now
refused rather than quietly built:

```
wantzel: the output name ends in .exe but no target was given; add --target=windows
         (or --target=linux to build an ELF under that name)
```

### `--version`

Prints the version and exits.

```
$ wantzel --version
wantzel 0.2.1
```

## Where the options go

**After the two file names.** The compiler reads the source and the output first:

```bash
wantzel prog.wz bin/prog --target=windows     # right
wantzel --target=windows prog.wz bin/prog     # refused
```

## What there is no flag for, and why

| | |
|---|---|
| **optimisation level** | there is no optimiser. Straightforward code generation keeps what runs recognisable as what you read, and it is a large part of why compiling takes milliseconds. See [`design.md`](design.md) |
| **include paths** | there is one, and it is not configurable: `lib/` beside the compiler's own executable. `include "io.wz"` is looked for there first, then beside the source file; a name with a `/` in it is a path and is only looked for beside the source. Point it somewhere else by putting the compiler somewhere else |
| **warnings** | there are none. Something is an error or it is fine — a warning is a thing you learn to scroll past |
| **debug information** | a binary carries the file and line of every runtime check, always. That is what an agent needs to fix its own mistake, so it is not something to switch on. The file is named relative to the project, never by its path on the build machine — see below |
| **stripping the build path** | nothing to strip. A runtime message carries at most the last two directory segments (`src/win32/main.wz:412`), so the same source gives the same binary whether you name it relatively or absolutely, and no executable carries the layout of the machine that built it |
| **linking** | there is no linker and nothing to link. No libc, no runtime, no shared libraries |

Each of those is a decision rather than a gap. If one of them turns out to be wrong it
changes here, with a count behind it.
