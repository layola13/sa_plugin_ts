function pick(a: i32): i32 {
  let r: i32 = 0;
  switch (a) {
    case 1: { r = 10; break; }
    case 2: { r = 20; break; }
    default: { r = 99; }
  }
  return r;
}
function main(): i32 {
  return pick(1);
}
