interface Bag { size: i32; }
function main(): i32 {
  const arr: i32[] = [1, 2, 3];
  const b: Bag = { size: 3 };
  return arr[0] + b.size;
}
