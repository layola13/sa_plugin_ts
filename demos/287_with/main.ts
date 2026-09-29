function main(): i32 {
  const a: number[] = [10, 20, 30];
  const b = a.with(1, 99);
  const c = a.with(-1, 77);
  return a[1] + b[1] + c[2];
}
