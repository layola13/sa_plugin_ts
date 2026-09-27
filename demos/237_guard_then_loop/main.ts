function run(n: i32): i32 {
  if (n < 0) { return 0; }
  if (n == 0) { return 1; }
  let t: i32 = 0;
  for (let i: i32 = 0; i < n; i++) { t = t + i; }
  return t;
}
function main(): i32 {
  return run(4);
}
