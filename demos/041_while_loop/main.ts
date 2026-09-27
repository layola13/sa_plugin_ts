function sum_to(n: i32): i32 {
  let total: i32 = 0;
  let i: i32 = 0;
  while (i < n) {
    total = total + i;
    i = i + 1;
  }
  return total;
}
function main(): i32 {
  return sum_to(5);
}
