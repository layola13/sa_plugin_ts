function f0(x: i32): i32 { return x + 0; }
function f1(x: i32): i32 { return x + 1; }
function f2(x: i32): i32 { return x + 2; }
function f3(x: i32): i32 { return x + 3; }
function main(): i32 {
  return f0(1) + f1(1) + f2(1) + f3(1);
}
