interface S { mode: i32; n: i32; }
function main(): i32 {
  const s: S = { mode: 1, n: 3 };
  let t: i32 = 0;
  for (let i: i32 = 0; i < s.n; i++) {
    switch (s.mode) {
      case 0: { t = t + 1; break; }
      default: { t = t + i; }
    }
  }
  return t;
}
