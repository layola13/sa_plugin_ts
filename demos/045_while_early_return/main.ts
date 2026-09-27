function find(n: i32): i32 {
  let i: i32 = 0;
  while (i < n) {
    if (i == 2) { return 42; }
    i = i + 1;
  }
  return 0;
}
function main(): i32 {
  return find(10);
}
