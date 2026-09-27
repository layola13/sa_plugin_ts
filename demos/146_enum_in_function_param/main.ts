enum Color { Red, Green }
function is_red(c: i32): i32 {
  if (c == 0) { return 1; }
  return 0;
}
function main(): i32 {
  return is_red(0);
}
