function sign(x: i32): i32 {
  if (x < 0) { return 0 - 1; } else { return 1; }
}
function main(): i32 {
  return sign(0 - 5);
}
