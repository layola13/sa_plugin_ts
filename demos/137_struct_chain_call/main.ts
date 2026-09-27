interface Point { x: i32; y: i32; }
function twice(x: i32): i32 { return x * 2; }
function main(): i32 {
  const p: Point = { x: 5, y: 6 };
  return twice(p.x);
}
