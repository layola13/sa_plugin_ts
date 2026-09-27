function is_small(x: i32): i32 {
  if (x < 10) { return 1; }
  return 0;
}
function main(): i32 {
  return is_small(4);
}
