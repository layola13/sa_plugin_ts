function main(): i32 {
  const arr: i32[] = [1, 2, 3];
  let t: i32 = 0;
  for (const v of arr) { t = t + v; }
  return t;
}
