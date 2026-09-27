function checked(a: i32, b: i32): i32 {
  if (a < 0) { return 0; }
  if (b < 0) { return 0; }
  return a + b;
}
function main(): i32 {
  return checked(3, 4);
}
