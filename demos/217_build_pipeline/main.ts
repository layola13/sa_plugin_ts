function compile_one(x: i32): i32 { return x + 1; }
function link_one(x: i32): i32 { return x * 2; }
function main(): i32 {
  let total: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) { total = link_one(compile_one(i)); }
  return total;
}
