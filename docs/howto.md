# How-to

**Short recipes for specific tasks: a goal, the steps, and the pitfalls.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

Task-shaped, not reference-shaped: you want to build one specific thing, and each section
says how. [`design.md`](design.md) explains why the language and compiler work the way they
do; [`writing-wantzel.md`](writing-wantzel.md) is the reference for pitfalls and idioms.

There is no toolkit underneath any of this — the binary is kilobytes and nothing installs,
and the price is that somebody has to know what the platform demands. That knowledge is
below, so it only has to be paid once.

## Background work with fork

`fork` needs no compiler change: `sys1`/`sys2`/etc. are builtins that translate straight to
the SYSCALL instruction (two bytes: `0x0F 0x05`), and `SYS.fork`/`SYS.wait4` are ordinary
constants in `lib/io.wz`. On Windows the same call goes through a shim instead of the raw
instruction — the only platform difference here.

```pascal
pid := sys1(SYS.fork, 0);
```

| | in the parent | in the child |
|---|---|---|
| return value | the child's pid (`> 0`) | `0` |
| on failure | `< 0` (`-errno`) | — |

`fork` copies the whole process: code, data, open file descriptors, program counter. From
there the two diverge.

**What goes wrong, roughly by frequency:**

| problem | fix |
|---|---|
| the child dies without writing anything (segfault, `halt`, OOM) | give every task a status that separates "started" from "finished"; treat a non-zero exit as failed |
| nobody reaps the child | reap periodically with `wait4(..., WNOHANG)` inside your existing event loop |
| two processes write the same store | strict division: the child writes only its own row, created by the parent before forking |
| the child inherits open connections | close what you do not need, first thing in the child |
| the task does not survive a restart | mark every "busy" task "aborted" at startup |

**Limits:**

| limit | value | symptom |
|---|---|---|
| processes per user | `ulimit -u` | `fork` returns `-EAGAIN` |
| memory | copy-on-write | OOM killer |
| file descriptors | inherited, `ulimit -n` | `accept` fails |
| zombies | until the process table is full | `fork` returns `-EAGAIN` |

The practical limit is almost always simultaneous task count, not memory — cap it and refuse
cleanly above the cap; five lines.

`http.serve(port, workers)` also forks, but statically: *n* processes made once at startup,
each with its own listening socket on `SO_REUSEPORT`, the kernel distributing connections.
That does not conflict with per-task forking, but **each worker reaps only its own
children** — a task started in worker 3 can only be reaped there, so an answer read by
worker 1 must come from disk, not memory.

**Killing a background process is not the same as knowing it is gone:**

- `kill` is a request, not a confirmation — follow with `wait` (only works on your own
  children), then poll `kill -0`, then `kill -KILL` if still alive.
- Track a list of pids, not one variable — an overwritten variable silently forgets the first.
- A shell `trap` does not fire if the shell dies under a timeout, or the child outlives the
  shell; a cleanup keyed to something unique to the run (e.g. its temp directory) catches
  what the trap misses.
- PPID tells you how an orphan got there: PPID 1 means started as a daemon; the session
  leader's PPID means adopted after the real parent died.
- "Memory does not come back" has several causes — split `Cached` (reclaimable) from
  `AnonPages` (not) in `/proc/meminfo`, and sum `ps -eo rss=,comm=` per command to find the
  real owner.

Not here, deliberately: threads (a language change, and unneeded — processes with no shared
state do the same job); `posix_spawn`/`vfork`/`clone` (reachable through `sysN` if ever
needed, `fork` is the one that was measured); signals (a child that must stop cleanly is
killed and its row marked, there is no handler).

## Serving HTTPS

Three situations, three different answers — work out which one you are in before reaching
for a certificate.

| where your program runs | what it needs |
|---|---|
| own machine, reached as `localhost` | a self-signed certificate, or no TLS at all |
| behind a tunnel (ngrok, Cloudflare, tailscale) | nothing — the tunnel terminates TLS |
| public address, real name | Let's Encrypt, and the program gets it itself |

**1. Localhost.** Let's Encrypt cannot issue for `localhost`, `127.0.0.1`, `.local`,
`.internal`, or private ranges (10.x, 192.168.x, 172.16–31.x) — ACME proves control of a
*public* name, and none of those are one. Traffic on loopback never leaves the machine, so
not using TLS is often the right answer there. Otherwise, self-sign in-process with
`lib/csr.wz`:

```pascal
include "csr.wz";
include "tls.wz";

p256.setup;
hn := io.push(host, 0, "localhost");
if not p256.genkey(d, qx, qy) then ...          // a fresh key
csr.setvalidity(io.realtime div 1000000000, 10); // ten years
if not csr.selfsign(host, hn, d, qx, qy) then ...
if not tls.setcert(csr.buf, csr.n, d) then ...   // and serve with it
```

Ten years, because nothing re-checks this and an expiry only creates an outage on a machine
talking to itself. Browsers will still warn — nothing vouches for a self-signed certificate,
correctly. `examples/localhttps.wz` is the full working version.

**2. Behind a tunnel.** TLS ends at the tunnel edge; your program never sees it:

```
browser --TLS (provider's certificate)--> tunnel edge --plain--> your program
```

No certificate needed, at the cost of the provider seeing your traffic in the clear and an
address that usually changes per session. A tunnel is a development tool, not a production
answer — except one configured to re-encrypt to you (Cloudflare "Full (strict)"), which puts
you back in case 3.

**3. A public address.** Real name, A record, ports 80 and 443 reachable — ACME works and the
program does it itself: no certbot, no cron, no reverse proxy. See `examples/serve.wz`. The
challenge arrives on port 80 while your server already listens there; renewal runs on a timer
in the same event loop; the key stays in memory, disk is only a cache. **HTTP-01, not
DNS-01** — DNS-01 needs API credentials for your DNS provider (a dependency this stack
avoids) and is only required for a wildcard certificate.

`ch.addsystem` must be called before any of this trusts a peer: it reads the machine's bundle
(`/etc/ssl/certs/ca-certificates.crt`) or falls back to two built-in roots (ISRG Root X1/X2)
on a scratch container with none. `lib/tls.wz` never calls it itself, so including it trusts
nothing quietly — an empty trust store leaves `tls.verified` false rather than waving a peer
through.

## Signing a Windows exe

A freshly compiled, unsigned `.exe` is blocked on a managed Windows 11 machine by two
separate layers:

| message | title | solution |
|---|---|---|
| ASR (Defender Exploit Guard) | "Action blocked", only **Close** | a trusted signature, or an administrator's folder exclusion |
| SmartScreen | "Windows protected your PC", **More info → Run anyway** | a trusted signature helps reputation; "Run anyway" also works |
| SmartScreen set to Block | same title, **no** More info, only **Don't run** | only a trusted, recognised publisher — no manual bypass |

Not specific to Wantzel — ASR judges reputation, not content, so an unsigned hello-world from
any compiler hits the same wall. Only a **signed** exe shows a known publisher; always test
with a signed one from `bin/`.

**Step 1 — sign.** From Linux (WSL) with `osslsigncode`:

```bash
sudo apt install osslsigncode      # once
./signexe.sh bin/hello.exe          # self-signed, in place
```

First run creates `~/.wantzel-sign/`: `wantzel.crt` (import on Windows), `wantzel.key`
(stays local), `wantzel.pfx` (Windows-friendly form). On Windows, as administrator:

```powershell
.\sign-windows.ps1 -Exe .\bin\hello.exe
```

Two common failures: **execution policy** blocks the `.ps1` — run
`powershell -ExecutionPolicy Bypass -File .\sign-windows.ps1 -Exe .\bin\hello.exe`, or set it
once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. **Not administrator** — the
script writes `LocalMachine\Root` and `TrustedPublisher`, which needs an elevated shell;
without it, trusting fails silently and ASR blocks the exe anyway.

**Step 2 — trust the certificate**, in the **local computer** stores (`certlm.msc`, not
`certmgr.msc`), in both:

- **Trusted Root Certification Authorities** — makes the signature chain valid.
- **Trusted Publishers** — makes the publisher "known".

Import only the Wantzel Self-Signed certificate; leave your organisation's own alone. Verify
by comparing the certificate's SHA-1 thumbprint against what `signexe.sh` printed (or
`openssl x509 -in ~/.wantzel-sign/wantzel.crt -noout -fingerprint -sha1`).

**Step 3 — run it.** Runs clean: the chain works. SmartScreen still names "Wantzel
Self-Signed" and offers More info: signature recognised, only reputation complains — click
**Run anyway** once. Still unknown or hard-blocked: certificate is not in the Local Machine
stores, or Windows has not noticed yet — log out/in or restart, and confirm you used
`certlm.msc`.

**Known weaknesses of self-signing:** `signexe.sh` timestamps against
`timestamp.digicert.com` by default so the signature outlives the certificate (falls back to
unsigned-timestamp offline); reputation stays at zero until "Run anyway" or a public EV
certificate; trust is local to the machine where you imported it.

**If it still does not work**, some organisations enforce ASR/SmartScreen through MDM tightly
enough that a local self-signed certificate does not count — ask your administrator to roll
it out by policy or add a folder exclusion, or test in Windows Sandbox instead (below). For a
release to others, submit the exe as a false positive at
[Microsoft's Security Intelligence portal](https://www.microsoft.com/en-us/wdsi/filesubmission).

### Windows Sandbox: a clean Windows, no ASR

A disposable Windows, built in, with none of the ASR policy that blocks unsigned exes.

**Enable once** (Windows 10/11 Pro/Enterprise, virtualisation on in BIOS), elevated
PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All
```

Restart; "Windows Sandbox" then appears in the Start menu.

**Do not run an exe straight from a mounted `\\wsl.localhost` share** — it gives "Access
denied", either because execute is blocked over the VirtIO share, or because a file written
via `/mnt/c` carries an ACL `WDAGUtilityAccount` cannot reach. The way that works: zip on the
host, unpack inside the sandbox onto a local disk.

```sh
cd ~/wantzel
for e in hello cat primes httpd mcpfiles; do ./bin/wantzel examples/$e.wz /tmp/$e.exe; done
( cd /tmp && zip -j wantzel-exes.zip hello.exe cat.exe primes.exe httpd.exe mcpfiles.exe )
cp /tmp/wantzel-exes.zip /mnt/c/wantzel-share/
```

```powershell
Expand-Archive C:\Users\WDAGUtilityAccount\Desktop\wantzel\wantzel-exes.zip C:\wantzel -Force
cd C:\wantzel
.\hello.exe
```

Networking is on inside the sandbox, so `httpd.exe`/`mcpfiles.exe` work too. The included
`win-sandbox.wsb` mounts a host folder onto the sandbox desktop — set `HostFolder` in it
first.

### Distribution: which certificate for what

Building is free; what costs money is *trust* on someone else's machine:

| goal | certificate | cost | works |
|---|---|---|---|
| own machines, testing | self-signed (`signexe.sh`) | free | only after importing; not on managed devices |
| managed work device | IT rollout, or folder exclusion | — | only if your administrator allows it |
| selling, wide audience | OV from a public CA | ~200–400/year | everywhere, once reputation builds |
| selling, no SmartScreen hurdle | EV from a public CA | ~350–700/year | everywhere, clean immediately |

Since June 2023 a public code-signing key must live on hardware (USB token or cloud HSM) —
no more `.pfx`, so you sign on Windows with the token plugged in:

```powershell
.\sign-release.ps1 -Exe .\bin\hello.exe
```

That runs `signtool sign /fd sha256 /tr <timestamp> /td sha256 /a <exe>` — `/a` picks the
token's certificate automatically, `-Thumbprint` targets a specific one. EV removes the
SmartScreen warning immediately; OV builds reputation over downloads. Sign an installer
(Inno Setup, WiX/MSI) the same way, both the installer and the exes inside it.
