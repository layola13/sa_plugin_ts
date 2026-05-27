# Solution Design: sa_plugin_ts

## 1. Architectural Strategy
The plugin uses a **Linear Lowering Pipeline**. It processes TS source code and emits SA-ASM text directly, bypassing intermediate high-level IRs.

### 1.1 Data Structures
- **LayoutTable**: A compile-time map stored in the plugin's memory that tracks TypeID -> { Size, FieldMap<Name, Offset> }.
- **ScopeStack**: A stack of active variable bindings used to track when a register needs to be released (!).

### 1.2 Lowering Logic
- **Interface Definition**: Scanned and recorded in the LayoutTable. No code is emitted.
- **Member Access**: obj.field is looked up in the LayoutTable. The offset is immediately added to the base pointer.
- **FFI Airlock**: All I/O calls are wrapped in SA's @ffi_wrapper internally to safely transition to Syscalls.

### 1.3 WASM Module Linkage
- **Direct Symbol Mapping**: The parser recognizes .wasm imports as @extern symbols, allowing zero-cost integration of pre-compiled assets.
- **WIT Integration**: Stubs are automatically generated to bridge TS structures with WASM memory layouts.

## 2. Memory Management
The plugin uses an **Arena Allocator** per compilation unit. This allows for O(1) cleanup after the SA code has been emitted, ensuring the compiler itself remains extremely fast.

## 3. Toolchain Integration
The plugin is compiled as a .so (Linux) and exposes a C-ABI entry point sa_plugin_ts_lower.
