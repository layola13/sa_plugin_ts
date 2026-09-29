export function incSum(n: i32): i32 {
  let s: i32 = 0;
  for (let i = 0; i < n; ++i) { s = s + i; }
  return s;
}
function main(): i32 {
  let t: i32 = 10;
  ++t;
  ++t;
  --t;
  return incSum(5) + t;
}
