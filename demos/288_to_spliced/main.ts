function main(): i32 {
  const a: number[] = [1, 2, 3, 4, 5];
  const r1 = a.toSpliced(1, 2);
  const r2 = a.toSpliced(1, 1, 9);
  const r3 = a.toSpliced(-2, 1, 7, 8);
  return a.length + r1.length * 2 + r2.length * 4 + r3.length * 8 + r1[1] + r2[1] * 2 + r3[3];
}
