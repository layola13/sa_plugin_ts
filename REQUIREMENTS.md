# Task Requirements: sa_plugin_ts

> **Status: partially complete.** Items marked `[x]` are implemented *and* verified
> to pass the SA-ASM verifier. See "Known Gaps" for features that parse but do not
> yet lower to valid SA-ASM. An earlier revision of this file claimed 100%
> completion; that was wrong because the test suite only asserted on substrings of
> the lowerer output and never assembled the result.

## 1. Goal
Implement a high-performance, AOT (Ahead-of-Time) lowering plugin for a strict subset of TypeScript that targets the SA-ASM ecosystem.

## 2. Core Features (Phase 1)
- [x] **SIMD Lexer**: Zero-copy string slices with SIMD-optimized whitespace scanning and line:col tracking.
- [x] **Type-Aware Parser**: Pratt parser handles TS interfaces, type aliases, primitive types, enums, generics.
- [x] **Static Offset Mapping**: Interface property access lowered to static byte offsets.
- [x] **Ownership Injection**: SA ownership operator `!` injected from lexical scope, and released on every exit path.
- [x] **Standard Library Mapping**: fs and net calls mapped to SA `@sa_fs_*` / `@sa_net_*` primitives with string arg expansion.
- [x] **Async/Await Support**: `async function f(): T` lowers to a ready-future
  wrapper (no executor; `await` unwraps the value). Verifier-accepted.
- [x] **WASM Interop**: `.wasm` imports declare an arity-matched `@extern` at
  the first call site (verifier-accepted; linking needs the real module).
- [x] **WIT Support**: `.wit` imports are refused with a located diagnostic —
  the assembler accepts no `@wit_import` directive, so none is emitted and
  calls are refused loudly at the call site (see Known Gaps).

## 3. Performance Targets
- [x] **Parsing Speed**: ~16k lines/sec in debug mode with the SIMD lexer (benchmark lives in the test suite).
- [x] **Verification**: Zero runtime cost; all safety checks performed by the SA Referee.
- [x] **Binary Size**: Minimal overhead, producing slim native/WASM binaries.

## 4. Constraints
- [x] Must not use existing heavy AST libraries (e.g., swc, esbuild).
- [x] Must adhere to SA-ASM's "Zero-AST / Linear Scanning" philosophy.
- [x] No dynamic JS features (any, eval, prototype modification).

## 5. Additional Features Implemented
- [x] Comparison operators: `==`, `!=`, `<`, `>`, `<=`, `>=`
- [x] Logical operators: `&&`, `||`, `!`
- [x] Arithmetic: `%`, unary `-`
- [x] Control flow: if/else, while, for (C-style), for-of, switch/case/default, break/continue, return
- [x] Arrays: literal `[1,2,3]`, indexing `arr[i]`, assignment `arr[i] = val` — including the annotated form `let arr: i32[] = [...]`
- [x] Enum definitions with auto-numbered variants
- [x] Type aliases
- [x] Generic type parameters (Array<T>, Map<K,V>, Box<T>)
- [x] Arrow function closures with parameters and static defunctionalization
  (`(x: T) =>`, `(a, b) =>`, bare `x =>`, block and expression bodies;
  out-of-line callbacks with per-arrow context registers; `let f = arrow`
  aliases; direct calls borrow `ctx`, higher-order passing moves `^ctx`)
- [x] Interpolated template literals (`` `sum=${x}` ``): integers render via
  `sext` + `@sa_fmt_i64_into` (`sa_std/fmt.sai`), floats via
  `@sa_fmt_f64_into` with precision 6, strings pass through,
  chunks join with the inlined `STR_CONCAT` body (`@sa_string_concat`,
  `sa_std/string.sai`). Booleans render as `0`/`1` (JEV scope decision);
  other operands are refused loudly with a located diagnostic
- [x] Type-directed float arithmetic (copied from `sa_plugin_sla`'s
  `planScalarBinaryOp`): `+ - * /` with an `f32`/`f64` side lower to
  `fadd`/`fsub`/`fmul`/`fdiv`, comparisons to `fcmp_*`; integer sides keep the
  existing forms (`/` on integers stays `div`, `%` stays `srem`). Unary `-` on
  a float lowers to `fneg`. There is no `frem` in SA-ASM, so `%` with a float
  side is refused loudly with a located diagnostic instead of emitting `srem`)
- [x] Double-quoted string literals bound to variables (`const s = "bob"`
  materialises the slice; the raw `"..."` is not an SA operand)
- [x] `s.length` property (aliased to the builtin string layout's `len`
  field) and the lenient `s.length()` method spelling (parens consumed)
- [x] Function return type annotations (`function f(): i32`) mapped to SA `-> i32:`
- [x] `catch (e) { }` binding form parses
- [x] Module-level import/export (local .ts/.sa modules; `.wasm` imports
  declare arity-matched `@extern` at first call site; `.wit` imports refused
  loudly with a located diagnostic)
- [x] CLI handle_command (`sa ts lower|check|build|build-exe|test|init [file.ts] [--out <path>] [-p <package>] [<sa-args>...]`, plus `skills [--json]` / `help`; `[file]` falls back to the `sa.mod` workspace (`-p name`/`-p=name`/`--package=name`); `test` delegates to `sa test`, `build-exe` to `sa build-exe <tmp.sai>` with direct passthrough and automatic `--jobs auto`; both spawn `sa` so `sap.json` declares `process.spawn` + `env`; `init [path]` scaffolds without overwriting)
- [x] Skills metadata registration
- [x] Standard plugin_api.zig ABI compliance
- [x] Parser error recovery (collects multiple errors, skips to sync points)
- [x] SIMD-optimized whitespace/comment scanning
- [x] Benchmark suite (40 tests total, including a runtime table whose 23 expectations are verified against Node: lower, `sa build`, run, assert exit status)
- [x] SA-ASM validity regression tests, plus an end-to-end check that runs `sa build` on lowered output
- [x] TypeScript demo corpus: 260 demos under `demos/`, verified by
      `tools/verify_demos.sh` (each demo is lowered and then assembled with the
      real `sa build`). Currently 259 verified against Node, 1 is refused with a
      located diagnostic (`155_generic_map`, a `new` expression), and 0 fail.
      `demos/251_kitchen_sink` exercises the whole verified subset in one program.
      `demos/262_float_arith` covers the type-directed float ops (`fdiv`/`fadd`/
      `fmul`/`fsub`/`fcmp_eq`).
      `demos/252_arrow_param_expr`–`255_arrow_block_body` cover arrow functions
      with parameters (expression/two-param/capture/block bodies).
      `demos/256_interp_basic`–`258_string_bind_length` cover interpolated
      templates, string-literal binding and `.length`.
      `demos/259_console_log_hello`–`261_console_log_loop` cover `console.log`
      (verified byte-for-byte against Node stdout, see §6a).
      `demos/251_kitchen_sink` exercises the whole verified subset in one program.
      The corpus is generated by `tools/gen_demos.py` (re-running it is a no-op).
- [x] CLI smoke suite: `tools/verify_cli.sh` (24 checks, all pass).

## 6. SA-ASM Emission Rules Enforced

These are the invariants the lowerer must hold; each has a regression test:

- Conditional branches use `br <cond> -> <true>, <false>`. There is no `jz`.
- `break` / `continue` lower to `jmp` at the enclosing loop or switch label.
- Every value-returning function declares `-> T:`; otherwise the backend rejects the `return`.
- Every basic block ends in a terminator, and no instruction follows a terminator.
- Unreferenced labels are dropped, so unreachable merge blocks are not emitted.
- `load` always carries an explicit byte offset (`load r + 0 as i32`).
- Live registers, including parameters, are released with `!` before each `return` and before any synthesised function terminator.
- A register moved by a register-to-register assignment is not released afterwards.

## 6a. Runtime Correctness (differential testing)

Assembling is not sufficient. A demo once verified cleanly and then segfaulted:
array literals were lowered as a raw element buffer while `for (const v of arr)`
read them as a slice, so `[1,2,3]` had its first element dereferenced as a data
pointer. Arrays are now lowered to a real SA slice (a 16-byte `{ptr,len}` header
plus a separate element buffer), which is also the layout `sa_std` expects.

`tools/verify_demos.sh` therefore links and **runs** every demo and compares the
result against **Node.js**. `tools/strip_ts.py` removes the TypeScript-only
syntax so the same program runs under Node; the two results must agree. This
checks the backend against a real evaluator rather than against expectations we
wrote ourselves, and it catches wrong-but-not-crashing results that no crash test
can see.

A process exit status is exactly `value & 0xFF`, so the comparison uses the low
byte; that also handles negative and out-of-range results. Print demos
(`259_console_log_*`) take the stdout branch instead: the Node oracle is
program stdout plus the harness's trailing `String(main())`, and print demos
conventionally `return 0`, so the oracle must equal the SA binary's captured
stdout with a trailing `"0"` appended byte-for-byte (file comparison via
`cmp`, never command substitution, which would strip trailing newlines).

### A finding that was reported and then withdrawn

A chained compare-dispatch of three or more `eq`/`br` levels was reported as
returning `44` instead of the selected value, and was recorded as an upstream
SA-toolchain bug. **That was wrong.** A process exit status is 8 bits, so
`return 300` is observed as `300 & 0xFF = 44`; the one- and two-level chains that
appeared to work all used values below 256 by coincidence. The shape is fine, the
value channel was the problem. Recorded in `tools/withdrawn_findings.md` so the
mistake is not repeated.

## 7. Known Gaps

### Rejected with a diagnostic (no longer emits invalid SA-ASM)

- **Non-numeric interpolation operands** (e.g. `null`) — recognised, but
  refused at lowering time with a `line:col` diagnostic. Integer, float and
  string operands lower normally (see §5); booleans render as `0`/`1` per the
  JEV scope decision recorded in §5.

### Parses, but cannot be semantically faithful

- **`try` / `catch` / `throw`** — SA-ASM has no exception edges. `throw` lowers to
  `panic`, which aborts, so a `catch` cannot resume execution. The `catch (e)`
  binding form parses correctly, but the construct is not equivalent to
  TypeScript.

### Not implemented

- **`/` on integers is integer division** — with no float side the subset maps
  TypeScript `/` to the integer `div`, so `15 / 2` yields `7`, not `7.5`. When
  either side is `f32`/`f64` (or a float literal) it lowers to `fdiv`, so
  `7.5 / 2.5` yields `3.0`. Programs relying on TypeScript float division must
  use float operands.
- **Statement-level intrinsics** — bare `store x + 0, 1 as i32` and `alloc(n)`
  used as statements lower inline (same instruction as the expression form).
- **`var`** — lowers exactly like `let` (function-level lowering with lexical
  scopes, so hoisting differences do not apply).
- **`new` as an expression** — refused loudly with a located diagnostic
  (`155_generic_map`); `alloc(n)` itself does lower. Refusing loudly is the
  intended behaviour, not a silent miscompile.

### Found by the demo corpus, still open

Verified counts from `tools/verify_demos.sh`: 259 assemble and match Node, 1 is
refused with a located diagnostic, and **0 fail**. Every demo now lands in a good
bucket, so no unresolved defect is left in the corpus.

- **Anonymous object literals (fixed)** — `125_struct_nested`,
  `133_struct_local_reassign`, `140_struct_deep_field` and
  `200_reassign_heap_struct` used to be refused with `unexpected token in
  expression: l_brace`. Field-type-driven nested literal parsing
  (`parseNewStructLiteral` / `parseStructLiteralFields`), struct reassignment
  through the declared type's allocation, and chained property loads retagged
  with the field type now lower all four; they assemble and match Node.
- **`new` as an expression (1)** — `155_generic_map` is refused with `unexpected
  token in expression: keyword_new`; `alloc(n)` itself does lower. Refusing
  loudly is the intended behaviour, not a silent miscompile.
- **Property access on an undefined name (fixed)** — `218_release_bundle` was
  refused with `property access on undefined variable 'b'`; the chained-load
  retag plus the C-for increment fix (`i = i ± N` in `parseForIncrement`,
  previously truncating the function) resolved it, and it now verifies.

### Branch-scoped registers: what actually fixed it

The long-standing "a heap value created inside an `if` arm or switch case leaks"
family is closed, and the CFG/dominator analysis turned out **not** to be the
missing piece. Two earlier attempts failed because they released *every* open
scope at the branch tail, which freed registers the enclosing function still
needed and turned a merge point into a state conflict (229 to 166 verified, e2e
24 to 18). The fix separates three questions that had been conflated:

1. **Which scopes does this control-flow edge abandon?** A `break`/`continue`
   target records its scope depth (`JumpTarget.scope_depth`), and
   `releaseScopesDeeperThan` releases only the scopes opened after it. Values
   bound outside stay live for the function-exit walk.
2. **Which scope's values die at a block's closing brace?**
   `exitScopeReleasingLocals` releases the innermost scope, and is applied to
   `if`/`else` arms, `while`, `for-of` and C-style `for` bodies, and to any block
   closing while `branch_depth`/`loop_depth` is non-zero. At function top level
   both depths are back to zero, so the function's own exit still owns those
   releases.
3. **Must the release be emitted at all?** A `return`, `break` or `continue`
   terminates the block, so a release written after it is unreachable code. That
   is why the release has to happen *before* the jump, not at the closing brace.

`Lowerer.computeDominators` is retained but no longer consulted during emission:
`dominatesWith` falls back to "the entry block dominates everything, any other
block dominates only itself", which is sound and is what the release walks use.
The `refreshDominators` call the switch-case path made was removed for the same
reason — its matrix could veto a release that was in fact required.

`Variable.is_released` makes the release walks idempotent. Several paths reach
the same release point (every `case` of a switch returns), and a second `!` for
the same register is a use-after-move error.

### A lexer bug that was hiding behind the corpus

`parseTemplateLiteral` re-primed both `current` and `peek` from the lexer after
consuming a template literal, but the `advance` that moved `current` onto the
literal had *already* primed `peek` with the following token. Reading two fresh
tokens therefore skipped one, so in an object literal whose field value was a
template literal, the `}` closing the object was swallowed. The field loop then
ran past the end of the literal, the function body was closed by the wrong brace,
and the releases that should have preceded the `return` were emitted after it —
the `basic blocks must end with jmp` failure seen in `219_full_app` and
`220_integration_all`. The fix consumes the already-primed `peek` instead.

Two helpers, `markScopeLoopLocal` and `markVarLoopLocal`, were removed: they
assigned to a `Variable.is_loop_local` field that does not exist. They were never
called, so Zig's lazy analysis never type-checked their bodies.

### Operand consumption, and why it is not simply "mark every operand"

Measured against the assembler:

| Construct | Moves the source? |
|---|---|
| `a = b` (register-to-register) | **yes** |
| `t = add a, b` | no — `a`/`b` must still be released |
| `t = load p + 0 as i32` | no — `p` is borrowed |
| `t = call @g(x)` | no |
| `br t -> A, B` | no |

So `markConsumed` on assignment is the complete rule. Temporaries are tracked and
released, and a release is only emitted where the definition dominates it
(`Lowerer.block_serial` plus `Variable.def_block`; the entry block dominates all
others, any other block dominates only itself). Releasing a temporary defined in
one arm of a branch, at the merge point, fails — that is the same missing-phi
problem above, not a separate bug.
