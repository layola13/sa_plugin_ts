function bucket(x: i32): i32 {
  if (x < 0) { return 0 - 1; }
  else if (x == 0) { return 0; }
  else if (x < 10) { return 1; }
  else { return 2; }
}
function main(): i32 {
  return bucket(5);
}
