function ok(a: i32, b: i32, c: i32): i32 {
  if (a > 0 && b > 0 && c > 0) { return 1; }
  return 0;
}
function main(): i32 {
  return ok(1, 2, 3);
}
