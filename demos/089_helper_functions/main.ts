function double(x: i32): i32 { return x * 2; }
function triple(x: i32): i32 { return x * 3; }
function sum_dbl_tri(x: i32): i32 { return double(x) + triple(x); }
function main(): i32 {
  return sum_dbl_tri(4);
}
