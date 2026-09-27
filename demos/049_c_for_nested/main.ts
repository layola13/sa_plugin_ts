function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) {
    for (let j: i32 = 0; j < 3; j++) { t = t + 1; }
  }
  return t;
}
