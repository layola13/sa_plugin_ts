interface Point { x: i32; }
function main(): i32 {
  let t: i32 = 0;
  if (1 < 2) {
    const p: Point = { x: 5 };
    t = p.x;
  }
  return t;
}
