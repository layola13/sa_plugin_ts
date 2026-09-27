function main(): i32 {
  let best: i32 = 0;
  for (let i: i32 = 0; i < 5; i++) {
    if (i > best) { best = i; }
  }
  return best;
}
