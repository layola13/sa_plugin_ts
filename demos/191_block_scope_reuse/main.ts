function main(): i32 {
  let t: i32 = 0;
  for (let i: i32 = 0; i < 2; i++) { t = t + i; }
  for (let i: i32 = 0; i < 3; i++) { t = t + i; }
  return t;
}
