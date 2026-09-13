<!-- Thanks for this. A few things that save a round trip. -->

**What this changes, and why**

<!-- The reasoning matters more than the diff: what was wrong, and why this fixes it. -->

**Related issue:**

---

- [ ] `./build.sh` and `./wztest --toolchain` are both green
- [ ] `src/wantzel.wz` and `bootstrap/boot.c` are in step (they are counterparts — a
      compiler change touches both, or the bootstrap fixed point breaks)
- [ ] both targets are covered, Linux and Windows
- [ ] a test comes with the change
- [ ] if this adds a keyword: `editors/vscode/syntaxes/wantzel.tmLanguage.json` knows it
- [ ] `docs/changelog.md` has an entry, if this changes the language, the compiler or `lib/`
- [ ] the commits are signed off (`git commit -s`) — see CONTRIBUTING.md
