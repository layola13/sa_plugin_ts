function sum(arr_len: i32): i32 {
  const arr: i32[] = [1, 2, 3, 4, 5];
  let t: i32 = 0;
  for (const v of arr) { t = t + v; }
  return t + arr_len;
}
function main(): i32 {
  return sum(0);
}
