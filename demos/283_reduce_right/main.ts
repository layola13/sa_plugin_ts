function main(): i32 {
  const a: number[] = [1, 2, 3, 4];
  const r1 = a.reduceRight((x, y) => x - y, 100);
  const r2 = a.reduceRight((x, y) => x + y);
  const e: number[] = [];
  const r4 = e.reduceRight((x, y) => x + y, 7);
  const s: number[] = [42];
  const r5 = s.reduceRight((x, y) => x + y);
  const r7 = a.reduceRight((x, y, i) => x + y + i, 0);
  return r1 + r2 * 10 + r4 + r5 * 2 + r7;
}
