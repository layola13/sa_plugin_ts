function count_upto(n: i32): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < n; i++) { t = t + 1; }
  return t;
}
function main(): i32 {
  return count_upto(7);
}
