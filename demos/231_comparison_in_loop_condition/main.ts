function main(): i32 {
  const n: i32 = 6;
  let t: i32 = 0;
  let i: i32 = 0;
  while (i < n && t < 100) {
    t = t + i;
    i = i + 1;
  }
  return t;
}
