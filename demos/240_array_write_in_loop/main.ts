function main(): i32 {
  let arr: i32[] = [0, 0, 0, 0];
  for (let i: i32 = 0; i < 4; i++) { arr[i] = i * 2; }
  return arr[3];
}
