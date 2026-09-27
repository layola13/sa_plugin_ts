interface Point { x: i32; y: i32; }
function make(x: i32, y: i32): Point {
  const p: Point = { x: x, y: y };
  return p;
}
function main(): i32 {
  const p: Point = make(4, 5);
  return p.y;
}
