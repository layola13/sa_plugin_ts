function pick(a: i32): i32 {
  let r: i32 = 0;
  switch (a) {
    default: { r = 7; }
  }
  return r;
}
function main(): i32 {
  return pick(0);
}
