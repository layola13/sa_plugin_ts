function f(x: i32): i32 {
  if (x > 0) { return 1; }
  return 2;
}
function main(): i32 {
  return f(1);
}
