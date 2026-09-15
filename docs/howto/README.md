# How to do things in Wantzel

Task-shaped documents: you want to build something specific, and this says how.

The other documents answer different questions. [`../internals/`](../internals/) says how the
compiler works and what the design rests on, [`../design.md`](../design.md) argues why the
language is like this, and [`../writing-wantzel.md`](../writing-wantzel.md) is the reference
for the language itself — pitfalls, idioms, and complete program skeletons to take over.

| | |
|---|---|
| [`a-window-on-windows.md`](a-window-on-windows.md) | a native Win32 window with controls that respond, from nothing |
| [`a-window-on-x11.md`](a-window-on-x11.md) | the same on Linux, speaking the X11 wire protocol over a socket |
| [`signing-a-windows-exe.md`](signing-a-windows-exe.md) | getting a freshly compiled `.exe` past SmartScreen and Defender on a managed machine |
| [`background-work-with-fork.md`](background-work-with-fork.md) | doing work in a second process without blocking the first, and cleaning it up |

Both exist because there is no toolkit underneath. That is the trade this language makes:
the binary is measured in kilobytes and there is nothing to install, and the price is that
somebody has to know what the platform actually demands. These documents are that knowledge,
so it only has to be paid once.
