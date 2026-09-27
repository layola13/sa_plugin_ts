function main(): i32 {
  const cells: i32[] = [0, 1, 2, 3, 4];
  let t: i32 = 0;
  for (let i: i32 = 0; i < 5; i++) { t = t + cells[i]; }
  return t;
}
