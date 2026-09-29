function main(): i32 {
  const g: [number, number][] = [[1, 4], [2, 1]];
  const out: number[] = [0, 0];
  g.forEach(([a, b]) => {
    out[0] = out[0] + a;
    out[1] = out[1] + b;
  });
  return out[0] * 10 + out[1];
}
