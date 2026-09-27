function different(a: i32, b: i32): i32 {
  if (a != b) { return 1; }
  return 0;
}
function main(): i32 {
  return different(4, 5);
}
