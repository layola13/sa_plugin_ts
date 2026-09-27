interface Point { x: i32; y: i32; }
function main(): i32 {
  let p: Point = { x: 1, y: 1 };
  p = { x: 2, y: 2 };
  return p.x;
}
