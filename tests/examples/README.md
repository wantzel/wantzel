# The examples compile

`examples/` is the first Wantzel most people read. A broken example is worse than a
missing one: it teaches a form that does not work, and it is the last place someone
looks for the cause of their own error.

Nothing guarded them until 13-09-2026 — the suite only ever looked inside `tests/`, so
the nine programs in `examples/` could have stopped compiling without a single test
turning red.

`examples_compile.sh` compiles every `examples/*.wz`.

Adding an example costs nothing here: the loop picks it up on its own.

## And three of them are run

`examples_run.sh` goes further for the three that need nothing but a terminal —
`hello.wz`, `primes.wz` and `cat.wz` — and checks what they actually print. Compiling is
not enough on its own: a program can translate perfectly and still print the wrong thing,
and an example that lies is worse than one that is missing. That is not hypothetical.
`hello.wz` greeted the reader in Dutch until 13-09-2026, in the very first program anyone
opens, and nothing noticed.

## And the server is asked a question

`httpd_serves.sh` starts `httpd.wz` on a loopback port and makes real requests: a GET is
answered, the path is echoed back, a second request is served, and a POST is refused with
405. `httpd.wz` calls itself proof that the event loop works, and until this test that
proof rested on the program compiling.

Two details that keep it from becoming the flaky test in the suite. The port is derived
from `$$`, so two runs cannot collide. And the trap kills the forked workers by parent
pid before the parent itself — killing only the parent leaves them holding the socket,
and the next run then fails on a busy port for no visible reason.

The remaining five (`mcpserver`, `mcpbridge`, `mcpfiles`, `mcpoauth`, `mcptools`) speak
MCP and would need a client that implements the protocol. Testing them against our own
client would prove less than it looks: a server that only satisfies the implementation it
ships with has not been tested against the protocol. Their building blocks are covered by
`tests/lib/`.
