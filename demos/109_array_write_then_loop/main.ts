function main(): i32 {
  let arr: i32[] = [1, 2, 3];
  arr[0] = 10;
  let t: i32 = 0;
  for (const v of arr) { t = t + v; }
  return t;
}
