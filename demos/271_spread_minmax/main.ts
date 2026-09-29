function main(): i32 {
  const a: number[] = [4, 9, 2, 7];
  const hi = Math.max(...a);
  const lo = Math.min(...a);
  const two = Math.max(3, 8);
  return hi * 10 + lo + two;
}
