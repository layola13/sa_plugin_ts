interface Point { x: i32; y: i32; }
function main(): i32 {
  const p: Point = { x: 2, y: 3 };
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) { t = t + p.x; }
  return t;
}
