function min(a: i32, b: i32): i32 {
  if (a < b) { return a; } else { return b; }
}
function main(): i32 {
  return min(10, 20);
}
