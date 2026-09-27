function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 5; i++) {
    if (i == 2) { break; }
    t = t + i;
  }
  return t;
}
