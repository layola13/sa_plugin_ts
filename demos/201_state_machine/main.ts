function step(state: i32, ev: i32): i32 {
  let next: i32 = state;
  switch (state) {
    case 0: { next = 1; break; }
    case 1: { next = 2; break; }
    default: { next = 0; }
  }
  return next;
}
function main(): i32 {
  return step(0, 1);
}
