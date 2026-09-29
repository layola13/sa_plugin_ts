function main(): i32 {
  const a: number[] = [1, 2];
  const b = [...a, 3];
  const c = [0, ...a, ...b];
  return b[0] * 10 + b[2] + c[0] + c[3] + c[5];
}
