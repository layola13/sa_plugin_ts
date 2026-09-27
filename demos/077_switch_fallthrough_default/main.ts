function pick(a: i32): i32 {
  let r: i32 = 0;
  switch (a) {
    case 1: { r = 10; break; }
    default: { r = 5; }
  }
  return r;
}
function main(): i32 {
  return pick(3);
}
