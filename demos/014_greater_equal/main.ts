function at_most(x: i32, n: i32): i32 {
  if (x >= n) { return 1; }
  return 0;
}
function main(): i32 {
  return at_most(5, 5);
}
