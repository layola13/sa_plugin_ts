function out_of_range(x: i32, lo: i32, hi: i32): i32 {
  if (x < lo || x > hi) { return 1; }
  return 0;
}
function main(): i32 {
  return out_of_range(50, 0, 10);
}
