function a(x: i32): i32 { return x + 1; }
function b(x: i32): i32 { return a(x) * 2; }
function c(x: i32): i32 { return b(x) + a(x); }
function main(): i32 {
  return c(3);
}
