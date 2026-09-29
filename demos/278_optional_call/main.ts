function plus(a: i32, b: i32): i32 {
  return a + b;
}
const double = (x: i32): i32 => x * 2;
function main(): i32 {
  return plus?.(3, 4) + double?.(21);
}
