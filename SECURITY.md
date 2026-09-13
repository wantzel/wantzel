# Security

## Reporting a vulnerability

Please do not open a public issue. A public report is a working recipe for anyone reading
it, and there is no way to take it back.

Use **[GitHub's private vulnerability reporting](https://github.com/wantzel/wantzel/security/advisories/new)**
— the "Report a vulnerability" button under the Security tab. It creates a private thread
between you and the maintainer.

Expect an acknowledgement within a few days. This is a one-person project, so please allow
a reasonable window to fix something before publishing it.

## What counts

Wantzel compiles source into a static executable, so the interesting cases are where it
produces something other than what the source says, or where the parts of `lib/` that face
a network mishandle what arrives:

- The compiler generating code that does not match the program's meaning — a bounds check
  that is skipped, a conversion that silently changes a value.
- A crafted source file making the compiler read or write outside its own buffers.
- A buffer overrun in `lib/http.wz`, `lib/json.wz`, `lib/oauth.wz` or `lib/mcp.wz`
  reachable from input arriving over a socket.
- Authentication in `lib/oauth.wz` accepting something it should refuse.

Worth knowing before you report: **the language deliberately has no exceptions, and an
integer overflow wraps silently.** A program that stops with
`runtime error: array index out of range` is the language working as specified, not a
vulnerability. The documented limits are in [tests/limits/README.md](tests/limits/README.md).

## Versions

Wantzel is before 1.0 and only the latest release gets fixes. There are no backports.
