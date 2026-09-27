function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) {
    switch (i) {
      case 0: { t = t + 1; break; }
      case 1: { t = t + 10; break; }
      default: { t = t + 100; }
    }
  }
  return t;
}
