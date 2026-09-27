interface Point { x: i32; y: i32; }
type Coord = i32;
function main(): i32 {
  const p: Point = { x: 1, y: 2 };
  const c: Coord = 3;
  return p.x + c;
}
