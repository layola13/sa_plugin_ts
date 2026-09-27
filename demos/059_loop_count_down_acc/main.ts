function main(): i32 {
  let n: i32 = 5;
  let t: i32 = 0;
  while (n > 0) {
    t = t + n;
    n = n - 1;
  }
  return t;
}
