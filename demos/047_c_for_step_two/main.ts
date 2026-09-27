function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 10; i = i + 2) { t = t + i; }
  return t;
}
