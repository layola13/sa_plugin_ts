function main(): i32 {
  let i: i32 = 0;
  let acc: i32 = 0;
  while (i < 4) {
    acc = acc + i;
    i = i + 1;
  }
  return acc;
}
