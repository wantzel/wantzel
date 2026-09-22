# The layers of a Wantzel user interface

*Written 17 September 2026, while the middle layer was being designed.*

A program with a window is built in three layers. Naming them is not bookkeeping: it decides
where a piece of work belongs, what it may depend on, and what it must never know.

```
  COMPONENTS    button, list, multi-select, modal, table, text field
  ─────────────────────────────────────────────────────────────────
  RENDERING     smooth text, rounded corners, shadows, measurement
  ─────────────────────────────────────────────────────────────────
  PROTOCOL      socket, window, events, rectangles, glyphs
  ─────────────────────────────────────────────────────────────────
  SYSTEM        syscalls — see two-operating-systems.md
```

Each layer may use the one below it and must not know the one above. A button may ask the
rendering layer to draw a rounded rectangle; the rendering layer must not know that buttons
exist.

## The protocol layer

**What it is.** Opening a connection, creating a window, sending drawing commands, reading
events back.

On X11 that is a Unix socket and a binary protocol: no library, no toolkit, nothing to
install. On Windows it is the window and drawing calls the operating system already
provides. The two are genuinely different and that difference stops here — nothing above
this layer may contain the word `winapi` or the word `syscall`.

**What belongs here:** the connection, the window, the event loop, a rectangle, a run of
glyphs, the clipboard transfer, the keyboard mapping.

**What does not:** anything that knows what it is drawing. A rectangle is a rectangle; that
it happens to be a button is a decision one layer up.

**How you can tell you are in it:** the code contains byte offsets and opcodes, and nothing
else does.

## The rendering layer

**What it is.** Turning a drawing intention into pixels that look right.

This is the layer that decides whether an interface reads as made with care or made in a
hurry, and almost none of it is about windows:

- **text that does not look ragged.** Core X11 fonts have no anti-aliasing at all — that is
  a property of a protocol from 1987, not a setting. Smooth text means rasterising glyphs
  into alpha masks yourself and compositing them, which the RENDER extension does
  server-side once you have uploaded them
- **rounded corners and shadows.** Cheapest as pre-generated assets scaled nine-slice,
  rather than arithmetic on every frame
- **measurement.** How wide is this string in this font? Everything above needs the answer
  and nothing below can give it
- **clipping.** A list that scrolls inside its frame needs the layer to refuse to draw
  outside it

**What belongs here:** the glyph cache, the colour ramp, the corner and shadow primitives,
text measurement, the clip stack.

**What does not:** which colour a *button* is. That is a component's decision, and the
rendering layer offers colours rather than choosing them.

## The component layer

**What it is.** The parts an application is assembled from, so that whoever writes a text
editor, a browser or an administration package never writes a button.

That is the point of this layer stated as a test: **if someone building an application has
to implement a list with selection, the layer has failed.**

**What belongs here:** button, label, text field, list, tree, tabs, menu bar, context menu,
scrollbar, modal, dropdown, multi-select, table, status bar.

**What does not:** anything specific to one application. A menu bar that knows about a
*Build* command is not a component; a menu bar that is given a list of items is.

### Components demand things from below

This is why the layers are worth naming: a component set is not a pile of drawing code. It
needs the layers beneath it to offer specific things, and those are easy to miss until a
component turns out to be impossible.

| a component needs | so the layer below must offer |
|---|---|
| a list that scrolls inside its frame | **clipping** — refusing to draw outside a rectangle |
| a dropdown or modal over the rest | **z-order** — drawing on top, and hit-testing in reverse |
| Tab moving between fields | **focus** — one place that knows who has it |
| dragging that continues off the widget | **mouse capture** — events keep arriving after you leave |
| a blinking caret, a tooltip after a pause | **timers** — an event loop that wakes without input |
| centring a label, fitting a column | **text measurement** |
| a list of ten thousand rows | **redraw regions** — repainting only what changed |

None of these is exotic, and none of them is free. A protocol layer built without clipping
in mind will need it added the day the first list scrolls.

### Two of these are easy to get subtly wrong

**Clipping is needed twice, and the second one is invisible when missing.** Once for
drawing, once for hit-testing. On X11 the drawing half is free — the server takes a clip
rectangle on the graphics context. The hit-testing half is yours, and forgetting it does not
look broken: a button half outside its scrolling frame simply responds to clicks where
nothing is visible. That is the kind of fault that survives for months, because every
screenshot of it looks correct.

A clip *stack* rather than a single rectangle, because panels nest. And a query that answers
"fully outside?" as well as "partly?" — a widget entirely clipped away can be skipped
instead of drawn, which is virtualisation for free.

**Text measurement is the first requirement, not a late one.** Without it there is no
layout, no caret position and no text selection. It has to be a synchronous answer: how wide
is this string, in this font, right now.

### Identity without pointers

Every component needs to be told apart from every other one: which button is hovered, which
field has focus, which tree node is collapsed. In a language with pointers the obvious
answer is the object's address.

There is a better one, and the libraries that have pointers use it anyway: **hash the
identity from the parent and the label.** A 32-bit integer, stable between frames, and it
costs nothing to store in a fixed array.

That is worth stating plainly: a language without pointers is not working around a
limitation here. It is using the mechanism the alternatives converged on, for the reason
they converged on it.

## Immediate or retained

Two ways to build the component layer, and the choice reaches down.

**Retained** (GTK, Qt): components are objects in a tree that survives between frames. The
application builds the tree once and changes it. This needs pointers for parent and child,
function pointers for callbacks, and a heap for the children that come and go.

**Immediate** (Dear ImGui, Nuklear, microui): there is no tree. Every frame the application
calls `button("Save")` and gets back whether it was pressed. State that must persist — which
row is selected, where the caret is — lives in a fixed table keyed by identity.

Wantzel has no heap, no pointers and no function pointers (see
[`no-pointers.md`](no-pointers.md)). That does not make retained mode impossible, but it
does mean rebuilding the parts of C that retained mode leans on.

Immediate mode needs none of them. The tree is the call stack of your own code; the callback
is an `if` after the call; there is no lifetime. What remains is a handful of fixed arrays:
a command buffer, a clip stack, a focus id, a hover id.

**Two prices, worth accepting deliberately rather than discovering later:**

**Layout stays simple.** A widget knows its size only once it has been drawn, so "centre
this against something that does not exist yet" is awkward. The answer is explicit rows and
widths rather than constraints — and taking that simplicity on purpose is better than
building a constraint solver and finding out why nobody does.

**A screen reader has nothing to read.** Assistive technology expects a persistent tree of
elements to walk, and immediate mode does not keep one. That is a real and permanent cost.
It may well be acceptable; it should be a choice.

One thing immediate mode does *not* mean: that the library remembers nothing. Hover, focus,
scroll positions and collapsed nodes all persist between frames. What is immediate is who
owns the application's data — the application — not whether any state exists.

## Keeping the platforms the same

Two operating systems, one look. The rule that makes it hold is simple and it is about
where the decision lives, not about how carefully anyone copies:

**Everything that decides anything is shared; only the drawing differs.**

A menu knows which items it has, how wide it is, and which one the pointer is over. None of
that is platform-specific — it is arithmetic over a list, and it is the same on both. What
differs is the last step: one side hands a rectangle to one API, the other to another.

So a menu lives in two files and one of them is shared:

```
  menu-model    which items, how wide, what is highlighted   shared, tested
  menu-draw     the rectangles and the glyphs                one per platform
```

Two things follow, and they are worth stating because they are what makes the rule work
rather than being a slogan:

**The shared half is testable without a window.** A model that is bytes in and bytes out can
be checked by a test that opens nothing. That is where the arithmetic bugs live, and they
are the ones that are invisible in a screenshot.

**Divergence becomes measurable.** If the shared half is genuinely shared, then a platform
that disagrees is not a matter of opinion: either it reads the same list or it does not.
Without the split, "do these two look the same?" can only be answered by putting screenshots
side by side, and that answer expires immediately.

The failure this prevents is specific: a feature added on one platform and forgotten on the
other. Not because anyone was careless, but because there was no place where the two had to
agree.

## Which layer is this work in?

The question to ask before starting, because it decides everything else:

- **Does it involve bytes on a wire?** Protocol layer.
- **Does it decide what a pixel looks like?** Rendering layer.
- **Would an application author expect it to exist already?** Component layer.
- **Does it know what the application is for?** Not a layer at all — that is the application.

A piece of work that seems to belong in two layers usually belongs in the lower one, with
the upper one asking for it. A button that needs a rounded rectangle does not draw a rounded
rectangle; it asks for one, and then every other component gets the same corner.
