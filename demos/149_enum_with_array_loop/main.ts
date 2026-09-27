enum State { Idle, Busy }
function main(): i32 {
  const arr: i32[] = [0, 1, 0];
  let t: i32 = 0;
  for (const v of arr) { t = t + v; }
  return t;
}
