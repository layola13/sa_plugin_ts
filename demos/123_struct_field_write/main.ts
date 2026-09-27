interface Point { x: i32; y: i32; }
function main(): i32 {
  const p: Point = { x: 1, y: 2 };
  p.x = 100;
  return p.x;
}
