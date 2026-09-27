function factorial(n: i32): i32 {
  let acc: i32 = 1;
  for (let i: i32 = 1; i <= n; i++) { acc = acc * i; }
  return acc;
}
function main(): i32 {
  return factorial(5);
}
