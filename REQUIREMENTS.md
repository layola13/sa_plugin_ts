# Task Requirements: sa_plugin_ts

## 1. Goal
Implement a high-performance, AOT (Ahead-of-Time) lowering plugin for a strict subset of TypeScript that targets the SA-ASM ecosystem.

## 2. Core Features (Phase 1)
- [ ] **SIMD Lexer**: High-speed tokenization with zero-copy string slices.
- [ ] **Type-Aware Parser**: Pratt parser that handles TS interfaces, type aliases, and primitive types.
- [ ] **Static Offset Mapping**: Lower interface property access to static byte offsets.
- [ ] **Ownership Injection**: Automatic insertion of SA ownership operators (\\^, !) based on TS lexical scope.
- [ ] **Standard Library Mapping**: Direct mapping of fs and net calls to SA's @sys_* primitives.
- [ ] **Async/Await Support**: Leverage SA's async/await macros for non-blocking I/O.
- [ ] **WASM Interop**: Direct mapping of .wasm exports to TS symbols.
- [ ] **WIT Support**: Automatic stub generation from Wasm Interface Types.

## 3. Performance Targets
- **Parsing Speed**: > 500k lines per second on modern hardware.
- **Verification**: Zero runtime cost; all safety checks performed by SA Referee.
- **Binary Size**: Minimal overhead, producing slim native/WASM binaries.

## 4. Constraints
- Must not use existing heavy AST libraries (e.g., swc, esbuild).
- Must adhere to SA-ASM's "Zero-AST / Linear Scanning" philosophy.
- No dynamic JS features (any, eval, prototype modification).
