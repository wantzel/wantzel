# Wantzel for VS Code

Syntax highlighting for `.wz` files.

## Install

There is no marketplace release yet. To use it from this repository:

```bash
cp -r editors/vscode ~/.vscode/extensions/wantzel-0.1.0
```

Then restart VS Code. On WSL the path is the one inside the Linux filesystem.

## What it highlights

The keyword list is taken from the compiler itself (`src/wantzel.wz`), not written by
hand, so it cannot drift from the language: keywords, the built-in types, the word
operators (`div`, `mod`, `shl`, …), the builtins (`len`, `ord`, `chr`, `slen`, …), the
tool attributes (`readonly`, `destructive`, `idempotent`), both comment forms, strings,
and numbers including hex and reals.

Two details that a Pascal grammar gets wrong here:

- **Names may contain dots.** `store.set` is one identifier, not a field access, so the
  word pattern includes `.`.
- **Everything is case-insensitive**, keywords included, so every pattern is too.
