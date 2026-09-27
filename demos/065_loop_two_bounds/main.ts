function main(): i32 {
  const lo: i32 = 2;
  const hi: i32 = 8;
  let t: i32 = 0;
  for (let i: i32 = lo; i < hi; i++) { t = t + i; }
  return t;
}
