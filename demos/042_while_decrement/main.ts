function main(): i32 {
  let n: i32 = 5;
  let acc: i32 = 1;
  while (n > 0) {
    acc = acc * n;
    n = n - 1;
  }
  return acc;
}
