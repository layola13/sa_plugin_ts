enum State { Idle, Busy }
function main(): i32 {
  const s: i32 = 1;
  let t: i32 = 0;
  for (let i: i32 = 0; i < 3; i++) {
    if (s == 1) { t = t + i; }
  }
  return t;
}
