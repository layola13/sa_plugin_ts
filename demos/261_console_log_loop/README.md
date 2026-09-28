# Console Log Loop

`console.log` inside a loop body, observed via program stdout. Exercises
loop-local temporaries and per-iteration releases in the print path.

- `main.ts`: TypeScript source for this slot.
- Convention for print demos: `return 0`, so the Node oracle (program
  output + `String(main())`) equals the SA binary's stdout plus a
  trailing `0`; `tools/verify_demos.sh` compares exactly that.
