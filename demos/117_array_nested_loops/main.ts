function main(): i32 {
  const a: i32[] = [1, 2];
  const b: i32[] = [3, 4];
  let t: i32 = 0;
  for (const x of a) { t = t + x; }
  for (const y of b) { t = t + y; }
  return t;
}
