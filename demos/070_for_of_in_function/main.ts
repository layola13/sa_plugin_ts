function total_of(n: i32): i32 {
  const arr: i32[] = [1, 2, 3, 4];
  let t: i32 = 0;
  for (const v of arr) { t = t + v; }
  return t + n;
}
function main(): i32 {
  return total_of(1);
}
