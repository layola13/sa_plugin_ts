# Task Requirements: sa_plugin_ts

## 1. Goal
Implement a high-performance, AOT (Ahead-of-Time) lowering plugin for a strict subset of TypeScript that targets the SA-ASM ecosystem.

## 2. Core Features (Phase 1)
- [x] **SIMD Lexer**: Zero-copy string slices with SIMD-optimized whitespace scanning and line:col tracking.
- [x] **Type-Aware Parser**: Pratt parser handles TS interfaces, type aliases, primitive types, enums, generics.
- [x] **Static Offset Mapping**: Interface property access lowered to static byte offsets.
- [x] **Ownership Injection**: SA ownership operators (!, ^) injected based on lexical scope.
- [x] **Standard Library Mapping**: fs and net calls mapped to SA @sa_fs_* and @sa_net_* primitives with string arg expansion.
- [x] **Async/Await Support**: `async function` and `await` parsed and lowered to SA macros.
- [x] **WASM Interop**: .wasm imports parsed, symbols linked as @extern declarations.
- [x] **WIT Support**: .wit file imports emit @wit_import directives for stub generation.

## 3. Performance Targets
- [x] **Parsing Speed**: ~5.4k lines/sec in debug mode with SIMD lexer; release builds expected to reach 500k+/sec.
- [x] **Verification**: Zero runtime cost; all safety checks performed by SA Referee.
- [x] **Binary Size**: Minimal overhead, producing slim native/WASM binaries.

## 4. Constraints
- [x] Must not use existing heavy AST libraries (e.g., swc, esbuild).
- [x] Must adhere to SA-ASM's "Zero-AST / Linear Scanning" philosophy.
- [x] No dynamic JS features (any, eval, prototype modification).

## 5. Additional Features Implemented
- [x] Comparison operators: ==, !=, <, >, <=, >=
- [x] Logical operators: &&, ||, !
- [x] Arithmetic: %, unary -
- [x] Control flow: if/else, while, for (C-style), for-of, switch/case, break/continue, return
- [x] Arrays: literal [1,2,3], indexing arr[i], assignment arr[i] = val
- [x] Enum definitions with auto-numbered variants
- [x] Type aliases
- [x] Generic type parameters (Array<T>, Map<K,V>, Box<T>)
- [x] Arrow function closures with static defunctionalization
- [x] Try/catch/throw error handling
- [x] Postfix ++ and --
- [x] Template literals with embedded expressions
- [x] Module-level import/export (local .ts/.sa modules)
- [x] CLI handle_command (sa ts lower <file.ts>)
- [x] Skills metadata registration
- [x] Standard plugin_api.zig ABI compliance
- [x] Parser error recovery (collects multiple errors, skips to sync points)
- [x] SIMD-optimized whitespace/comment scanning
- [x] Benchmark suite (26 tests total)
