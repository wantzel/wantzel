<!-- Thanks for this. A few things that save a round trip. -->

**What this changes, and why**

<!-- The reasoning matters more than the diff: what was wrong, and why this fixes it. -->

**Related issue:**

---

- [ ] `./build.sh` and `./wztest --toolchain` are both green
- [ ] if this touches something `src/wantzel.wz` needs to compile itself,
      `bootstrap/boot.c` implements it too (it only has to build the compiler's
      own source — most changes do not need it; see docs/testing.md)
- [ ] a test comes with the change
- [ ] `docs/changelog.md` has an entry, if this changes the language, the compiler or `lib/`
- [ ] the commits are signed off (`git commit -s`) — see CONTRIBUTING.md
