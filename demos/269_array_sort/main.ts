function main(): i32 {
  const a: number[] = [3, 1, 2];
  a.sort();
  const b: number[] = [3, 1, 2];
  b.sort((x, y) => y - x);
  return a[0] * 100 + a[1] * 10 + a[2] + b[0] * 1000 + b[1] * 100 + b[2] * 10;
}
