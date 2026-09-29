# Optional Index

`a?.[i]` null-guarded index (Bun/esbuild shape); `?.` followed by a digit
(`c?.5:7`) lexes as ternary plus a leading-dot float (also Bun's rule).

Known gap (pre-existing, shared with plain `? 0.5 :` ternaries): a float
arm through the join slot loses float-ness, so only integer outcomes are
asserted here. Float-merge joins are future work.
