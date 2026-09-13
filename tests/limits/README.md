# Limits of the language and the toolchain (measured)

`limits.sh` proves every limit with a case that just fits and one that just does not.
Measured on 10 September 2026; this table is the source, and the constants live in
`bootstrap/boot.c`/`src/wantzel.wz` (the compiler) and `lib/*.wz` (the library).

| limit | value | what happens above it |
|---|---|---|
| arguments per routine | 10 (an `array of T` counts as 2) | compile error |
| identifier length | 4095 bytes | compile error |
| string literal | 4095 bytes | compile error |
| include depth (`schema`/`tools` count as an include too) | 16 | compile error |
| source files including generated ones | 1024 | compile error |
| source in total (`SRCMAX`, including generated code) | 16 MB | compile error |
| machine code (`CODEMAX`) | 16 MB | compile error |
| data: literals, JSON schemas, tool list (`DATMAX`) | 8 MB | compile error |
| global names (var + const, including schema constants) | 16384 | compile error |
| local names per routine (var + const) | 2048 | compile error |
| routines | 8192 | compile error |
| record types | 1024 | compile error |
| record fields in total | 32768 | compile error |
| names in one declaration | 64 | compile error |
| schemas | 512 | compile error |
| fields per schema | 128 | compile error |
| enum values per schema in total | 1024 | compile error |
| JSON Schema text per schema, and the whole tool list | 1 MB | compile error |
| tools | 1024 | compile error |
| `break`/`continue` per loop nest | 256 | compile error |
| static arrays (bss) | effectively unbounded up to RAM + swap; measured: 8 GB runs, 32 GB segfaults on first touch (Linux, overcommit heuristic) | SIGSEGV, no message |
| stack | 8 MB (`ulimit -s`); about 100,000 levels of recursion with small frames | SIGSEGV, no message |
| `int` | 64-bit, overflow wraps without a check | silent |
| `real` | IEEE double; no trap on ±inf or NaN | silent |
| HTTP (`lib/http.wz`) | 1024 connections, 16 KB request, 64 KB response per connection | connection closed |
| MCP stdio (`lib/mcp.wz`) | 256 KB per message | the process stops |
| tools (`lib/tools.wz`) | 1 MB of result JSON per call | runtime error (bounds) |

The library limits (the HTTP buffers, the MCP message) are constants; they can be raised
later, or replaced by a shared arena.
