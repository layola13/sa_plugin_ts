function checked(x: i32): i32 {
  if (x < 0) { return 0; }
  return x * 2;
}
function main(): i32 {
  return checked(21);
}
