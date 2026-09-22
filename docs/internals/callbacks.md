# Letting Windows call you back

*Built and measured 15 September 2026.*

A program that draws a window does not run from top to bottom. It sits and waits, and the
operating system tells it when something happened: a key, a click, a window uncovered. The
two systems arrange that differently, and the difference decided how much work this was.

**On Linux it is a conversation.** Events arrive on a socket; the program reads them in its
own loop and decides what to do. Nothing unusual is needed — which is why an X11 program was
working well before a Windows one.

**On Windows the operating system calls you.** You hand it the address of a function and
Windows jumps into your program whenever it has news. That is the part the language could
not do. Not "was awkward at" — could not do at all: there was no way to express *the address
of this function*, by design, because addresses of functions are the thing that makes
languages unsafe.

And the obvious way around it does not exist. A button click is *sent* directly to your
function, not *posted* to the queue your loop reads — so no amount of cleverness in the loop
can see it. Microsoft's documentation is explicit about the distinction, and it removes the
escape route completely.

## What was added, and what was refused

The easy fix would have been to allow taking the address of any routine. That is a function
pointer, and this language does not have them on purpose: a pointer to code is something you
can get wrong in a way nothing checks.

So the door was opened exactly as wide as the need, and no wider:

```pascal
winproc(handler)
```

One builtin, one job, and a name that says what it is for. It works only when building for
Windows; on Linux it does not compile, because a callback is a Windows notion and pretending
otherwise would hide the difference rather than handle it.

**What it gives back is not the routine's address.** That would have compiled and then
misbehaved: Windows passes arguments in one set of registers and this language reads them
from another. So the compiler writes a small adapter next to your routine and hands back the
address of *that* — a dozen instructions that move the arguments across, set up the stack the
way the platform demands, and preserve the registers Windows expects to find untouched.

That last part is the one that bites. Two registers are *yours to destroy* on Linux and
*yours to preserve* on Windows — the single point where the two conventions disagree about
who owns what. Getting it wrong does not crash at the call. It crashes later, somewhere
unrelated, which is exactly how it presented: a fault on an address that meant nothing.

## Why this is general, and not a window-shaped hack

The risk with a feature like this is that it solves today's problem and is back on the table
in a month. It is not, and the reason is arithmetic rather than optimism.

**Every callback in the Windows API has the same shape**: up to four arguments in registers,
one integer back. Window procedures, dialog procedures, window enumerators, hooks, timers,
sort comparators, thread entry points — all of them. So an adapter that carries four
arguments carries all of them, and one that takes fewer simply ignores the rest.

The proof is that the first thing it was tested against was not a window at all:
`EnumWindows` handed a Wantzel routine each open window in turn, ten times, and returned
cleanly. Nothing about that call knows what kind of program it was built for.

## How this gets used, and how it should not

Reaching it directly looks like this:

```pascal
winapi("user32.dll", "EnumWindows", winproc(onwindow), 0);
```

Two low-level things in one line: a raw DLL call and a raw callback address. **That is the
right shape for the compiler and the wrong shape for an application.** Nobody writing a
desktop program should be thinking about user32.dll.

What belongs above it is an ordinary library, so the application writes ordinary code:

```pascal
include "win.wz";

procedure onclick(id: int); forward;      // you write this

begin
  win.window("Totals", 326, 539);
  win.button("Refresh", 0, 2);
  win.run;                                // the loop lives in here
end;
```

The callback, the adapter, the message loop, the structure layouts and the four-register
convention all sit inside `win.wz`. The application sees a function it defines and a
function it calls — the same thing it would see in any language, except there is no toolkit
underneath and the binary is measured in kilobytes.

**That is the line this project keeps drawing**: the compiler gains the smallest thing that
cannot be done without it, and everything else is a library. `winproc` is that smallest
thing. It exists so that `win.wz` can exist, and `win.wz` exists so that nobody else has to
know either of them is there.

## What is not done

- `lib/win.wz` is not written. The mechanism is proven and two Win32 programs are built on
  it directly; the vocabulary above it is not.
- Only the callback side is a language question. A Windows window still needs its class
  structure filled in correctly, and those layouts are written down in
  [`../howto/a-window-on-windows.md`](../howto/a-window-on-windows.md).
- Nothing here is needed on Linux, and that asymmetry is worth keeping in view: the same
  application ends up with two interface files, and one of them required a language feature
  the other never asks for.
