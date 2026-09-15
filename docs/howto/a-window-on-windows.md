# Calling Win32 from Wantzel: the layouts you cannot guess

*Measured 15 September 2026. Structure layouts from Microsoft's documentation; the x64
offsets below were worked out from it rather than quoted, so if something does not fit, the
arithmetic here is the suspect.*

A DLL function the compiler has never heard of, called because the source named it:

```pascal
winapi("user32.dll", "MessageBoxA", 0, addr(text[0]), addr(title[0]), 0);
```

No entry in the compiler's import table, no recompilation of the compiler. The name is data.
How that works is in [`../internals/two-operating-systems.md`](../internals/two-operating-systems.md); what
follows is what the platform demands once you are through that door.

## Three places a wrong name shows up

The cost of naming imports in the source is that checking is spread over three moments:

| what is wrong | caught at | what happens |
|---|---|---|
| wrong `--target` | **compile time** | `winapi() is only available in a Windows executable` |
| a DLL that does not exist | **load time** | the loader refuses; **not one line of the program runs** |
| a function that does not exist, in a real DLL | **run time** | the program starts, then aborts *at that call* |

The third is worth knowing because it is counter-intuitive, and it was measured after being
predicted wrongly. A missing DLL cannot be resolved and the loader refuses the process; a
missing *function* in a DLL that does exist gets a stub that only complains when something
calls it (`unimplemented function user32.dll.OnzinA, aborting`).

So a misspelled function name sits quietly until that path is taken. **Exercise every
`winapi` call once in a test** — that is the only thing that catches it.

## The calling convention

x64 Windows, not System V. The first four arguments go in **RCX, RDX, R8, R9**; the rest on
the stack. The caller must also leave **32 bytes of shadow space** and keep the stack
16-byte aligned. `winapi()` does all of that.

What is on you is the **argument count**, and getting it wrong is silent.

Related: use the name form, not a numeric import slot. A hand-computed slot number once
reached `DispatchMessageA` instead of the intended function and read a pointer that was
never passed. A slot number is a magic constant you can get wrong with nothing to catch it.

## WNDCLASSEXA on x64

Offsets with natural alignment, which is what a caller at this level needs:

| offset | size | member | note |
|---|---|---|---|
| 0 | 4 | `cbSize` | **must be 80** on x64 |
| 4 | 4 | `style` | |
| 8 | 8 | `lpfnWndProc` | the window procedure |
| 16 | 4 | `cbClsExtra` | |
| 20 | 4 | `cbWndExtra` | |
| 24 | 8 | `hInstance` | |
| 32 | 8 | `hIcon` | may be 0 |
| 40 | 8 | `hCursor` | 0 means the application sets the cursor itself |
| 48 | 8 | `hbrBackground` | a colour + 1 is allowed instead of a brush |
| 56 | 8 | `lpszMenuName` | may be 0 |
| 64 | 8 | `lpszClassName` | |
| 72 | 8 | `hIconSm` | may be 0 |

**Total: 80 bytes.** Note the padding: `lpfnWndProc` sits at 8 and not at 4, because a
pointer aligns to 8. That is the kind of detail that produces a structure the system rejects
without saying why.

## DRAWITEMSTRUCT on x64, and the field that is not what you expect

Needed for owner-drawn controls — a button you paint yourself rather than letting Windows
draw it.

| offset | size | member |
|---|---|---|
| 0 | 4 | `CtlType` |
| 4 | 4 | `CtlID` |
| 8 | 4 | `itemID` |
| 12 | 4 | `itemAction` |
| 16 | 4 | `itemState` |
| 24 | 8 | `hwndItem` |
| 32 | 8 | `hDC` |
| 40 | 16 | `rcItem` (four 32-bit values) |

**For a button, the identifier is `CtlID` at offset 4, not `itemID` at offset 8.** `itemID`
is for a list or menu item and stays 0 — which draws every button in a grid with the same
label, and looks like a string-buffer bug rather than a wrong offset.

## Sent versus posted: why a message loop is not enough

The obvious hope is that a button click shows up in the message loop, so you could read it
before `DispatchMessage` and never need a window procedure of your own. It does not. From
Microsoft's documentation:

> *Posting* a message means the message goes on the message queue, and is dispatched
> through the message loop (GetMessage and DispatchMessage).
> *Sending* a message means the message skips the queue, and the operating system calls the
> window procedure directly.

A control sends `WM_COMMAND` to its parent with `SendMessage`, which calls the window
procedure directly and returns only when it has been handled. It is never in the queue that
`GetMessage` reads, so no message loop — however written — can see it.

That makes a window procedure unavoidable for anything interactive, and it is why the
language has `winproc`: see [`../internals/callbacks.md`](../internals/callbacks.md).

**The X11 side has no equivalent problem.** There is no window procedure and no callback:
events arrive on the socket and you read them in your own loop. Same application, and one
platform demands a language construct the other never asks for.

## What a minimal window needs

`RegisterClassExA`, `CreateWindowExA`, `ShowWindow`, then the loop: `GetMessageA`,
`TranslateMessage`, `DispatchMessageA`, and `PostQuitMessage` to end it.

That loop dates from 1985 and is still current practice — the abstractions above it (WinUI,
WPF, the Windows App SDK) run a `DispatchMessage` pump underneath rather than replacing it.

## Two things that are not code, and both are required

1. **A manifest.** Windows ships two versions of its controls and gives you the 1995 one
   unless an application manifest asks for version 6. Themed controls are not a flag you
   set; they are a file you ship beside the executable.
2. **A font.** The default for a control is the System font from Windows 95. Anything that
   should look current creates Segoe UI explicitly and assigns it to every control.

## Reference

- [WNDCLASSEXA structure](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-wndclassexa)
- [DRAWITEMSTRUCT structure](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-drawitemstruct)
- [RegisterClassExA](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclassexa)
- [Creating a window](https://learn.microsoft.com/en-us/windows/win32/learnwin32/creating-a-window)
- [Window messages: posted versus sent](https://learn.microsoft.com/en-us/windows/win32/learnwin32/window-messages)
