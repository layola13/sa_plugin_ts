function main(): i32 {
  const a: number[] = [3, 1, 2];
  const s = a.toSorted();
  const d = a.toSorted((x, y) => y - x);
  const e: number[] = [];
  const es = e.toSorted();
  return s[0] + s[1] * 2 + s[2] * 4 + d[0] * 8 + a[0] * 16 + es.length;
}
