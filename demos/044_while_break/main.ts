function main(): i32 {
  let i: i32 = 0;
  let t: i32 = 0;
  while (i < 100) {
    if (i == 3) { break; }
    t = t + i;
    i = i + 1;
  }
  return t;
}
