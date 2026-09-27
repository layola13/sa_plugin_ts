function g(x: i32): i32 {
  if (x > 0) { return 1; } else { return 2; }
  return 3;
}
function main(): i32 {
  return g(1);
}
