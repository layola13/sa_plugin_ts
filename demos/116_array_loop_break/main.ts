function main(): i32 {
  const arr: i32[] = [1, 2, 3, 4];
  let t: i32 = 0;
  for (const v of arr) {
    if (v == 3) { break; }
    t = t + v;
  }
  return t;
}
