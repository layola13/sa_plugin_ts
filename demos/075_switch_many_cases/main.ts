function name_of(c: i32): i32 {
  let r: i32 = 0;
  switch (c) {
    case 0: { r = 100; break; }
    case 1: { r = 200; break; }
    case 2: { r = 300; break; }
    case 3: { r = 400; break; }
    default: { r = 999; }
  }
  return r;
}
function main(): i32 {
  return name_of(2);
}
