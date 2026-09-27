function deep(x: i32): i32 {
  if (x == 1) {
    return 100;
  } else {
    if (x == 2) {
      return 200;
    } else {
      if (x == 3) { return 300; } else { return 0; }
    }
  }
}
function main(): i32 {
  return deep(2);
}
