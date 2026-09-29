function main(): i32 {
  const a: number[] = [1, 2, 3, 4];
  const r = a.toReversed();
  const e: number[] = [];
  const er = e.toReversed();
  return a[0] + a[3] * 10 + r[0] + r[3] * 2 + er.length;
}
