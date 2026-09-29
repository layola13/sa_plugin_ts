function main(): i32 {
  const a: number[] = [1, 2, 3, 4];
  const s = a.some((x) => x > 3);
  const e = a.every((x) => x > 0);
  const f = a.find((x) => x > 2);
  const fi = a.findIndex((x) => x > 2);
  const ic = a.includes(3);
  return s * 10000 + e * 1000 + f * 100 + fi * 10 + ic;
}
