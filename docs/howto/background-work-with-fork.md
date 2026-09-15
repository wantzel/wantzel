# Background work with fork: how it works and what it costs

*Measured 11 September 2026; the fork and wait4 behaviour re-checked against the compiler on
15 September.*

How a Wantzel program can do work in a second process without blocking the first, what the
compiler does for it, and where the edges are.

**The short version: it works, it needs no compiler change, and the difficulty is not in
starting a process but in cleaning it up.**

## 1. What the compiler does with a system call

Wantzel has no runtime and no libc. `sys1` through `sys6` are **builtins** that the compiler
translates straight to machine code. There is nothing in between: no wrapper, no error
handling, no errno translation.

```pascal
pid := sys1(SYS.fork, 0);
```

The arguments go into the registers of the System V convention — the same ones the ordinary
calling convention uses, which is what makes sharing them easy. The compiler then emits
literally two bytes:

```
0x0F 0x05        // the x86-64 SYSCALL instruction
```

On Windows there is a call to a shim instead of the instruction. That is the only place the
two platforms differ here.

**The number is the contract.** `SYS.fork = 57` and `SYS.wait4 = 61` are ordinary constants
in `lib/io.wz`; those are the Linux x86-64 numbers. The compiler does not know what fork is
and knows no system call by name. That is why this needs **no compiler change**: there is
nothing to add to the language, only a constant and a call.

The other side of that: there is also no checking. A wrong number or a wrong argument gives a
negative return value (`-errno`) or, worse, something that appears to work.

## 2. What the operating system does on fork

`fork` makes a **copy of the whole process**: the same code, the same data, the same open
file descriptors, the same program counter. From that point they diverge. The only difference
is the return value:

| | in the parent | in the child |
|---|---|---|
| `sys1(SYS.fork, 0)` | the child's pid (> 0) | `0` |
| on failure | `< 0` (`-errno`) | — |

## 3. What can go wrong

Roughly in order of how often it happens.

### The child dies without writing anything

A segfault, a `halt` on an error path, or the OS killing the process under memory pressure.
The parent sees an exit code but has no result. **A task therefore needs a status that
separates "started" from "finished"**, and the parent must be able to turn a non-zero exit
code into a failed task.

### Nobody reaps the child

If the parent forgets, the zombie stays. If the parent dies first, the child is adopted by
init and cleaned up properly — the only case that goes right by itself.

For a server that forks tasks: **something must reap periodically.** `wait4` with `WNOHANG`
asks "is anything finished" without blocking, and that can ride along in an existing event
loop.

### Two processes write to the same store

The most dangerous one, because it fails silently. The child inherits the store as it was at
the moment of forking and writes to it afterwards. So does the parent. Two processes writing
the same row produce unpredictable rubbish, and two writing different rows can overwrite each
other's length bookkeeping.

**The safe form is a strict division**: the child writes only to its own task row, which the
parent created before forking. No other table. Then there is no shared write location and
nothing to synchronise.

### The child inherits the open connections

The child has the same socket descriptors, including the listening socket and the connection
of the request that started it. A child that does not notice can write on that same
connection, or hold it open after the parent closed it. **A forked child should close what it
does not need, first thing.**

### The task does not survive a restart

Restart the server while a child is computing and the child is gone while the task says
"busy" forever. Fix it by marking every task that is still "busy" as "aborted" at startup — a
task cannot be running if the process has just begun.

## 4. The limits

| limit | value | what happens |
|---|---|---|
| processes per user | `ulimit -u`, often a few thousand | `fork` returns `-EAGAIN` |
| memory | copy-on-write, so only what the child writes | the OOM killer |
| file descriptors | inherited, `ulimit -n` per process | `accept` fails |
| zombies | until the process table is full | `fork` returns `-EAGAIN` |

The practical limit is almost always **the number of simultaneous tasks**, not memory. A
server that forks per request without an upper bound is a denial of service on itself. A
counter ("at most N tasks at once, refuse above that with a clear message") is the whole
solution and costs five lines.

## 5. What `http.serve` already does

The server already forks, but for something else: `http.serve(port, workers)` creates *n*
independent processes at startup, each opening its own listening socket with `SO_REUSEPORT`.
The kernel distributes the connections — all cores, no threads, no locks, nothing shared.

That is a **static** division: the workers are made once and live as long as the server. A
background task is the opposite — one child per task, ending when the work is done. They do
not conflict, but they share a trap: with multiple workers **every worker** does its own
reaping, and a task started in worker 3 can only be reaped by worker 3. So a request that
arrives at worker 1 must read the answer from disk rather than from memory.

## 6. If you build this

1. **The task row exists before the fork.** The parent creates it with status "busy" and
   returns the id; the child fills only that one row.
2. **The child closes what it does not need**, certainly the connection and the listening
   socket.
3. **Reap with `WNOHANG` in the existing loop**, and turn a non-zero exit code into a failed
   task with a readable reason.
4. **An upper bound on simultaneous tasks**, with a clean refusal above it.
5. **At startup, abort everything marked "busy"** — it cannot be true.
6. **Clean up by age**, or the data directory grows unnoticed.
7. **Return only the caller's own tasks.** A leaked id then still gives no access.

## What is deliberately not here

- **Threads.** Wantzel does not have them and will not get them; that would be a language
  change. It is also not needed: processes do the same work here without shared state, which
  is less to get wrong.
- **`posix_spawn`, `vfork`, `clone` with flags.** All reachable through `sysN` if it ever has
  to be, but `fork` is the simplest and the only one measured.
- **Signals.** A child that wants to be stopped cleanly needs a signal handler, and there is
  none. Aborting a task currently means killing the process and marking the row.

## Killing a background process is not the same as knowing it is gone

A measured lesson, and the most expensive one here.

- **`kill` is a request, not a confirmation.** It sends a signal and moves on. To be sure:
  `kill`, then `wait` (which only works on your own children), then a short poll on
  `kill -0`, and `kill -KILL` if it is still alive.
- **Tracking one pid is not enough** if something can be started twice. Keep a list; an
  overwritten variable forgets the first one silently.
- **A `trap` is not a guarantee.** It does not fire if the shell dies under a timeout, or if
  the child outlives the shell. A safety net one layer up — cleaning on something unique to
  that run, such as the temporary directory — catches exactly the cases the trap misses.
- **Look for the evidence in the PPID.** An orphan with PPID 1 was started as a daemon; one
  with the session leader's PPID was *adopted* after its parent disappeared. That difference
  is what identifies the cause.
- **"Memory does not come back" is a symptom with several causes.** Split it before
  concluding: `Cached` in `/proc/meminfo` is free to reclaim, `AnonPages` is not, and
  `ps -eo rss=,comm=` summed per command points at the real owner.

The specific trap worth naming: a test running inside command substitution (`out=$(...)`)
gives the test's stdout to a pipe, `$(...)` waits for that pipe to close, and a background
process **inherits that pipe**. The shell ends, the process lives on a moment longer, and is
then adopted outside the reach of any `trap`.
