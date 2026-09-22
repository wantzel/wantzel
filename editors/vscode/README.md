# Wantzel for VS Code

Highlighting for `.wz` files, compile errors in the Problems panel, and build and run.

## Install

There is no Marketplace release yet. Everything the Marketplace needs is in place --
`tests/toolchain/vscode_package_ready.sh` checks that on every `--toolchain` run -- but
publishing takes an account and a token, which is a person's and not a repository's:

```bash
npm install -g @vscode/vsce
cd editors/vscode
vsce package                    # makes wantzel-0.2.0.vsix, which also installs locally
vsce publish                    # needs a Personal Access Token for the wantzel publisher
```

To use it from this repository without any of that:

```bash
cp -r editors/vscode ~/.vscode/extensions/wantzel.wantzel-0.2.0
```

Then restart VS Code. On WSL the path is the one inside the Linux filesystem.

## What it highlights

The keyword list is taken from the compiler itself (`src/wantzel.wz`), not written by
hand, so it cannot drift from the language: keywords, the built-in types, the word
operators (`div`, `mod`, `shl`, …), the builtins (`len`, `ord`, `chr`, `slen`, …), the
tool attributes (`readonly`, `destructive`, `idempotent`), comments, strings, and numbers
including hex and reals.

Two details that a Pascal grammar gets wrong here:

- **Names may contain dots.** `store.set` is one identifier, not a field access, so the
  word pattern includes `.`.
- **Everything is case-insensitive**, keywords included, so every pattern is too.

## Build and run

Open a `.wz` file and the extension offers two actions, with no `tasks.json` to write:

| | | |
|---|---|---|
| **Wantzel: Build** | Ctrl+Shift+B | compile the file in front of you |
| **Wantzel: Run** | Ctrl+F5 | compile it, and run it if the compile succeeded |

Both also appear in the Command Palette and as buttons in the editor title bar. The binary
is written beside the source, named after it: `hello.wz` produces `hello`. Run is one task
rather than two so that a failed compile cannot run a stale binary.

A project with a `build.sh` also gets **Wantzel: build (all)** in the task list.

**Run > Run Without Debugging** works too, and runs the same build. VS Code's Run menu is
its debug system, so a language it knows nothing about leaves those entries grey; the
extension contributes a launch configuration that compiles first and then runs the binary
in the terminal. There is no debugger for Wantzel and this does not pretend there is one --
no breakpoints, no stepping. Run and Start Debugging do the same thing.

### Which compiler it uses

In order: the setting `wantzel.compilerPath` if you set one, otherwise the nearest
`bin/wantzel` found by walking up from the file you are compiling and then from the
workspace root, otherwise `wantzel` on the `PATH`.

Walking up matters when the folder you opened *contains* the checkout rather than *being*
it. Looking only at the workspace root found nothing in that case and fell through to the
`PATH`, where a compiler that was sitting one directory down went unnoticed.

## Compile errors in the Problems panel

The compiler reports `wantzel: <file>:<line>: <message>` and nothing else, so no parsing
code is needed — the extension contributes a problem matcher named `wantzel`, and the build
and run tasks above already use it. An error lands on its own line in Problems.

There is no column in the message, so a problem marks a whole line. That is the compiler's
format, not a limitation of the matcher.

If you would rather write the task yourself, the matcher is available as `$wantzel`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "wantzel: compile this file",
      "type": "shell",
      "command": "${workspaceFolder}/bin/wantzel",
      "args": ["${file}", "${fileDirname}/${fileBasenameNoExtension}"],
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": "$wantzel",
      "presentation": { "reveal": "silent" }
    }
  ]
}
```

## What is not here, and why it stays that way

**This extension is deliberately compact: highlighting, errors, build and run.** Three
things, and it is not meant to grow past them. An editor plugin that keeps acquiring
features ends up a half-built IDE that nobody maintains, and each addition here would be a
second implementation of something the compiler or a real editor already does better.

- **Snippets** were dropped in 0.2.1. The complete working programs live in
  [`docs/writing-wantzel.md`](../../docs/writing-wantzel.md), where a test compiles them on
  every run and where they are found by anyone, not only by a VS Code user.
- **Jump to a declaration** needs a language server or at least a symbol index.
- **Formatting**: there is no formatter for Wantzel and none planned, so there is nothing
  to call.
- **A debugger.** Run Without Debugging compiles and runs; Start Debugging does the same.
  Breakpoints and stepping need a debug adapter, which is a project of its own.
