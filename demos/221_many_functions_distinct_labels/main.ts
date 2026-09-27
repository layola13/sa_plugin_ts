function a(x: i32): i32 { if (x > 0) { return 1; } return 0; }
function b(x: i32): i32 { if (x > 0) { return 2; } else { return 0; } }
function c(x: i32): i32 { let t: i32 = 0; for (let i: i32 = 0; i < x; i++) { t = t + i; } return t; }
function d(x: i32): i32 { let t: i32 = 0; let i: i32 = 0; while (i < x) { t = t + i; i = i + 1; } return t; }
function main(): i32 {
  return a(1) + b(1) + c(3) + d(3);
}
