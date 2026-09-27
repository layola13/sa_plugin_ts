interface P { x: i32; y: i32; }
function main(): i32 {
  const arr: i32[] = [1, 2, 3, 4];
  const a: P = { x: 1, y: 2 };
  const b: P = { x: 3, y: 4 };
  let t: i32 = 0;
  for (const v of arr) { t = t + v + a.x + b.y; }
  return t;
}
