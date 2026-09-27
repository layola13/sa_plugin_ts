function half(x: i32): i32 { return x / 2; }
function main(): i32 {
  const a: i32 = half(10);
  const b: i32 = half(20);
  return a + b;
}
