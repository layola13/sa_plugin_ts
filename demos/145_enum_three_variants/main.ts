enum Level { Low, Mid, High }
function weight(l: i32): i32 {
  let r: i32 = 0;
  switch (l) {
    case 0: { r = 1; break; }
    case 1: { r = 2; break; }
    case 2: { r = 3; break; }
    default: { r = 0; }
  }
  return r;
}
function main(): i32 {
  return weight(2);
}
