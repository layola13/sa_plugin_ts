function inc(x: i32): i32 { return x + 1; }
function main(): i32 {
  return inc(1) + inc(2) * inc(3);
}
