function d(a: i32): i32 {
  switch (a) {
    case 1: { return 10; }
    case 2: { return 20; }
    default: { return 0; }
  }
}
function main(): i32 {
  return d(1);
}
