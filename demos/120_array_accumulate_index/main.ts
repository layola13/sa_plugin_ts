function main(): i32 {
  const arr: i32[] = [1, 2, 3, 4];
  let t: i32 = 0;
  for (let i: i32 = 0; i < 4; i++) { t = t + arr[i]; }
  return t;
}
