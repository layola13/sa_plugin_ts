function add3(a: i32, b: i32, c: i32): i32 {
  return a + b + c;
}
function sum(...rest: number[]): i32 {
  let s: i32 = 0;
  for (const v of rest) { s = s + v; }
  return s;
}
function main(): i32 {
  const args: number[] = [3, 4];
  const big: number[] = [1, 2, 3, 4, 5];
  return add3(1, ...args) + sum(1, 2, 3, 4) + sum(...big);
}
