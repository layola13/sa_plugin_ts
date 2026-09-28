function main(): i32 {
  const a: i32 = 2;
  const b: i32 = 3;
  const c: i32 = 4;
  // Integer arithmetic only: the supported subset maps TypeScript `/` to the
  // integer `div`, so a program relying on TypeScript float division is out of
  // scope. See REQUIREMENTS.md.
  return a * b + c * 2 - 1 + (a + b) * (c - 1) * 2;
}
