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
- `zig build` produces `libsa_plugin_ts.so`. Use the default (Debug) build: raw optimized builds (`-Doptimize=ReleaseSmall/Safe/Fast` without `SA_PLUGIN_DEV=1`) still crash at load with a host `lock` segfault; this reproduces on the pristine tree without any CLI changes, so it is a pre-existing defect, not a regression from the `test`/`build-exe` work. `build.zig` mirrors sa_plugin_sla's compilation plumbing verbatim: `effectiveOptimizeForDevInstall` (ReleaseFast + `SA_PLUGIN_DEV=1` forces Debug, so `sa plugin install --dev` installs the tested Debug artifact), `test-filter` build option, `linkHostSystemLibs` (ws2_32/iphlpapi on Windows) on lib + tests, and `sap.json` installed to `lib/sap.json`.
- `zig build test` runs all 40 tests (all pass; the runtime table holds 23 node-verified expectations).
- `tools/verify_e2e.sh` lowers a corpus of TypeScript and runs `sa build` on the
  result. Run this after any change to emission: the Zig tests only assert on
  substrings and cannot catch an instruction the assembler rejects.
- `tools/verify_cli.sh` covers the CLI surface (24 checks: help/skills output,
  arg validation, `init` scaffold, `sa.mod` workspace fallback, `build-exe` /
  `test` delegation). Run it after any change to `handle_command` or `sap.json`.
- Plugin API is imported as a module in `build.zig`.

### Dev install and test
- `SA_PLUGIN_DEV=1 sa plugin install --dev .` installs in seconds and now works end to end: the build.zig downgrade forces the Debug artifact, so the installed plugin no longer segfaults in the host `lock` on first dispatch (verified 2026-09-28: `ts check`/`build-exe`/`test` via the installed path, plus a 256-demo installed-path sweep: 255 pass, 1 refused-with-diagnostic, 0 fail).
- The old manual workaround (`zig build` Debug, then copy `zig-out/lib/libsa_plugin_ts.so` over `~/.local/share/sa_plugins/installed/sa_plugin_ts/current/` and `0.1.0/`) is no longer needed.
- Day-to-day dev testing does not need the install at all: the verify scripts
  set `SA_PLUGINS_PATH=$PLUGIN_DIR/zig-out/lib` and exercise the Debug build
  directly (they export `SA_PLUGIN_DEV=1` like sa_plugin_sla's sweep scripts,
  since `zig-out/lib` now ships `sap.json` and the host requires dev mode).
- `sa build` linking needs `XDG_CACHE_HOME=/tmp/xdg` in this container (the
  default cache is ReadOnlyFileSystem and `zig cc` fails without it).

### Testing caveat
The inline tests match substrings of the lowerer output. That is necessary but
not sufficient: it cannot tell a valid instruction from a plausible-looking
invalid one. Every bug fixed in the SA-ASM emission layer (`jz`, missing return
types, `break`/`continue`/`throw` as instructions, offsetless `load`/`store`)
passed all substring assertions. `tools/verify_e2e.sh` is the guard.

## SA-ASM Emission Rules

The lowerer targets SA-ASM, whose instruction set differs from what the TS
syntax suggests. Getting these wrong yields output that looks right and fails
to assemble.

- Conditional branch: `br <cond> -> <true_label>, <false_label>`. There is no
  `jz`, and both targets are mandatory.
- Unconditional jump: `jmp <label>`. `break` and `continue` are not
  instructions; they lower to `jmp` at the enclosing loop/switch label, tracked
  on `break_stack` / `continue_stack`.
- There is no `throw`. It lowers to `panic`, which aborts.
- A value-returning function needs `-> T:` in its signature. Without it the
  backend fails with "Instruction has a name, but provides a void value".
- Every basic block must end in a terminator, and nothing may follow one. The
  `Lowerer` tracks this via `block_terminated` and suppresses dead code.
- `load` and `store` require an explicit byte offset: `load r + 0 as i32`.
- Labels are emitted lazily. `useLabel`/`reserveLabel` mark branch targets, and
  `emitLabel` drops unreferenced ones — which is what keeps an unreachable
  if/else merge block (and its duplicated register releases) out of the output.
- Every live register must be released with `!` before the function exits,
  parameters included. A release must be emitted *before* the terminator that
  leaves the value's scope, never after it, or it becomes unreachable code.
  `return` and function exit release every open scope via
  `releaseAllOwnedExcept`; `break`/`continue` release only the scopes deeper
  than the jump target's recorded `scope_depth`; a block closing inside a branch
  arm or loop body releases its own scope via `exitScopeReleasingLocals`. A
  register moved by a register-to-register assignment is not released
  afterwards, and `Variable.is_released` keeps the walks idempotent.

### Source Layout
- `src/plugin.zig` — Plugin entry, descriptor, C-ABI exports, CLI handler (`lower`/`check`/`build`/`build-exe`/`test`/`init`/`skills`/`help`), 39 tests (38 substring/structural + 1 runtime table with 23 node-verified expectations: lower in-process, `sa build`, run, assert exit status). `[file]` is optional with `sa.mod` workspace fallback (`-p name`/`-p=name`/`--package=name`); `test`/`build-exe` lower to a temp `.sai` and delegate to `sa` (`sa test` / `sa build-exe <tmp.sai>`, extra args passed straight through, `--jobs auto` appended) via `resolveSaExecutable` (SA_EXE > SCI_ROOT dev layout > host dir > PATH), like `sa_plugin_sla`; needs `link_libc` (see `build.zig`) for `Child.spawn` env inheritance. `init` scaffolds `sa.mod` + `src/main.ts` + `.gitignore` and never overwrites.
- `src/lexer.zig` — 30+ keywords, zero-copy scanning, SIMD-optimized whitespace skip, line:col tracking, template literal chunk scanning.
- `src/parser.zig` — Pratt expression parser, LayoutTable, ScopeManager, stdlib mapping (static + dynamic), arrow closures with parameters, generic type parameters, for-of iteration, template literals, module import/export (WASM arity-matched externs, WIT refusal), error recovery.
- `src/lowerer.zig` — SA-ASM emitter. Records a CFG (`edges`, filled by
  `emitBranchTo`/`emitJumpTo` plus an implicit fallthrough edge) and provides
  `computeDominators`, an iterative immediate-dominator analysis returning a
  reachability matrix. The matrix is **not consulted during emission**:
  `src/scope.zig`'s `dominatesWith` receives a null matrix and applies
  "entry block dominates everything, any other block dominates only itself",
  which is sound and avoids the analysis vetoing a required release. The
  `refreshDominators` call the switch-case path used to make was removed for
  that reason. A branch to a not-yet-written label is recorded as a label index
  that resolves to serial `index + 1`.
- `src/lowerer.zig` — SA-ASM emitter. Owns basic-block well-formedness:
  terminator tracking, lazy label emission with reference counting, and a
  capture mode used to defer a `for` increment clause past the loop body.
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
- Arrow function closures with parameters (static defunctionalization, out-of-line callbacks, per-arrow context registers, `let f = (x) => ...` aliases; direct calls borrow `ctx`, higher-order passing moves `^ctx`)
- Template literals: a plain literal (`` `text` ``) lowers to an SA string
  slice; interpolated forms (`` `text ${expr}` ``) lower too — integer
  operands go through `sext` + `@sa_fmt_i64_into`, string operands pass
  through, chunks join with `@sa_string_concat`. Booleans render as 0/1.
  Float/other operands are refused with a located diagnostic. See Known Gaps.
- for-of iteration over arrays
- `console.log(...)` lowers to `@sa_print_bytes` (`sa_std/io/print.sai`, the
  sla `emitPrintln` shape): each operand normalises to a text slice via the
  interpolation renderer (strings pass through, integers via `sext` +
  `@sa_fmt_i64_into`, booleans as 0/1), args join with a space, trailing
  newline. Other `console` members are refused with a located diagnostic.
- Module import/export (local .ts/.sa files; `.wasm` imports declare arity-matched `@extern` at the first call site, linking needs the real module; `.wit` imports are refused with a located diagnostic)

### Parser
- Pratt expression parser with correct left-associativity (<= comparison)
- 6 precedence levels: or, and, comparison, sum, product, call
- Postfix ++ and --
- Unary negation and logical not
- Error recovery: collects multiple errors, skips to sync points

## Known Gaps

These are deliberate, documented refusals rather than silent bad codegen. See
`REQUIREMENTS.md` section 7 for the full list and the reference implementation
for each.

- **Interpolated template literals with non-integer operands** — integers
  lower via `sext` + `@sa_fmt_i64_into` (`sa_std/fmt.sai`) and strings pass
  through, joined chunk-by-chunk with `@sa_string_concat` (`sa_std/string.sai`)
  into a fresh `{ptr, len}` slice. Booleans render as 0/1 (documented). Float
  or other operand types record a located diagnostic and return
  `error.UnsupportedTemplateLiteral` instead of emitting bad SA.
- **String variable binding** — `const s: string = "..."` materializes a real
  slice (plain `s = "..."` is not a valid SA-ASM register assignment).
- **`s.length` property** — aliases to the string slice's `len` field. The
  method form `s.length()` is legacy and intentionally unhandled.
- **`try` / `catch` / `throw`** — SA-ASM has no exception edges. `throw` becomes
  `panic` (an abort), so `catch` cannot resume.
- **Statement-level intrinsics** (`store ...` / `alloc` as statements), `var`
  and `new` for declared interfaces lower normally; arrow functions take
  parameters (`(x: T) =>`, `(a, b) =>`, bare `x =>`, block and expression
  bodies) via out-of-line callbacks.
- **Async/await** lower to ready-future wrappers (`async function` returns a
  16-byte `{state, value}` handle, `await` unwraps); there is no executor.
- **`.wasm` imports** declare an arity-matched `@extern` at the first call
  site (verifier-accepted; linking needs the real module). An explicit
  `declare function` signature wins.
- **`.wit` imports** are refused with a located diagnostic: the assembler
  accepts no `@wit_import` directive, so none is emitted and calls are refused
  at the call site too.

## Diagnostics

Parser diagnostics are printed to stderr with `std.debug.print` (the
`error:line:col:` / `warning:line:col:` channel the CLI already uses) as well as
being collected on `Parser.errors`. `Parser.errors` is not reported by the CLI,
so anything user-facing must also print.

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
- Template literals: lexer produces template_start/mid/end, and template_end
  directly when a literal has no `${`. The parser re-primes both tokens from the
  normal lexer after consuming a template, since the template-mode lookahead is stale.
- Context struct aligned to 8 bytes (pointer alignment).
- `^ctx` (move) semantics for passing context to callbacks.

## Coding Conventions
- All Zig code follows standard formatting.
- No external dependencies beyond Zig stdlib.
- Tests are inline in `src/plugin.zig`.
- Error messages include `line:col`.
