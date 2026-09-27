function main(): i32 {
  let t: i32 = 0;
  switch (1) {
    case 1: { t = 1; break; }
    default: { t = 0; }
  }
  for (let i: i32 = 0; i < 3; i++) { t = t + i; }
  return t;
}
