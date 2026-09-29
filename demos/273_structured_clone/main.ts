function main(): i32 {
  const src: number[][] = [[1, 2], [3, 4]];
  const c = structuredClone(src);
  c[0][0] = 9;
  return src[0][0] * 10 + c[0][0] + src[1][1];
}
