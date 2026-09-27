function main(): i32 {
  const row: i32[] = [1, 2, 3];
  let t: i32 = 0;
  for (let r: i32 = 0; r < 2; r++) {
    for (const v of row) { t = t + v; }
  }
  return t;
}
