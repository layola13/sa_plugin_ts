function main(): i32 {
  const a: i32 = 5;
  const b: i32 = 5;
  const same: i32 = a == b;
  if (same && a > 0) { return 1; }
  return 0;
}
