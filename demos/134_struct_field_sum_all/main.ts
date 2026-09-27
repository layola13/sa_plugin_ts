interface V3 { x: i32; y: i32; z: i32; }
function total(v: V3): i32 {
  return v.x + v.y + v.z;
}
function main(): i32 {
  const v: V3 = { x: 1, y: 2, z: 3 };
  return total(v);
}
