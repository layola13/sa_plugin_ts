function main(): i32 {
  let t: i32 = 0;
  let i: i32 = 0;
  while (i < 3) {
    for (let j: i32 = 0; j < 3; j++) { t = t + 1; }
    i = i + 1;
  }
  return t;
}
