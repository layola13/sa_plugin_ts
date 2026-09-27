function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 5; i++) {
    switch (i) {
      case 3: { t = 99; break; }
      default: { t = t + i; }
    }
    t = t + 100;
  }
  return t;
}
