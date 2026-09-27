function main(): i32 {
  const x: i32 = 5;
  let t: i32 = 0;
  if (x < 3) { t = 1; }
  else if (x < 6) { t = 2; }
  else { t = 3; }
  for (let i: i32 = 0; i < 2; i++) { t = t + i; }
  return t;
}
