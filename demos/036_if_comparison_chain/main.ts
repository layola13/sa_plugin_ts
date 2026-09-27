function between(x: i32): i32 {
  if (0 < x && x < 100) { return 1; }
  return 0;
}
function main(): i32 {
  return between(50);
}
