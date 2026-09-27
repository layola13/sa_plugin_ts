function clamp(x: i32, lo: i32, hi: i32): i32 {
  if (x < lo) { return lo; }
  if (x > hi) { return hi; }
  return x;
}
function main(): i32 {
  return clamp(3 * 4, 0 + 1, 10 + 2);
}
