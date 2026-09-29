function main(): i32 {
  let acc = 0;
  const a: number[] = [1, 2, 3, 4, 5];
  a.copyWithin(0, 3);
  acc = acc + a[0] * 1 + a[1] * 10;
  const b: number[] = [1, 2, 3, 4, 5];
  b.copyWithin(1, 0, 3);
  acc = acc + b[1] * 100 + b[3] * 1000;
  const c: number[] = [1, 2, 3, 4, 5];
  c.copyWithin(-2, -3, -1);
  acc = acc + c[3];
  const d: number[] = [1, 2, 3];
  d.copyWithin(0, 0);
  d.copyWithin(2, 0, 0);
  d.copyWithin(5, 0, 2);
  acc = acc + d[0] + d[2] * 2;
  return acc;
}
