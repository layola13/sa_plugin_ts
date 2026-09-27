enum Mode { A, B, C }
function main(): i32 {
  const m: i32 = 1;
  let t: i32 = 0;
  let i: i32 = 0;
  while (i < 3) {
    switch (m) {
      case 0: { t = t + 1; break; }
      case 1: { t = t + 2; break; }
      default: { t = t + 3; }
    }
    i = i + 1;
  }
  return t;
}
