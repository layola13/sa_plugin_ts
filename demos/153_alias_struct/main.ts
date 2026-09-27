interface Point { x: i32; y: i32; }
type Coord = Point;
function main(): i32 {
  const p: Point = { x: 1, y: 2 };
  return p.x;
}
