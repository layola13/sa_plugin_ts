# Float Arithmetic

Type-directed float arithmetic copied from `sa_plugin_sla`'s
`planScalarBinaryOp`: `+ - * /` with an `f64` side lower to
`fadd`/`fsub`/`fmul`/`fdiv`, comparisons to `fcmp_*`.

- `main.ts`: TypeScript source for this slot.
