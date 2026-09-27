interface Rect { x: i32; y: i32; w: i32; h: i32; }
function main(): i32 {
  const r: Rect = { x: 0, y: 0, w: 4, h: 5 };
  r.h = 10;
  return r.h;
}
