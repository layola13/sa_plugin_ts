function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 2; i++) {
    const arr: i32[] = [i, i];
    t = t + arr[1];
  }
  return t;
}
