interface Point { x: i32; y: i32; }
interface Size { w: i32; h: i32; }
function main(): i32 {
  const p: Point = { x: 1, y: 2 };
  const s: Size = { w: 3, h: 4 };
  return p.x + s.w;
}
