function pick(flag: i32): i32 {
  let r: i32 = 0;
  if (flag) { r = 7; } else { r = 9; }
  return r;
}
function main(): i32 {
  return pick(1);
}
