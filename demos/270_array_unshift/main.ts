function main(): i32 {
  const a: number[] = [2, 3];
  a.unshift(1);
  const p = a.pop();
  a.push(4);
  const s = a.shift();
  return a[0] * 100 + a[1] + p * 10 + s;
}
