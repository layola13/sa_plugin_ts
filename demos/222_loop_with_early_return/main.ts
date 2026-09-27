function scan(n: i32): i32 {
  for (let i: i32 = 0; i < n; i++) {
    if (i == 1) {
      if (i > 0) { return 99; }
    }
  }
  return 0;
}
function main(): i32 {
  return scan(5);
}
