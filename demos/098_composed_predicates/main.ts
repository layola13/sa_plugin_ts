function is_even(x: i32): i32 { if (x % 2 == 0) { return 1; } return 0; }
function is_positive(x: i32): i32 { if (x > 0) { return 1; } return 0; }
function main(): i32 {
  const v: i32 = 4;
  if (is_even(v) && is_positive(v)) { return 1; }
  return 0;
}
