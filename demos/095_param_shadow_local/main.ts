function widen(x: i32): i32 {
  let y: i32 = x;
  let z: i32 = y + 1;
  return z;
}
function main(): i32 {
  return widen(9);
}
