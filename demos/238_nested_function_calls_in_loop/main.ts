function dbl(x: i32): i32 { return x * 2; }
function inc(x: i32): i32 { return x + 1; }
function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) { t = dbl(inc(i)); }
  return t;
}
