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

## Installing the compiler

One file, downloaded; nothing to build and nothing else to install:

```sh
curl -fsSLO https://github.com/wantzel/wantzel/releases/latest/download/wantzel-linux-x86_64
curl -fsSLO https://github.com/wantzel/wantzel/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS                  # wantzel-linux-x86_64: OK
mv wantzel-linux-x86_64 wantzel && chmod +x wantzel
./wantzel --version
```

The file is the compiler and the whole standard library: `import io;` works with nothing
beside it, `./wantzel --lib` lists the modules and `./wantzel --lib io` prints one. A
specific release instead of the newest is `.../releases/download/v<version>/wantzel-linux-x86_64`.
Several versions side by side are several files — `wantzel --version` says which one you
have, and its library cannot come from anywhere else. Building it yourself from a clone is
in the README (*Build from source*).

## Background work with fork

`fork` needs no compiler change: `sys1`/`sys2`/etc. are builtins that translate straight to
the SYSCALL instruction (two bytes: `0x0F 0x05`), and `SYS.fork`/`SYS.wait4` are ordinary
constants in `lib/io.wz`.

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
import csr;
import tls;

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
program does it itself: no certbot, no cron, no reverse proxy, no second process. A server on
`lib/http.wz` needs one call more than a plain one:

```pascal
import http;

procedure app.request;
begin
  http.add("hello over https\n");
  http.finish(200, "text/plain");
end;

begin
  // the name, a contact address, where the certificate is kept, staging or not
  http.https("www.example.com", "you@example.com", "/var/lib/hello/certs", true);
  http.serve(443, 1);
end.
```

```bash
./bin/wantzel hello.wz hello
sudo ./hello        # ports 80 and 443; or grant the binary cap_net_bind_service
```

Try it against **staging** first (the `true`) — its certificates are not trusted by browsers,
but its rate limits are generous; change it to `false` for a real certificate. The
authority's address is found through DNS (`lib/dns.wz`, with the machine's nameservers).
`examples/autocertd.wz` is the same server with command-line options for every setting.

What the program does, in one loop:

- **At start** it opens both ports, then reads the store (here `/var/lib/hello/certs`; `""`
  means `certs/` beside the binary). A certificate that is for this host, matches its key and
  has more than 30 days left is served at once and **not** ordered again — so restarts are
  free, which matters: Let's Encrypt limits certificates per name per week.
- **Port 80** never serves the application. It answers the authority's
  `/.well-known/acme-challenge/<token>` from memory while an order is pending, redirects
  everything else to `https://` (`301`, or `308` for a method other than GET and HEAD) once a
  certificate is installed, and says `503` before that.
- **The order** runs one HTTPS request per loop turn, so port 80 keeps answering between
  them — the authority fetches the token while the order is pending.
- **The certificate** gets a new key, is checked before use (right host, our key, in date,
  each link of the chain signed by the next), saved with its key in one atomic write, and
  installed with its intermediate. The next handshake uses it; nothing restarts.
- **Renewal** is checked daily and happens when fewer than 30 days are left.
- **When the authority fails** the current certificate stays in service, and the next attempt
  comes after 1 h, 6 h, then every 24 h. The schedule is stored, so a restart does not retry
  early.

TLS terminates in that same loop, for many clients at once: each connection's session is fed
the bytes that arrived, so a handshake advances as its records come in, and a client that
stalls halfway holds only its own connection until the header deadline closes it. A renewed
certificate goes in while connections are open: the next handshake uses it, open connections
carry on. For development without an authority, `http.httpsfiles("cert.pem", "key.pem")`
serves a certificate from files on any port; the details are in
[library.md](library.md#http--a-non-blocking-http11-server-on-epoll).

The log is one line per step on stderr, and says what is served and when the next attempt
is:

```
autocert: www.example.com: certificate loaded from the store, valid until 2026-12-01 (68 days left)
autocert: www.example.com: renewing: 29 days left
autocert: www.example.com: order failed: the authority did not answer in time; the current certificate stays in use; next attempt in 1 h
```

**HTTP-01, not DNS-01** — DNS-01 needs API credentials for your DNS provider (a dependency this
stack avoids) and is only required for a wildcard certificate.

**Every request to the authority is verified HTTPS.** `autocert.start` fills the trust store
with `ch.addsystem` when the program has not put roots in it: the machine's bundle
(`/etc/ssl/certs/ca-certificates.crt`), or two built-in roots (ISRG Root X1/X2) on a scratch
container with none. A connection whose certificate does not chain to one of them is refused,
not used. For a private ACME authority, give its root with `--ca <file.pem>` — then that root
is the whole trust store. `lib/tls.wz` never fills the store itself, so including it trusts
nothing quietly.

## Reaching a server by name

`net.connect` takes four numbers; `lib/dns.wz` turns a name into them. Pick the form by
where the call sits:

| where | call |
|---|---|
| a command-line tool, or start-up | `fd := dns.connect("example.com", 443)` — resolve, then connect to the first address that accepts |
| you want the addresses | `n := dns.resolve("example.com", addrs)` — blocks for at most the lookup's total time, 5 s |
| inside an event loop | `q := dns.start(name)`, `dns.fd` in your epoll set, `dns.poll(q, addrs)` after each wake — nothing blocks |

In an event loop a blocking lookup stops every other connection for as long as the
nameserver takes, so a server that looks something up while it serves uses the third form —
unless the lookup is rare and its stop bounded: `lib/autocert.wz` resolves the authority with
`dns.resolve` for each of the handful of requests an order makes, every two months or so. `dns.wait` is the timeout to hand
`epoll_wait`, so a lookup whose server went silent still moves on in time:

```pascal
if not net.watch(ep, EPOLL_ADD, dns.fd, EPOLLIN) then ...   // once
q := dns.start("acme-v02.api.letsencrypt.org");
...
n := net.wait(ep, addr(ev[0]), 64, dns.wait);                // -1 when nothing is pending
n := dns.poll(q, addrs);          // DNS.PENDING (0), a count, or a DNS.* code
```

Pitfalls:

- **The connect after the lookup is a separate step.** `dns.connect` resolves and then calls
  `net.connect`, which blocks; in an event loop, resolve with `dns.start`/`dns.poll` and
  connect however your loop connects.
- **Say which failure it was.** `dns.error(code)` gives a sentence; `DNS.NXDOMAIN` (no such
  name) and `DNS.TIMEOUT` (nobody answered) are different problems with different fixes.
- **Test against a server of your own.** `dns.noservers` and `dns.addserver(127, 0, 0, 1,
  port)` replace the system's nameservers, so a test never depends on the network —
  `tests/lib/dns.sh` does exactly this.
