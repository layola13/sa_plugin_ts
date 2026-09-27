interface Point { x: i32; y: i32; }
function sum(p: Point): i32 {
  return p.x + p.y;
}
function main(): i32 {
  const p: Point = { x: 10, y: 20 };
  return sum(p);
}
