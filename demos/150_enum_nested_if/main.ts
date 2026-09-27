enum State { Idle, Busy }
function act(s: i32): i32 {
  if (s == 0) {
    return 1;
  } else {
    if (s == 1) { return 2; } else { return 0; }
  }
}
function main(): i32 {
  return act(1);
}
