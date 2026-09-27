function m(c: i32): i32 {
  let r: i32 = 0;
  switch (c) {
    case 0: { r = 0; break; }
    case 1: { r = 1; break; }
    case 2: { r = 2; break; }
    case 3: { r = 3; break; }
    case 4: { r = 4; break; }
    case 5: { r = 5; break; }
    case 6: { r = 6; break; }
    default: { r = 7; }
  }
  return r;
}
function main(): i32 {
  return m(3);
}
