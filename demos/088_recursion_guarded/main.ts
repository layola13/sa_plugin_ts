function countdown(n: i32): i32 {
  if (n <= 0) { return 0; }
  return 1 + countdown(n - 1);
}
function main(): i32 {
  return countdown(5);
}
