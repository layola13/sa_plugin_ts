# Generic Inference

Call-site monomorphization-lite: `new Box((e: Item) => ...)` binds `T := Item`
on the instance, so methods returning `T` keep the struct layout for member
access. Ambiguity leaves the instance generic (loud downstream).

- `main.ts`: TypeScript source for this slot.
