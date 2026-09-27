function stage1(x: i32): i32 { return x + 1; }
function stage2(x: i32): i32 { return x * 2; }
function stage3(x: i32): i32 { return x - 3; }
function main(): i32 {
  return stage3(stage2(stage1(1)));
}
