function main(): i32 {
  const work: i32[] = [1, 2, 3];
  let done: i32 = 0;
  for (const w of work) {
    switch (w) {
      case 1: { done = done + 1; break; }
      case 2: { done = done + 2; break; }
      default: { done = done + 3; }
    }
  }
  return done;
}
