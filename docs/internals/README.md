# How Wantzel works inside

The other documents in `docs/` tell you how to *use* the language. These tell you how it
**works** — what the compiler does, why it was built that way, and what the two operating
systems it targets actually demand.

You do not need any of this to write Wantzel. Read it when you want to know why something is
the way it is, when you are changing the compiler, or when a platform is behaving in a way
the API documentation did not prepare you for.

## How the compiler works

| | |
|---|---|
| [`two-operating-systems.md`](two-operating-systems.md) | how one `io.write` becomes a raw `syscall` on Linux and a `WriteFile` call on Windows, and how a program reaches an API the compiler has never heard of |
| [`callbacks.md`](callbacks.md) | what it takes to let Windows call a Wantzel routine, and the register convention that makes it harder than it looks |
| [`memory.md`](memory.md) | arrays, indexes, slices, `view` and `mmap`: how you work with large data with no heap and no pointers |
| [`what-the-system-can-already-do.md`](what-the-system-can-already-do.md) | what is available today and proven by an experiment, and which limits are a choice rather than a property |

## What the design rests on

[`../design.md`](../design.md) makes the argument for the language. These two carry the
measurements underneath it — the evidence, in enough detail to be argued with:

| | |
|---|---|
| [`no-pointers.md`](no-pointers.md) | nine linked structures built without pointers, two of them safer for it, and the one place it genuinely stops |
| [`why-strict.md`](why-strict.md) | why a language written by a generator is stricter than one written by hand, from 100 recorded mistakes |
| [`three-measures.md`](three-measures.md) | compile time, binary size and run time measured together — and why the usual trade-off did not appear |

## Building something on a platform

The field notes for a specific platform — the structure layouts, the protocol, the traps —
are task-shaped, so they live in [`../howto/`](../howto/) next to the thing you are trying to
build:

| | |
|---|---|
| [`../howto/a-window-on-windows.md`](../howto/a-window-on-windows.md) | the x64 structure layouts you cannot guess, and why a message loop cannot see a button click |
| [`../howto/a-window-on-x11.md`](../howto/a-window-on-x11.md) | the X11 wire protocol over a socket, its fonts, and why its failures are silent |

## What you will not find here

**Measurements without their caveats.** Every number below comes with the machine, the date
and what would make it stale. A figure quoted without those is not evidence of anything, and
the audience for this project measures for itself.

**Anything that has not been run.** These documents describe code that exists and was
executed. Where something is partial, it says so in the first paragraph rather than the last.
