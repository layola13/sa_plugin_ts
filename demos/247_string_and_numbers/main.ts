function main(): i32 {
  const label: string = `total`;
  const base: i32 = 10;
  let t: i32 = base;
  for (let i: i32 = 0; i < 3; i++) { t = t + i; }
  return t;
}
