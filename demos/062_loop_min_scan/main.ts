function main(): i32 {
  let worst: i32 = 100;
  for (let i: i32 = 0; i < 5; i++) {
    if (i < worst) { worst = i; }
  }
  return worst;
}
