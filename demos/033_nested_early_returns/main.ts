function h(x: i32): i32 {
  if (x > 0) {
    if (x > 5) { return 2; }
    return 1;
  }
  return 0;
}
function main(): i32 {
  return h(9);
}
