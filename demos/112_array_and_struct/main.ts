interface Point { x: i32; y: i32; }
function main(): i32 {
  const arr: i32[] = [1, 2];
  const p: Point = { x: 3, y: 4 };
  return arr[0] + p.x;
}
