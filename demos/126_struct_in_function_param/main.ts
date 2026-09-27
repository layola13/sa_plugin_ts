interface Point { x: i32; y: i32; }
function getX(p: Point): i32 {
  return p.x;
}
function main(): i32 {
  const p: Point = { x: 7, y: 8 };
  return getX(p);
}
