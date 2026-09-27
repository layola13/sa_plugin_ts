function main(): i32 {
  let i: i32 = 0;
  let t: i32 = 10;
  while (i < 5 && t > 0) {
    t = t - 1;
    i = i + 1;
  }
  return t;
}
