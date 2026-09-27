function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) {
    const doubled: i32 = i * 2;
    t = t + doubled;
  }
  return t;
}
