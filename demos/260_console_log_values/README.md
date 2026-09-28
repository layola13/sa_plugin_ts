# Console Log Values

`console.log` with mixed string/integer operands, multiple arguments
(space-separated), and a zero-argument call (blank line), observed via
program stdout.

- `main.ts`: TypeScript source for this slot.
- Convention for print demos: `return 0`, so the Node oracle (program
  output + `String(main())`) equals the SA binary's stdout plus a
  trailing `0`; `tools/verify_demos.sh` compares exactly that.
