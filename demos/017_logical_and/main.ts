function in_range(x: i32, lo: i32, hi: i32): i32 {
  if (x >= lo && x <= hi) { return 1; }
  return 0;
}
function main(): i32 {
  return in_range(5, 0, 10);
}
