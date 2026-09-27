type Count = i32;
function bump(c: Count): Count {
  return c + 1;
}
function main(): i32 {
  return bump(1);
}
