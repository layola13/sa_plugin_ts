# AGENTS.md — sa_plugin_ts

## Scope
This file covers the entire `sa_plugin_ts` plugin project.

## Architecture Notes

### Plugin System Compliance
- Follows the standard SA plugin pattern defined in `sci/docs/pluginssytem.md`.
- Uses shared `plugin_api.zig` / `plugin_helpers.zig` (copied from `sa_plugin_http_client`).
- Exports `saasm_plugin_descriptor_v1` + `_fn` with `handle_command` for CLI invocation.
- Skills metadata registered for host discovery.
- All errors reported via `plugin_api.emitLog`.

### Build
- `zig build` produces `libsa_plugin_ts.so`.
- `zig build test` runs all 26 tests (all pass).
- Plugin API is imported as a module in `build.zig`.

### Source Layout
- `src/plugin.zig` — Plugin entry, descriptor, C-ABI exports, CLI handler, 26 tests.
- `src/lexer.zig` — 30+ keywords, zero-copy scanning, SIMD-optimized whitespace skip, line:col tracking, template literal chunk scanning.
- `src/parser.zig` — Pratt expression parser, LayoutTable, ScopeManager, stdlib mapping (static + dynamic), arrow closure synthesis, generic type parameters, for-of iteration, template literals, module import/export, WIT imports, error recovery.
- `src/lowerer.zig` — Thin string-based emitter for SA-ASM output.
- `src/scope.zig` — Lexical scope stack with heap variable tracking and automatic `!` release.
- `src/plugin_api.zig` — Standard SA plugin ABI types (shared across plugins).
- `src/plugin_helpers.zig` — C-argv conversion and stream writer helpers (shared).

## Standard Library Mapping

### fs module (`import { ... } from "fs"`)
| TS Function | SA Primitive | String Args |
|---|---|---|
| `readFile` | `@sa_fs_read_file` | path |
| `writeFile` | `@sa_fs_write_file` | path |
| `open` | `@sa_fs_file_open` | path |
| `create` | `@sa_fs_file_create` | path |
| `close` | `@sa_fs_file_close` | — |
| `remove` | `@sa_fs_remove_file` | path |
| `mkdir` | `@sa_fs_make_dir` | path |

### net module (`import { ... } from "net"`)
| TS Function | SA Primitive | String Args |
|---|---|---|
| `tcpConnect` | `@sa_net_tcp_connect` | host |
| `tcpListen` | `@sa_net_tcp_listener_bind` | host |
| `tcpAccept` | `@sa_net_tcp_listener_accept` | — |
| `tcpRead` | `@sa_net_tcp_stream_read` | — |
| `tcpWrite` | `@sa_net_tcp_stream_write` | — |
| `tcpClose` | `@sa_net_tcp_stream_close` | — |

String args auto-expanded from TS string structs (ptr+len) into SA pointer+length pairs.

## Feature Summary

### Language Features
- Interfaces with static byte-offset layout
- Generic type parameters (Box<T>, Map<K,V>) — base name used for layout lookup
- Enums with auto-numbered variants
- Type aliases
- Arrow function closures (static defunctionalization with context struct)
- Template literals (`text ${expr} text`) with concat emission
- for-of iteration over arrays
- Module import/export (local .ts/.sa files, .wasm, .wit)

### Parser
- Pratt expression parser with correct left-associativity (<= comparison)
- 6 precedence levels: or, and, comparison, sum, product, call
- Postfix ++ and --
- Unary negation and logical not
- Error recovery: collects multiple errors, skips to sync points

### Lexer
- 30+ keyword tokens
- SIMD-optimized whitespace scanning (@Vector(16, u8) batch processing)
- SIMD-optimized comment scanning
- Template literal chunk scanning (template_start/mid/end)
- Line:col tracking for all tokens

## Design Decisions
- Arrow closures: captured variables packed into context struct, standalone callback loads from context pointer.
- Stdlib mapping: dynamic ArrayList entries (from parseImport) + static inline fallback table.
- Generic types: base name stripped of `<...>` for layout table lookup.
- Template literals: lexer produces template_start/mid/end; parser switches to nextTemplateChunk mode.
- Context struct aligned to 8 bytes (pointer alignment).
- `^ctx` (move) semantics for passing context to callbacks.

## Coding Conventions
- All Zig code follows standard formatting.
- No external dependencies beyond Zig stdlib.
- Tests are inline in `src/plugin.zig`.
- Error messages include `line:col`.
