# How one program reaches two operating systems

*Measured 15 September 2026 against real binaries, read back with `objdump`.*

A Wantzel program that writes a file contains no platform code at all. The same `io.write`
becomes a raw `syscall` instruction on Linux and a `WriteFile` call into kernel32 on
Windows — and the mechanism that does this is small enough to explain in full.

## Two targets, one source

`lib/io.wz` writes to a file like this, and this is the whole of it:

```pascal
return sys3(SYS.write, fd, a, n);
```

No `#ifdef`, no platform module, no second implementation. What `sys3` *becomes* depends on
`--target=`:

| target | what `sys3` emits |
|---|---|
| Linux | the `syscall` instruction, literally. The kernel, with nothing in between. |
| Windows | a call to `__wsys`, which the compiler generates **in Wantzel** |

`__wsys` receives the Linux system call number and dispatches on it:

```pascal
if nr = 1 then return __wwrite(a, b, c);      // write
if nr = 0 then return __wread(a, b, c);       // read
if nr = 2 then
begin
  if band(b, 65536) <> 0 then return __wopendir(a);   // O_DIRECTORY
  return __wopen(a, b);
end;
```

`__wwrite` calls `WriteFile` from kernel32. So: a pure system call on Linux, kernel32 on
Windows, from one line of library source.

### It is emulation, not translation

Look at `nr = 2` above. "Open" does not mean the same thing on the two systems, so opening a
*directory* routes somewhere else entirely. That is the honest description: `__wsys`
emulates a Linux system call interface on top of the Windows API, and where the two disagree
it makes a decision rather than pretending the difference away.

Worth saying plainly, because the alternative framing — "we translate system calls" —
promises something nobody can deliver. `__wsys` covers what the standard library needs. It
is a finite list of numbers in a real dispatch, not all of Linux.

## Reaching an API the compiler has never heard of

A system call covers what a program asks the *kernel*. A Windows program also wants
`MessageBoxA`, `CreateFontA`, `RegisterClassExA` — and there are tens of thousands of those.
Building them into a compiler is not a plan, it is a treadmill.

So they are data:

```pascal
winapi("user32.dll", "MessageBoxA", 0, text, title, 0);
```

The name is recorded while translating and written into the executable's import table.
Reaching a new Windows API is a line of ordinary source, not a compiler release.

### What the compiler still carries, and why

48 imports: 27 kernel32, 11 ws2_32, 1 advapi32, 9 user32. Not for convenience — the loader
fills the import table **before the first instruction runs**, so a program cannot look up the
functions it needs *in order to start*. `GetStdHandle`, `WriteFile`, `ExitProcess` and
`GetCommandLineA` have to be in the file the compiler wrote.

That is a bootstrapping constraint, and it is the whole of the justification. Everything a
program calls *after* it has started can be data.

### Naming one of those 48 yourself

Three cases, and they are all the compiler does:

| what you name | what happens |
|---|---|
| a DLL it has, a function it has | the existing slot; nothing is added |
| a DLL it has, a function it does not | a new entry, and a second directory entry for that DLL |
| a DLL it does not have | a new directory entry and new slots |

Measured: a program calling `winapi("kernel32.dll", "WriteFile", ...)` contains **one**
`WriteFile` in its import table, under the compiler's own `KERNEL32.dll` entry. The reuse is
per *function*, not per DLL — naming `user32.dll` does not hand you the built-in user32
block, which is why `MessageBoxA` still gets an entry of its own.

Two directory entries naming one library looks untidy and is deliberate: the built-in names
and the source-named ones are two separate runs in the name table, and interleaving them
puts the address table out of step with the names. That is not hypothetical — see below.

## Why this stays simple, which is the surprising part

The obvious worry: `lib/` is compiled **into** the compiler, so a library routine that names
an import has to be understood by the C bootstrap too, or a fresh clone could not build.

It is, and the two produce byte-identical output. No circularity arises, for a reason worth
stating: the imports a library routine names land in **your** executable, not in the
compiler's own table. The chain runs one way — the bootstrap compiles `lib/`, which compiles
your program — and nothing folds back on itself.

The one place the boundary is real is the startup path. Code that runs *before* your program
does cannot reach itself through an import table the loader has not filled yet. So the
question to ask of any candidate name is only: **does the startup path need it before user
code runs?** If no, it can be data. That is a bounded question, not a delicate one.

## The bug that proves the design

Worth telling because it is the strongest argument for the structure.

Compiling a program that named a user32 function, then a gdi32 one, then user32 again
produced an executable that jumped to **address zero**. The crash surfaced in a font routine
that had nothing to do with it.

The cause: the import table is written **grouped by DLL**, while `winapi()` calls are read in
**source order**. The slot of an import therefore depends on calls that have not been parsed
yet — so a slot computed at parse time was one too low, and pointed at the null terminator
between two DLL groups. Which is zero.

The fix is one line of principle: **a one-pass compiler must not bake a value that can still
change.** The fixup mechanism for exactly this already existed; it simply had no case for
import slots. Adding one made the problem disappear, in both compilers, with the bootstrap
fixed point intact.

Six isolated reproductions of the "obvious" hypothesis all *succeeded* before the actual
behaviour was read out of the running program. That is its own lesson: reproductions that
pass are evidence the hypothesis is wrong, not that the case is exotic.

## What this does not claim

- **"No platform code" applies to the standard library, not to everything.** A program that
  calls `winapi` directly is Windows-specific and should be, the same way a program calling
  X11 is Linux-specific. A desktop program of this kind has one shared core and two separate
  front ends — that is the honest shape.
- **The 48 is not a number to brag about driving to zero.** Most of it could move into `lib/`
  now the slot arithmetic is right, but ws2_32 is reached through `__wsys` rather than
  directly, and every name moved out is one the compiler can no longer count or check.
