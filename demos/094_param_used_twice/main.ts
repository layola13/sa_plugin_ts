function in_pair(x: i32): i32 {
  if (x > 0 && x < 100) { return 1; }
  return 0;
}
function main(): i32 {
  return in_pair(50);
}
