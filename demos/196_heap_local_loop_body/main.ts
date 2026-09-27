interface Point { x: i32; }
function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) {
    const p: Point = { x: i };
    t = t + p.x;
  }
  return t;
}
