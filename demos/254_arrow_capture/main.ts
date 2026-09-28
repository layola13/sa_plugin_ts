function main(): i32 {
  let base: i32 = 100;
  let f = x => x + base;
  let r: i32 = f(5);
  return r;
}
