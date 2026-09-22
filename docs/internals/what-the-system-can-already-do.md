# What the system can already do

*Measured 11 September 2026; every claim re-checked against the compiler and `lib/` on
15 September.*

What is available today in Wantzel and `lib/`, what of that is **proven** by an experiment,
and which limitations are a *choice* rather than a property of the language.

This document exists because three things were called impossible here that already worked.

## The rule that makes it worth writing down

**`sys1` through `sys6` are builtins that emit the `SYSCALL` instruction literally.** The
system call *number* is an ordinary constant in `lib/io.wz`, and **the compiler knows no
system call by name.**

From that follows something easy to overlook: *everything the operating system offers is
reachable without touching the language.* A new capability is a constant plus a call — no
compiler change. What remains to decide is **where** it belongs: in `lib/` (almost always) or
in the application (almost never).

### The same holds on Windows, through `winapi()`

`winapi("kernel32.dll", "GetModuleFileNameA", ...)` names a DLL and a function **as
strings**, and the PE writer emits the import like any other. So a Windows API the compiler
has never heard of is also reachable without a compiler change — the dynamic route
(`GetProcAddress`) is there as well when a function should not be a hard import.

**Worth writing down because it was missed in exactly the situation it was made for.** On
17 September 2026 the library search path was being anchored on the executable instead of
`argv[0]`, which on Linux is `readlink("/proc/self/exe")`. The Windows equivalent is
`GetModuleFileNameA`, and that name is *not* in the compiler's own import table — from which
the wrong conclusion followed, that the Windows side needed the import table extended and
therefore a compiler change. It did not: the name is a string, and a string is data.

Two lessons, and the second is the reusable one:

1. **Not in the built-in import table is not the same as not reachable.** The table exists
   for what the *runtime* needs before user code runs; anything else is named by the source.
2. **Check the reachability question before the scope question.** "This needs a compiler
   change" was reached by looking at the wrong list. The rule at the top of this document is
   the answer on both platforms, and forgetting it on one of them costs the same as
   forgetting it on both — see also `fork`, shared memory and `flock` below, each called
   impossible here before someone tried.

## Processes and concurrency

| | state | evidence |
|---|---|---|
| `fork` | **yes** | **measured**: the parent continues while the child computes 200 million iterations |
| copy-on-write | **yes** | **measured**: the child overwrites 4 MB, the parent keeps its own values; peak 3.9 MB |
| a child's exit code | **yes** | **measured**: raw status 1792 → exit code 7 |
| the signal from a crashed child | **yes** | **measured**: SIGKILL gives exit code 0 *and* signal 9 |
| reaping without blocking | **yes** | `wait4` with `WNOHANG`; fits an existing event loop |
| **shared memory between processes** | **yes** | **measured**: the child writes 999, the parent reads 999 |
| **locking between processes** | **yes** | **measured**: the parent waits 250 ms for a lock |
| several server processes | **yes** | `http.serve(port, workers)` does this, with `SO_REUSEPORT` |
| threads | **no** | and that stays so: processes do the same work here without shared state |

### Three traps found the hard way

**1. `flock` attaches to the open file description, not to the process.** That description is
**shared** on `fork`, so a child inheriting the descriptor shares the lock too and never
collides with the parent — with no error, and everything appears to work. Measured: 0 ms
instead of the expected 250. Only with its **own `open`** in the child does it really lock.

**2. An exit status is not the exit code.** A normally terminated process gives
`(status >> 8) & 255`, but a process killed by a signal has **zero** in those bits and the
signal number in the lowest seven. Reading only `shr 8` shows a crashed child as "finished,
code 0". `proc.exited`, `proc.exitcode` and `proc.signal` exist precisely for this.

**3. A child must never return into the HTTP loop.** It shares the request's connection with
the parent; two processes answering on it produce nonsense. A forked child ends with `halt`,
always.

## Storage

| | state |
|---|---|
| durable tables with crash recovery | **yes** — `lib/store.wz`: append-only log plus snapshot |
| atomic rename | **yes** — `SYS.rename` |
| mapping memory from a file | **yes** — `SYS.mmap` |
| resuming from a log position | **yes** — `store.replay(from)`, with `store.logsize` as the counter |
| appending from two processes without interleaved records | **yes** — `O_APPEND`, measured up to 1 MB per record |
| **multiple writers** | **no, but that is a CHOICE** — see below |

### The single-writer choice, stated explicitly

`lib/store.wz` maps its rows with `MAP_PRIVATE | MAP_ANONYMOUS`. After a `fork` the child
gets a copy-on-write copy: **what the child writes to a row, the parent never sees.** The head
of that file has always been honest about it:

> One process writes; readers of a shared directory are not supported (there is nothing to
> lock yet but the log, see flock).

Note the word **yet**. This is not an impossibility but a decision not taken:

- `MAP_SHARED` is already declared in `lib/io.wz`
- `SYS.flock`, `LOCK_EX` and `LOCK_UN` are there too
- `store.replay(from)` resumes from an offset, so the log can be re-read in the meantime
- **an `O_APPEND` write stays intact, well above `PIPE_BUF`.** Measured: a parent and child
  each wrote sixteen records to the same file, each with its own `open`; at 64 kB per record
  and at 1 MB per record, not one interleaved record came out. The 4096-byte limit from POSIX
  applies to pipes, not to ordinary files: Linux serialises the offset increment and the write
  under the inode lock. So `flock` is not needed to keep a record intact — possibly for the
  reader side, or to keep several records together. **This does not hold on NFS.**

So all four primitives a shared task table needs are present. What is missing is the decision
to take `lib/store.wz` from one writer to several, and that should be deliberate rather than a
by-product of something else.

## What a database did, and what it did not

In a classic stack a database is not only storage but also the **concurrency layer**:

| a database | here |
|---|---|
| multiple writers with MVCC | one writer |
| transactions: all or nothing | one `store.set` is atomic, a sequence is not |
| visibility between processes | none |
| row locking, deadlock detection | not needed with one writer |
| `LISTEN`/`NOTIFY` | polling, or a pipe |
| **crash recovery with a WAL** | **the append-only log does exactly this** |
| `VACUUM`, TTL | by hand |

The bottom two are worth naming: there it is **not** worse. The rest is a deliberate trade —
no planner, no connection pool, no isolation levels — and that trade holds as long as there is
one writer.

## Network and protocol

| | state |
|---|---|
| HTTP server, several workers | **yes** |
| MCP over HTTP and stdio | **yes** |
| OAuth 2.1 with DCR and PKCE | **yes** |
| OpenAPI from the same declarations | **yes** |
| ONNX inference in pure Wantzel | **yes** — `lib/onnx.wz`, calibrated to 1e-6 against onnxruntime |
| reading protobuf | **yes** — `lib/protobuf.wz` |
| TLS | **no** — handled by a separate process in front |
| chunked / streaming response | **no** |
| pipes between processes | **not declared yet** — `SYS.pipe2` is one line |

TLS is the honest exception to "zero dependencies" and is open as such.

## How to add something here

1. **Find the system call number** for x86-64 and put it with the others in `lib/io.wz`.
2. **Write the call** with `sysN`, and check the return value: a negative result is `-errno`.
3. **Measure it with a small program** before believing it. Every "yes" above was written only
   after a running program produced the number next to it.
4. **Put it in `lib/`**, not in the application — the next program needs it too.
5. **Carry the Windows side in the same change**, with `winapi()` and the DLL function by
   name. A capability that exists on one target only is half a capability, and the
   asymmetry is discovered much later — usually by a test under Wine.

**And if a system call has no Windows counterpart, make the emulation return an error rather
than refuse.** `__wsys` traps on a number it does not know, which is right for a program that
cannot continue and wrong for a caller that has a fallback ready: `readlink` on Windows
returns `-1` so the anchor above falls back to `argv[0]`. Trapping there killed the compiler
itself before it compiled anything.
